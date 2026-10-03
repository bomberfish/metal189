// metal189: block voxel volume for world-space reflections.
//
// A 128-block cube around the camera, stored toroidally in 3D textures (block (x, y, z)
// lives at texel (x, y, z) mod 128), in 16-block slots that each hold one terrain section.
// Each voxel records what reflections need to draw a block: where its texture is in the
// block atlas, its tint, its light and its shape (bounds and octants for partial blocks,
// crossed planes for plants). Sections are voxelized on the GPU from the same vertex
// buffers the terrain passes draw, when they change or come into range.
#import "voxels.h"
#import "resources.h"
#import "gpu_profiler.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace m189 {

namespace {

constexpr int kN = 128, kSlots = kN / 16;
constexpr int kMaxUpdatesPerFrame = 24;
constexpr size_t kScratchPerSection = 16 * 16 * 16 * 16;   // 4 uints per block

struct Slot {
    bool filled = false;
    int32_t sx = 0, sy = 0, sz = 0;   // section coordinates (blocks / 16) the slot holds
    uint64_t version = 0;             // 0: the section was absent (cleared slot)
};

id<MTLTexture> g_tex = nil, g_shape = nil, g_occ = nil;
id<MTLBuffer> g_scratch = nil, g_dummy = nil;
id<MTLComputePipelineState> g_accum = nil, g_resolve = nil, g_occK = nil;
bool g_tried = false;
Slot g_slot[kSlots][kSlots][kSlots];

struct ResolveArgs {         // voxel_resolve_kernel's VoxResolveArgs
    simd_int4 slot;          // xyz: slot origin in texels
    simd_float4 atlas;       // xy: atlas size in texels
};

int floorDiv(int a, int b) { return (a >= 0 ? a : a - b + 1) / b; }
int mod(int a, int b) { int m = a % b; return m < 0 ? m + b : m; }

id<MTLTexture> volume(id<MTLDevice> dev, MTLPixelFormat f, int n, NSString* label) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor new];
    d.textureType = MTLTextureType3D;
    d.pixelFormat = f;
    d.width = d.height = d.depth = n;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    t.label = label;
    return t;
}

bool init() {
    id<MTLDevice> dev = device();
    if (g_tried) {
        if (!g_accum) return false;
        if (g_tex) return true;
    }
    if (!g_tex) {
        g_tex = volume(dev, MTLPixelFormatRGBA16Uint, kN, @"voxels");
        g_shape = volume(dev, MTLPixelFormatRG32Uint, kN, @"voxel shapes");
        g_occ = volume(dev, MTLPixelFormatR8Uint, kN / 4, @"voxel bricks");
        // per-section scratch the resolve pass leaves cleared, so zeroed once here
        g_scratch = [dev newBufferWithLength:kScratchPerSection * kMaxUpdatesPerFrame options:MTLResourceStorageModeShared];
        if (g_scratch) memset(g_scratch.contents, 0, g_scratch.length);
        g_dummy = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
        for (auto& a : g_slot) for (auto& b : a) for (Slot& sl : b) sl = Slot();
        if (!g_tex || !g_shape || !g_occ || !g_scratch || !g_dummy) {
            log("voxels: unavailable: out of memory");
            voxelsRelease();
            return false;
        }
    }
    if (g_tried) return true;
    g_tried = true;
    MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
    bool f = false;
    for (NSUInteger i = 10; i <= 12; i++) [cv setConstantValue:&f type:MTLDataTypeBool atIndex:i];
    NSError* err = nil;
    id<MTLFunction> ka = [engine().library newFunctionWithName:@"voxel_accum_kernel" constantValues:cv error:&err];
    id<MTLFunction> kr = [engine().library newFunctionWithName:@"voxel_resolve_kernel" constantValues:cv error:&err];
    id<MTLFunction> ko = [engine().library newFunctionWithName:@"voxel_occ_kernel" constantValues:cv error:&err];
    if (ka) g_accum = [dev newComputePipelineStateWithFunction:ka error:&err];
    if (kr) g_resolve = [dev newComputePipelineStateWithFunction:kr error:&err];
    if (ko) g_occK = [dev newComputePipelineStateWithFunction:ko error:&err];
    if (!g_accum || !g_resolve || !g_occK) {
        log("voxels: unavailable: %s", err ? err.localizedDescription.UTF8String : "no kernels");
        g_accum = nil;
        voxelsRelease();
        return false;
    }
    return true;
}

} // namespace

void voxelsRelease() {
    // command buffers in flight hold their own references
    g_tex = g_shape = g_occ = nil;
    g_scratch = g_dummy = nil;
}

