// metal189: GPU-driven terrain (src/terrain_gpu.mm). The frame's visible sections become
// records (layer buffers + modelview) and 64-quad meshlets per layer, in vanilla's order
// (translucent back to front), entirely on the GPU; each layer is one indirect draw.
#include "common.h"

struct TerrainSectionMeta {        // per section id (terrain_gpu.mm SectionMeta)
    ulong verts[4];                // layer buffers' GPU addresses (0: empty layer)
    uint groupStart[4][8];         // per layer: face groups' first quads (resources.h)
    float plane[4][7];             // per layer: face groups' planes
    uint pad[4];
};

struct TerrainEntryGpu {           // per visible section: its id and vanilla's camera offset
    uint id;
    float x, y, z;
};

struct TerrainRecordGpu {          // ff.metal TerrainDraw
    ulong verts[4];
    float4x4 mv;
};

struct TerrainMeshletGpu {         // ff.metal TerrainMeshlet
    uint record, first, count, layer;
};

struct TerrainCullUniforms {
    float4x4 mv;                   // the terrain pass's modelview
    float4 chunk[4];               // RenderChunk's model matrix columns (frame_exec.mm sectionMatrix)
    float4 eye;                    // xyz: the eye in offset space; w: 1 = cull back-facing groups
    uint4 n;                       // x: entries
    uint4 cap;                     // meshlet capacity per layer
    uint4 base;                    // first meshlet of each layer's region
};

constant uint kMeshletQuads = 64;
enum { FG_NY = 0, FG_NX, FG_NZ, FG_PY, FG_OTHER, FG_PZ, FG_PX, FG_COUNT };

// frame_exec.mm sectionMatrix, with the same fused operations so CPU and GPU agree exactly.
static float4x4 sectionMatrix(float4x4 mv, float3 o, constant float4* chunk) {
    float m[16];
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) m[c * 4 + r] = mv[c][r];
    for (int r = 0; r < 4; r++) m[12 + r] = fma(m[8 + r], o.z, fma(m[4 + r], o.y, fma(m[r], o.x, m[12 + r])));
    float4x4 out;
    for (int c = 0; c < 4; c++) {
        float4 b = chunk[c];
        for (int r = 0; r < 4; r++) out[c][r] = fma(m[12 + r], b.w, fma(m[8 + r], b.z, fma(m[4 + r], b.y, m[r] * b.x)));
    }
    return out;
}

// Counts a layer's meshlets (layerRuns' callback).
struct CountMeshlets {
    uint count = 0;
    void operator()(uint, uint quads) { count += (quads + kMeshletQuads - 1) / kMeshletQuads; }
};

// Writes a layer's meshlets from its first slot (layerRuns' callback).
struct EmitMeshlets {
    device TerrainMeshletGpu* out;
    uint at, cap, record, layer;
    void operator()(uint first, uint quads) {
        for (uint q = 0; q < quads; q += kMeshletQuads) {
            if (at < cap) out[at] = TerrainMeshletGpu{record, first + q, min(kMeshletQuads, quads - q), layer};
            at++;
        }
    }
};

// The layer's visible runs of face groups (frame_exec.mm drawTerrain), as calls to emit(first, quads).
template <typename F>
static void layerRuns(device const TerrainSectionMeta& m, uint l, float3 o, constant TerrainCullUniforms& u, thread F& emit) {
    const float eps = 1e-3f;
    float cx = u.eye.x - o.x, cy = u.eye.y - o.y, cz = u.eye.z - o.z;
    device const float* pl = m.plane[l];
    bool cull = u.eye.w > 0.5f;
    bool vis[FG_COUNT] = {
        cy < pl[FG_NY] + eps, cx < pl[FG_NX] + eps, cz < pl[FG_NZ] + eps, cy > pl[FG_PY] - eps,
        true, cz > pl[FG_PZ] - eps, cx > pl[FG_PX] - eps,
    };
    uint runStart = 0, runEnd = 0;
    bool open = false;
    for (int g = 0; g < FG_COUNT; g++) {
        uint a = m.groupStart[l][g], b = m.groupStart[l][g + 1];
        if (a == b) continue;
        if (!cull || vis[g]) {
            if (!open) { runStart = a; open = true; }
            runEnd = b;
        } else if (open) {
            emit(runStart, runEnd - runStart);
            open = false;
        }
    }
    if (open) emit(runStart, runEnd - runStart);
}

