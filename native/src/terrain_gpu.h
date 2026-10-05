// metal189: GPU-driven terrain (shaders/terrain.metal): culling and meshlets on the GPU.
#pragma once
#import "engine.h"
#include <simd/simd.h>

namespace m189 {

struct Section;

// A section's layers or position changed (or it was deleted: s = nullptr).
void terrainMetaChanged(int id, const Section* s);

struct TerrainGpuDraws {
    id<MTLBuffer> records = nil;   // ff.metal TerrainDraw, one per entry
    id<MTLBuffer> meshlets = nil;  // ff.metal TerrainMeshlet: layer l at meshletBase[l]
    uint32_t meshletBase[4] = {};
    id<MTLBuffer> args = nil;      // MTLDrawIndexedPrimitivesIndirectArguments per layer
};

// Encodes the culling of `count` visible sections (ids + vanilla offsets, draw order) into `cb`
// (a command buffer that runs before the frame's render work). False if unavailable.
bool terrainGpuCull(id<MTLCommandBuffer> cb, const uint32_t* ids, const simd_float3* offsets, uint32_t count,
                    const simd_float4x4& mv, simd_float3 eye, bool faceCull, const float chunk[16], TerrainGpuDraws& out);

// The 64-quad index pattern a meshlet instance draws (UInt16, 384 indices).
id<MTLBuffer> terrainMeshletIndices();

} // namespace m189
