// metal189: block voxel volume for world-space reflections, world-space GI and coloured
// block light.
//
// A 128-block cube around the camera, stored toroidally in 3D textures (block (x, y, z)
// lives at texel (x, y, z) mod 128), in 16-block slots that each hold one terrain section.
// Each voxel records what reflections need to draw a block: where its texture is in the
// block atlas, its tint, its light and its shape (bounds and octants for partial blocks,
// crossed planes for plants). Sections are voxelized on the GPU from the same vertex
// buffers the terrain passes draw, when they change or come into range.
//
// For coloured block light, voxels also record how they treat light (solid, a colour
// filter such as stained glass, or a light of some colour), and a flood fill spreads
// coloured light through the volume a block per step, as vanilla spreads light levels.
#import "voxels.h"
#import "resources.h"
#import "advanced.h"
#import "gpu_profiler.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_set>
#include <vector>

namespace m189 {

namespace {

constexpr int kN = 128, kSlots = kN / 16;
constexpr int kMaxUpdatesPerFrame = 24;
constexpr size_t kScratchPerSection = 16 * 16 * 16 * 16;   // 4 uints per block
constexpr int kFloodStepsPerFrame = 2;

struct Slot {
    bool filled = false;
    int32_t sx = 0, sy = 0, sz = 0;   // section coordinates (blocks / 16) the slot holds
    uint64_t version = 0;             // 0: the section was absent (cleared slot)
};

id<MTLTexture> g_tex = nil, g_shape = nil, g_occ = nil, g_occSlot = nil;
id<MTLTexture> g_props = nil, g_flood[2] = {nil, nil};   // coloured block light (allocated when used)
int g_floodCur = 0;
// flood steps still to run: light settles a block per step (15 levels), so after a change the
// flood runs this many steps and then rests until something changes again
int g_floodRemaining = 0;
constexpr int kFloodSettleSteps = 40;
bool g_lightFilled = false;   // every slot has its light properties
id<MTLBuffer> g_scratch = nil, g_dummy = nil;
id<MTLComputePipelineState> g_accum = nil, g_resolve = nil, g_occK = nil, g_tintK = nil, g_floodK = nil;
bool g_tried = false;
Slot g_slot[kSlots][kSlots][kSlots];

struct ResolveArgs {         // voxel_resolve_kernel's VoxResolveArgs
    simd_int4 slot;          // xyz: slot origin in texels
    simd_float4 atlas;       // xy: atlas size in texels
    simd_uint4 light;        // x: write light properties, y: clear the slot's spread light (new position)
};

struct TintArgs {            // voxel_tint_kernel's VoxTintArgs
    simd_int4 slot;
    simd_uint4 info;         // x: quads
};

struct FloodArgs {           // light_flood_kernel's FloodArgs
    simd_int4 wrap;          // xyz: volume origin mod N, w: N
    simd_int4 origin;        // xyz: the slot's corner in the volume (blocks), w: 1 to clear it
};

std::vector<uint64_t> g_lightSlots;   // sections the light spread through last frame

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

void resetSlots() {
    for (auto& a : g_slot) for (auto& b : a) for (Slot& sl : b) sl = Slot();
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
        g_occSlot = volume(dev, MTLPixelFormatR8Uint, kSlots, @"voxel slots");
        // per-section scratch the resolve pass leaves cleared, so zeroed once here
        g_scratch = [dev newBufferWithLength:kScratchPerSection * kMaxUpdatesPerFrame options:MTLResourceStorageModeShared];
        if (g_scratch) memset(g_scratch.contents, 0, g_scratch.length);
        g_dummy = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
        resetSlots();
        g_lightFilled = false;
        if (!g_tex || !g_shape || !g_occ || !g_occSlot || !g_scratch || !g_dummy) {
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
    auto kernel = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [engine().library newFunctionWithName:name constantValues:cv error:&err];
        return fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    };
    g_accum = kernel(@"voxel_accum_kernel");
    g_resolve = kernel(@"voxel_resolve_kernel");
    g_occK = kernel(@"voxel_occ_kernel");
    g_tintK = kernel(@"voxel_tint_kernel");
    g_floodK = kernel(@"light_flood_kernel");
    if (!g_accum || !g_resolve || !g_occK) {
        log("voxels: unavailable: %s", err ? err.localizedDescription.UTF8String : "no kernels");
        g_accum = nil;
        voxelsRelease();
        return false;
    }
    if (!g_tintK || !g_floodK) log("voxels: no coloured block light: %s", err ? err.localizedDescription.UTF8String : "no kernels");
    return true;
}

// Coloured block light's textures; dropping them when it is off saves 24 MB.
bool ensureLight(bool on) {
    if (!on || !g_tintK || !g_floodK) {
        g_props = g_flood[0] = g_flood[1] = nil;
        g_lightFilled = false;
        return false;
    }
    if (g_props) return true;
    id<MTLDevice> dev = device();
    g_props = volume(dev, MTLPixelFormatRGBA8Uint, kN, @"voxel light properties");
    g_floodRemaining = kFloodSettleSteps;
    g_flood[0] = volume(dev, MTLPixelFormatRGBA8Unorm, kN, @"coloured light 0");
    g_flood[1] = volume(dev, MTLPixelFormatRGBA8Unorm, kN, @"coloured light 1");
    if (!g_props || !g_flood[0] || !g_flood[1]) {
        g_props = g_flood[0] = g_flood[1] = nil;
        return false;
    }
    g_lightFilled = false;
    return true;
}

} // namespace

void voxelsRelease() {
    // command buffers in flight hold their own references
    g_tex = g_shape = g_occ = g_occSlot = nil;
    g_props = g_flood[0] = g_flood[1] = nil;
    g_lightFilled = false;
    g_lightSlots.clear();
    g_scratch = g_dummy = nil;
}

bool voxelsUpdate(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, id<MTLTexture> atlas, bool light, VoxelScene& out) {
    out = VoxelScene();
    if (!atlas || !init()) return false;
    int atlasW = (int)atlas.width, atlasH = (int)atlas.height;
    bool lightOn = ensureLight(light) && advancedLightColors() && advancedMaterials();
    if (lightOn && !g_lightFilled) {
        // every slot needs its light properties: voxelize them all again
        resetSlots();
        g_lightFilled = true;
    }
    // the volume: kSlots sections per axis around the camera's section
    int cx = floorDiv((int)std::floor(camX), 16) - kSlots / 2, cy = floorDiv((int)std::floor(camY), 16) - kSlots / 2,
        cz = floorDiv((int)std::floor(camZ), 16) - kSlots / 2;
    struct Job { int dist; int sx, sy, sz; const Section* s; bool moved; };
    std::vector<Job> jobs;
    for (int i = 0; i < kSlots; i++)
        for (int j = 0; j < kSlots; j++)
            for (int k = 0; k < kSlots; k++) {
                int sx = cx + i, sy = cy + j, sz = cz + k;
                Slot& sl = g_slot[mod(sx, kSlots)][mod(sy, kSlots)][mod(sz, kSlots)];
                const Section* s = sectionAt(sx, sy, sz);
                uint64_t version = s ? s->version : 0;
                bool here = sl.filled && sl.sx == sx && sl.sy == sy && sl.sz == sz;
                if (here && sl.version == version) continue;
                int di = i - kSlots / 2, dj = j - kSlots / 2, dk = k - kSlots / 2;
                jobs.push_back({di * di + dj * dj + dk * dk, sx, sy, sz, s, !here});
            }
    auto slotOf = [](int sx, int sy, int sz) {
        return simd_make_int4(mod(sx, kSlots) * 16, mod(sy, kSlots) * 16, mod(sz, kSlots) * 16, 0);
    };
    if (!jobs.empty()) {
        std::sort(jobs.begin(), jobs.end(), [](const Job& a, const Job& b) { return a.dist < b.dist; });
        if ((int)jobs.size() > kMaxUpdatesPerFrame) jobs.resize(kMaxUpdatesPerFrame);
        MTLComputePassDescriptor* cp = [MTLComputePassDescriptor computePassDescriptor];
        profCompute(cp, "voxels");
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoderWithDescriptor:cp];
        e.label = @"voxels";
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
        if (lightOn) {
            [e setTexture:g_props atIndex:2];
            [e setTexture:g_flood[0] atIndex:3];
            [e setTexture:g_flood[1] atIndex:4];
            [e setBuffer:advancedLightColors() offset:0 atIndex:6];
        }
        static const uint32_t kNoSolid[128] = {};
        for (size_t n = 0; n < jobs.size(); n++) {
            const Section* s = jobs[n].s;
            for (uint32_t layer = 0; layer < 3; layer++) {
                id<MTLBuffer> lb = s && s->layers[layer] && s->vertices[layer] ? s->layers[layer] : g_dummy;
                [e setBuffer:lb offset:0 atIndex:layer];
            }
            [e setBuffer:g_scratch offset:n * kScratchPerSection atIndex:3];
            ResolveArgs a;
            a.slot = slotOf(jobs[n].sx, jobs[n].sy, jobs[n].sz);
            a.atlas = simd_make_float4((float)atlasW, (float)atlasH, 0, 0);
            a.light = simd_make_uint4(lightOn ? 1u : 0u, jobs[n].moved ? 1u : 0u, 0, 0);
            [e setBytes:&a length:sizeof a atIndex:4];
            [e setBytes:s ? s->solid : kNoSolid length:512 atIndex:5];
            [e dispatchThreads:MTLSizeMake(16, 16, 16) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
        }
        [e memoryBarrierWithScope:MTLBarrierScopeTextures];
        // stained glass and the like filter light, portals give it (the translucent layer)
        if (lightOn) {
            [e setComputePipelineState:g_tintK];
            [e setTexture:g_props atIndex:0];
            [e setTexture:atlas atIndex:1];
            [e setBuffer:advancedLightColors() offset:0 atIndex:2];
            [e setBuffer:advancedMaterials() offset:0 atIndex:3];
            for (const Job& jb : jobs) {
                const Section* s = jb.s;
                uint32_t quads = s && s->layers[3] ? s->vertices[3] / 4 : 0;
                if (!quads) continue;
                TintArgs ta;
                ta.slot = slotOf(jb.sx, jb.sy, jb.sz);
                ta.info = simd_make_uint4(quads, 0, 0, 0);
                [e setBuffer:s->layers[3] offset:0 atIndex:0];
                [e setBytes:&ta length:sizeof ta atIndex:4];
                [e dispatchThreads:MTLSizeMake(quads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            }
            [e memoryBarrierWithScope:MTLBarrierScopeTextures];
        }
        // which 4-block bricks hold anything (traces cross the empty ones in one step)
        [e setComputePipelineState:g_occK];
        [e setTexture:g_tex atIndex:0];
        [e setTexture:g_occ atIndex:1];
        [e setTexture:g_occSlot atIndex:2];
        for (const Job& jb : jobs) {
            simd_int4 slot = slotOf(jb.sx, jb.sy, jb.sz);
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
        if (!jobs.empty()) g_floodRemaining = kFloodSettleSteps;   // new or changed blocks in the volume
    }
    int ox = cx * 16, oy = cy * 16, oz = cz * 16;   // the volume's min corner (blocks)
    out.wrap = simd_make_int4(mod(ox, kN), mod(oy, kN), mod(oz, kN), kN);
    if (lightOn) {
        // spread coloured light a block per step through what lets it pass, in sections with
        // something that gives light and their neighbours (light reaches 14 blocks)
        auto key = [](int x, int y, int z) {
            return ((uint64_t)(uint32_t)(x & 0x1FFFFF) << 42) | ((uint64_t)(uint32_t)(y & 0x1FFFFF) << 21) | (uint64_t)(uint32_t)(z & 0x1FFFFF);
        };
        bool emits[kSlots][kSlots][kSlots];
        for (int i = 0; i < kSlots; i++)
            for (int j = 0; j < kSlots; j++)
                for (int k = 0; k < kSlots; k++) {
                    const Section* s = sectionAt(cx + i, cy + j, cz + k);
                    emits[i][j][k] = s && s->emits;
                }
        std::vector<simd_int4> active;
        std::vector<uint64_t> activeKeys;
        for (int i = 0; i < kSlots; i++)
            for (int j = 0; j < kSlots; j++)
                for (int k = 0; k < kSlots; k++) {
                    bool lit = false;
                    for (int a = -1; a <= 1 && !lit; a++)
                        for (int b = -1; b <= 1 && !lit; b++)
                            for (int c = -1; c <= 1 && !lit; c++) {
                                int ii = i + a, jj = j + b, kk = k + c;
                                lit = ii >= 0 && jj >= 0 && kk >= 0 && ii < kSlots && jj < kSlots && kk < kSlots && emits[ii][jj][kk];
                            }
                    if (!lit) continue;
                    active.push_back(simd_make_int4(i * 16, j * 16, k * 16, 0));
                    activeKeys.push_back(key(cx + i, cy + j, cz + k));
                }
        // sections that no longer see light lose what they had
        std::unordered_set<uint64_t> now(activeKeys.begin(), activeKeys.end());
        std::vector<simd_int4> cleared;
        for (uint64_t kk : g_lightSlots) {
            if (now.count(kk)) continue;
            int sx = (int)((int64_t)(kk << 1) >> 43), sy = (int)((int64_t)(kk << 22) >> 43), sz = (int)((int64_t)(kk << 43) >> 43);
            int i = sx - cx, j = sy - cy, k = sz - cz;
            if (i >= 0 && j >= 0 && k >= 0 && i < kSlots && j < kSlots && k < kSlots) cleared.push_back(simd_make_int4(i * 16, j * 16, k * 16, 1));
        }
        if (activeKeys != g_lightSlots || !cleared.empty()) g_floodRemaining = kFloodSettleSteps;
        g_lightSlots.swap(activeKeys);
        if ((!active.empty() && g_floodRemaining > 0) || !cleared.empty()) {
            MTLComputePassDescriptor* cp = [MTLComputePassDescriptor computePassDescriptor];
            profCompute(cp, "coloured light");
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoderWithDescriptor:cp];
            e.label = @"coloured light";
            [e setComputePipelineState:g_floodK];
            [e setTexture:g_props atIndex:0];
            FloodArgs fa;
            fa.wrap = out.wrap;
            for (const simd_int4& o : cleared) {
                fa.origin = o;
                for (int t = 0; t < 2; t++) {
                    [e setTexture:g_flood[t] atIndex:1];
                    [e setTexture:g_flood[t] atIndex:2];
                    [e setBytes:&fa length:sizeof fa atIndex:0];
                    [e dispatchThreads:MTLSizeMake(16, 16, 16) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
                }
            }
            for (int step = 0; step < kFloodStepsPerFrame && !active.empty() && g_floodRemaining > 0; step++, g_floodRemaining--) {
                [e setTexture:g_flood[g_floodCur] atIndex:1];
                [e setTexture:g_flood[g_floodCur ^ 1] atIndex:2];
                for (const simd_int4& o : active) {
                    fa.origin = o;
                    [e setBytes:&fa length:sizeof fa atIndex:0];
                    [e dispatchThreads:MTLSizeMake(16, 16, 16) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
                }
                [e memoryBarrierWithScope:MTLBarrierScopeTextures];
                g_floodCur ^= 1;
            }
            [e endEncoding];
        }
        out.light = g_flood[g_floodCur];
    } else {
        g_lightSlots.clear();
    }
    out.tex = g_tex;
    out.shape = g_shape;
    out.occ = g_occ;
    out.occSlot = g_occSlot;
    out.cam = simd_make_float4((float)(camX - ox), (float)(camY - oy), (float)(camZ - oz), 0);
    out.valid = true;
    return true;
}

} // namespace m189