kernel void terrain_count(uint i [[thread_position_in_grid]],
                          constant TerrainCullUniforms& u [[buffer(0)]],
                          device const TerrainEntryGpu* entries [[buffer(1)]],
                          device const TerrainSectionMeta* metas [[buffer(2)]],
                          device TerrainRecordGpu* records [[buffer(3)]],
                          device uint* counts [[buffer(4)]]) {
    uint n = u.n.x;
    if (i >= n) return;
    TerrainEntryGpu e = entries[i];
    device const TerrainSectionMeta& m = metas[e.id];
    float3 o = float3(e.x, e.y, e.z);
    TerrainRecordGpu r;
    for (int l = 0; l < 4; l++) r.verts[l] = m.verts[l];
    r.mv = sectionMatrix(u.mv, o, u.chunk);
    records[i] = r;
    for (uint l = 0; l < 4; l++) {
        CountMeshlets c;
        if (m.verts[l] != 0) layerRuns(m, l, o, u, c);
        counts[l * n + i] = c.count;
    }
}

struct IndirectIndexed { uint indexCount, instanceCount, indexStart; int baseVertex; uint baseInstance; };

// One threadgroup per layer: exclusive prefix sums of the counts in draw order (translucent:
// last entry first), and the layer's indirect draw.
kernel void terrain_scan(uint t [[thread_index_in_threadgroup]], uint l [[threadgroup_position_in_grid]],
                         constant TerrainCullUniforms& u [[buffer(0)]],
                         device const uint* counts [[buffer(4)]],
                         device uint* offsets [[buffer(5)]],
                         device IndirectIndexed* args [[buffer(6)]]) {
    threadgroup uint sums[1024];
    uint n = u.n.x;
    uint per = (n + 1023) / 1024;
    uint begin = min(t * per, n), end = min(begin + per, n);
    bool reverse = l == 3;
    uint local = 0;
    for (uint j = begin; j < end; j++) local += counts[l * n + (reverse ? n - 1 - j : j)];
    sums[t] = local;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint d = 1; d < 1024; d <<= 1) {
        uint v = t >= d ? sums[t - d] : 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        sums[t] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint run = sums[t] - local;   // exclusive
    for (uint j = begin; j < end; j++) {
        uint i = reverse ? n - 1 - j : j;
        offsets[l * n + i] = run;
        run += counts[l * n + i];
    }
    if (t == 1023) {
        IndirectIndexed a;
        a.indexCount = kMeshletQuads * 6;
        a.instanceCount = min(sums[1023], u.cap[l]);
        a.indexStart = 0;
        a.baseVertex = 0;
        a.baseInstance = 0;
        args[l] = a;
    }
}

kernel void terrain_emit(uint i [[thread_position_in_grid]],
                         constant TerrainCullUniforms& u [[buffer(0)]],
                         device const TerrainEntryGpu* entries [[buffer(1)]],
                         device const TerrainSectionMeta* metas [[buffer(2)]],
                         device const uint* offsets [[buffer(5)]],
                         device TerrainMeshletGpu* meshlets [[buffer(7)]]) {
    uint n = u.n.x;
    if (i >= n) return;
    TerrainEntryGpu e = entries[i];
    device const TerrainSectionMeta& m = metas[e.id];
    float3 o = float3(e.x, e.y, e.z);
    for (uint l = 0; l < 4; l++) {
        if (m.verts[l] == 0) continue;
        EmitMeshlets emit{meshlets + u.base[l], offsets[l * n + i], u.cap[l], i, l};
        layerRuns(m, l, o, u, emit);
    }
}

// Section metadata updates: entries copied into the persistent table (in command order).
struct TerrainMetaUpdate {
    uint id;
    uint pad[3];
    TerrainSectionMeta meta;
};

kernel void terrain_meta_scatter(uint i [[thread_position_in_grid]],
                                 constant uint& count [[buffer(0)]],
                                 device const TerrainMetaUpdate* updates [[buffer(1)]],
                                 device TerrainSectionMeta* metas [[buffer(2)]]) {
    if (i >= count) return;
    metas[updates[i].id] = updates[i].meta;
}
