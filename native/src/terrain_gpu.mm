// metal189: GPU-driven terrain (see terrain_gpu.h, shaders/terrain.metal).
//
// The engine keeps a table of every section's draw metadata (layer buffer addresses, face
// groups) on the GPU, updated as sections change. Each frame the CPU hands over only the
// visible list (ids and vanilla's camera offsets); kernels turn it into records and meshlets
// per layer, in draw order, and each layer is one indirect instanced draw. The CPU's work no
// longer grows with the number of visible sections' geometry.
#import "terrain_gpu.h"
#import "resources.h"
#include <unordered_set>

namespace m189 {

extern int g_optQuadDiagonal;

namespace {

struct SectionMeta {          // terrain.metal TerrainSectionMeta
    uint64_t verts[4];
    uint32_t groupStart[4][8];
    float plane[4][7];
    uint32_t pad[4];
};
static_assert(sizeof(SectionMeta) == 288, "matches TerrainSectionMeta");

struct MetaUpdate {           // terrain.metal TerrainMetaUpdate
    uint32_t id;
    uint32_t pad[3];
    SectionMeta meta;
};
static_assert(sizeof(MetaUpdate) == 304, "matches TerrainMetaUpdate");

struct Entry { uint32_t id; float x, y, z; };

struct Uniforms {             // terrain.metal TerrainCullUniforms
    simd_float4x4 mv;
    simd_float4 chunk[4];
    simd_float4 eye;
    simd_uint4 n, cap, base;
};

std::vector<SectionMeta> g_meta;            // CPU copy, by id
std::vector<uint32_t> g_dirty;
std::unordered_set<uint32_t> g_dirtySet;
uint64_t g_quads[4] = {0, 0, 0, 0};          // resident quads per layer (meshlet capacity)
std::vector<uint32_t> g_metaQuads;           // per id: its layers' quads (4 per id)

id<MTLBuffer> g_table = nil;                 // GPU table (private)
size_t g_tableCount = 0;

id<MTLComputePipelineState> g_count, g_scan, g_emit, g_scatter;
bool g_tried = false, g_ok = false;

bool init() {
    if (g_tried) return g_ok;
    g_tried = true;
    id<MTLLibrary> lib = engine().library;
    NSError* err = nil;
    auto make = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> f = [lib newFunctionWithName:name];
        if (!f) return nil;
        id<MTLComputePipelineState> p = [device() newComputePipelineStateWithFunction:f error:&err];
        if (!p) log("terrain gpu: %s: %s", name.UTF8String, err.localizedDescription.UTF8String);
        return p;
    };
    g_count = make(@"terrain_count");
    g_scan = make(@"terrain_scan");
    g_emit = make(@"terrain_emit");
    g_scatter = make(@"terrain_meta_scatter");
    g_ok = g_count && g_scan && g_emit && g_scatter && g_scan.maxTotalThreadsPerThreadgroup >= 1024;
    if (!g_ok) log("terrain gpu: unavailable; terrain is culled on the CPU");
    return g_ok;
}

// Per frame in flight: scratch the kernels write.
struct Scratch {
    id<MTLBuffer> entries, records, counts, offsets, meshlets, args;
    size_t entryCap = 0, meshletCap = 0;
};
Scratch g_scratch[kFramesInFlight + 1];
uint32_t g_scratchIndex = 0;

id<MTLBuffer> newBuffer(size_t bytes, MTLResourceOptions o) {
    return [device() newBufferWithLength:std::max<size_t>(bytes, 256) options:o];
}

// Brings the GPU table up to date (in `cb`, ahead of the culling that reads it).
void flushMeta(id<MTLCommandBuffer> cb) {
    if (g_tableCount < g_meta.size()) {
        size_t count = std::max(g_meta.size() + 4096, g_tableCount * 2);
        id<MTLBuffer> t = newBuffer(count * sizeof(SectionMeta), MTLResourceStorageModePrivate);
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        b.label = @"terrain table grow";
        [b fillBuffer:t range:NSMakeRange(0, t.length) value:0];
        if (g_table) [b copyFromBuffer:g_table sourceOffset:0 toBuffer:t destinationOffset:0 size:g_tableCount * sizeof(SectionMeta)];
        [b endEncoding];
        g_table = t;
        g_tableCount = count;
    }
    if (g_dirty.empty()) return;
    size_t bytes = g_dirty.size() * sizeof(MetaUpdate);
    id<MTLBuffer> up = newBuffer(bytes, MTLResourceStorageModeShared);
    MetaUpdate* u = (MetaUpdate*)up.contents;
    for (size_t i = 0; i < g_dirty.size(); i++) {
        u[i].id = g_dirty[i];
        u[i].meta = g_meta[g_dirty[i]];
    }
    uint32_t count = (uint32_t)g_dirty.size();
    id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
    c.label = @"terrain table update";
    [c setComputePipelineState:g_scatter];
    [c setBytes:&count length:sizeof count atIndex:0];
    [c setBuffer:up offset:0 atIndex:1];
    [c setBuffer:g_table offset:0 atIndex:2];
    [c dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [c endEncoding];
    g_dirty.clear();
    g_dirtySet.clear();
}

} // namespace

void terrainMetaChanged(int id, const Section* s) {
    if (id <= 0) return;
    if ((size_t)id >= g_meta.size()) {
        g_meta.resize((size_t)id + 1024, SectionMeta{});
        g_metaQuads.resize(g_meta.size() * 4, 0);
    }
    SectionMeta& m = g_meta[id];
    m = SectionMeta{};
    for (int l = 0; l < 4; l++) {
        uint32_t q = 0;
        if (s && s->layers[l]) {
            m.verts[l] = s->layers[l].gpuAddress;
            for (int g = 0; g < 8; g++) m.groupStart[l][g] = s->groupStart[l][g];
            for (int g = 0; g < 7; g++) m.plane[l][g] = s->plane[l][g];
            q = s->vertices[l] / 4;
        }
        g_quads[l] += q;
        g_quads[l] -= g_metaQuads[(size_t)id * 4 + l];
        g_metaQuads[(size_t)id * 4 + l] = q;
    }
    if (g_dirtySet.insert((uint32_t)id).second) g_dirty.push_back((uint32_t)id);
}

id<MTLBuffer> terrainMeshletIndices() {
    static id<MTLBuffer> b = nil;
    static int diagonal = -1;
    if (b && diagonal == g_optQuadDiagonal) return b;
    b = newBuffer(64 * 6 * 2, MTLResourceStorageModeShared);
    uint16_t* p = (uint16_t*)b.contents;
    for (uint16_t q = 0; q < 64; q++) {
        uint16_t v = q * 4;
        if (g_optQuadDiagonal) {
            p[q * 6 + 0] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 3;
            p[q * 6 + 3] = v + 1; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        } else {
            p[q * 6 + 0] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 2;
            p[q * 6 + 3] = v; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        }
    }
    diagonal = g_optQuadDiagonal;
    return b;
}

bool terrainGpuCull(id<MTLCommandBuffer> cb, const uint32_t* ids, const simd_float3* offsets, uint32_t count,
                    const simd_float4x4& mv, simd_float3 eye, bool faceCull, const float chunk[16], TerrainGpuDraws& out) {
    if (!init() || count == 0) return false;
    flushMeta(cb);
    Scratch& s = g_scratch[g_scratchIndex];
    g_scratchIndex = (g_scratchIndex + 1) % (kFramesInFlight + 1);
    // meshlets: every run of a section's layer is at most 7 runs, each rounded up to whole meshlets
    uint32_t cap[4], base[4], total = 0;
    for (int l = 0; l < 4; l++) {
        uint64_t c = g_quads[l] / 64 + (uint64_t)count * 7 + 64;
        cap[l] = (uint32_t)std::min<uint64_t>(c, 1u << 26);
        base[l] = total;
        total += cap[l];
    }
    if (s.entryCap < count) {
        s.entryCap = std::max<size_t>(count + 1024, s.entryCap * 2);
        s.entries = newBuffer(s.entryCap * sizeof(Entry), MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined);
        s.records = newBuffer(s.entryCap * 96, MTLResourceStorageModePrivate);
        s.counts = newBuffer(s.entryCap * 16, MTLResourceStorageModePrivate);
        s.offsets = newBuffer(s.entryCap * 16, MTLResourceStorageModePrivate);
    }
    if (s.meshletCap < total) {
        s.meshletCap = (size_t)total + total / 4;
        s.meshlets = newBuffer(s.meshletCap * 16, MTLResourceStorageModePrivate);
    }
    if (!s.args) s.args = newBuffer(4 * 20, MTLResourceStorageModePrivate);
    Entry* e = (Entry*)s.entries.contents;
    for (uint32_t i = 0; i < count; i++) e[i] = {ids[i], offsets[i].x, offsets[i].y, offsets[i].z};
    Uniforms u;
    u.mv = mv;
    for (int c = 0; c < 4; c++) u.chunk[c] = simd_make_float4(chunk[c * 4], chunk[c * 4 + 1], chunk[c * 4 + 2], chunk[c * 4 + 3]);
    u.eye = simd_make_float4(eye.x, eye.y, eye.z, faceCull ? 1.0f : 0.0f);
    u.n = simd_make_uint4(count, 0, 0, 0);
    u.cap = simd_make_uint4(cap[0], cap[1], cap[2], cap[3]);
    u.base = simd_make_uint4(base[0], base[1], base[2], base[3]);
    id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
    c.label = @"terrain cull";
    [c setBytes:&u length:sizeof u atIndex:0];
    [c setBuffer:s.entries offset:0 atIndex:1];
    [c setBuffer:g_table offset:0 atIndex:2];
    [c setBuffer:s.records offset:0 atIndex:3];
    [c setBuffer:s.counts offset:0 atIndex:4];
    [c setBuffer:s.offsets offset:0 atIndex:5];
    [c setBuffer:s.args offset:0 atIndex:6];
    [c setBuffer:s.meshlets offset:0 atIndex:7];
    [c setComputePipelineState:g_count];
    [c dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [c memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [c setComputePipelineState:g_scan];
    [c dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
    [c memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [c setComputePipelineState:g_emit];
    [c dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [c endEncoding];
    out.records = s.records;
    out.meshlets = s.meshlets;
    for (int l = 0; l < 4; l++) out.meshletBase[l] = base[l];
    out.args = s.args;
    return true;
}

} // namespace m189