bool voxelsUpdate(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, int atlasW, int atlasH, VoxelScene& out) {
    out = VoxelScene();
    if (atlasW <= 0 || atlasH <= 0 || !init()) return false;
    // the volume: kSlots sections per axis around the camera's section
    int cx = floorDiv((int)std::floor(camX), 16) - kSlots / 2, cy = floorDiv((int)std::floor(camY), 16) - kSlots / 2,
        cz = floorDiv((int)std::floor(camZ), 16) - kSlots / 2;
    struct Job { int dist; int sx, sy, sz; const Section* s; };
    std::vector<Job> jobs;
    for (int i = 0; i < kSlots; i++)
        for (int j = 0; j < kSlots; j++)
            for (int k = 0; k < kSlots; k++) {
                int sx = cx + i, sy = cy + j, sz = cz + k;
                Slot& sl = g_slot[mod(sx, kSlots)][mod(sy, kSlots)][mod(sz, kSlots)];
                const Section* s = sectionAt(sx, sy, sz);
                uint64_t version = s ? s->version : 0;
                if (sl.filled && sl.sx == sx && sl.sy == sy && sl.sz == sz && sl.version == version) continue;
                int di = i - kSlots / 2, dj = j - kSlots / 2, dk = k - kSlots / 2;
                jobs.push_back({di * di + dj * dj + dk * dk, sx, sy, sz, s});
            }
    if (!jobs.empty()) {
        std::sort(jobs.begin(), jobs.end(), [](const Job& a, const Job& b) { return a.dist < b.dist; });
        if ((int)jobs.size() > kMaxUpdatesPerFrame) jobs.resize(kMaxUpdatesPerFrame);
        MTLComputePassDescriptor* cp = [MTLComputePassDescriptor computePassDescriptor];
        profCompute(cp, "voxels");
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoderWithDescriptor:cp];
        e.label = @"voxels";
        auto slotOf = [](const Job& jb) {
            return simd_make_int4(mod(jb.sx, kSlots) * 16, mod(jb.sy, kSlots) * 16, mod(jb.sz, kSlots) * 16, 0);
        };
        // what each block's quads cover, into the section's scratch
        [e setComputePipelineState:g_accum];
        for (size_t n = 0; n < jobs.size(); n++) {
            const Section* s = jobs[n].s;
            if (!s) continue;
            [e setBuffer:g_scratch offset:n * kScratchPerSection atIndex:2];
            for (uint32_t layer = 0; layer < 3; layer++) {
                uint32_t quads = s->layers[layer] ? s->vertices[layer] / 4 : 0;
                if (!quads) continue;
                simd_uint2 info = simd_make_uint2(quads, layer);
                [e setBuffer:s->layers[layer] offset:0 atIndex:0];
                [e setBytes:&info length:sizeof info atIndex:1];
                [e dispatchThreads:MTLSizeMake(quads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            }
        }
        [e memoryBarrierWithScope:MTLBarrierScopeBuffers];
        // into voxels (absent sections clear their slot)
        [e setComputePipelineState:g_resolve];
        [e setTexture:g_tex atIndex:0];
        [e setTexture:g_shape atIndex:1];
        for (size_t n = 0; n < jobs.size(); n++) {
            const Section* s = jobs[n].s;
            for (uint32_t layer = 0; layer < 3; layer++) {
                id<MTLBuffer> lb = s && s->layers[layer] && s->vertices[layer] ? s->layers[layer] : g_dummy;
                [e setBuffer:lb offset:0 atIndex:layer];
            }
            [e setBuffer:g_scratch offset:n * kScratchPerSection atIndex:3];
            ResolveArgs a;
            a.slot = slotOf(jobs[n]);
            a.atlas = simd_make_float4((float)atlasW, (float)atlasH, 0, 0);
            [e setBytes:&a length:sizeof a atIndex:4];
            [e dispatchThreads:MTLSizeMake(16, 16, 16) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
        }
        [e memoryBarrierWithScope:MTLBarrierScopeTextures];
        // which 4-block bricks hold anything (traces cross the empty ones in one step)
        [e setComputePipelineState:g_occK];
        [e setTexture:g_tex atIndex:0];
        [e setTexture:g_occ atIndex:1];
        for (const Job& jb : jobs) {
            simd_int4 slot = slotOf(jb);
            [e setBytes:&slot length:sizeof slot atIndex:0];
            [e dispatchThreads:MTLSizeMake(4, 4, 4) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
        }
        [e endEncoding];
        for (const Job& jb : jobs) {
            Slot& sl = g_slot[mod(jb.sx, kSlots)][mod(jb.sy, kSlots)][mod(jb.sz, kSlots)];
            sl.filled = true;
            sl.sx = jb.sx; sl.sy = jb.sy; sl.sz = jb.sz;
            sl.version = jb.s ? jb.s->version : 0;
        }
    }
    int ox = cx * 16, oy = cy * 16, oz = cz * 16;   // the volume's min corner (blocks)
    out.tex = g_tex;
    out.shape = g_shape;
    out.occ = g_occ;
    out.wrap = simd_make_int4(mod(ox, kN), mod(oy, kN), mod(oz, kN), kN);
    out.cam = simd_make_float4((float)(camX - ox), (float)(camY - oy), (float)(camZ - oz), 0);
    out.valid = true;
    return true;
}

} // namespace m189
