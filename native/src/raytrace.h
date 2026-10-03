// metal189: hardware ray tracing scene (terrain acceleration structures).
#pragma once
#import "engine.h"
#include <simd/simd.h>
#include "ff.h"

namespace m189 {

// Per-instance data read by ray-traced shaders (matches RtInstance in adv.metal).
struct RtInstanceData {
    uint64_t verts[3];   // GPU addresses of the vertex buffers, by geometry index
    uint32_t layers;     // render layer of geometry g in bits [2g, 2g+2)
    uint32_t pad;
};

struct RtScene {
    id<MTLAccelerationStructure> tlas = nil;
    id<MTLBuffer> instances = nil;                         // RtInstanceData[instanceCount]
    uint32_t instanceCount = 0;
    const std::vector<id<MTLResource>>* resources = nullptr; // BLASes and vertex buffers the shaders may touch
    simd_float3 camera = {0, 0, 0};                        // camera position in ray tracing space
};

bool rtAvailable();
void rtSectionChanged(int sid);
void rtSectionDeleted(int sid);
// Frees every acceleration structure; sections are rebuilt on demand afterwards.
void rtRelease();

// Builds pending section BLASes (budgeted) and, when needed, the TLAS over sections
// within `radius` blocks of the camera. Returns false when ray tracing is unavailable
// or nothing is built yet.
bool rtPrepare(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, float radius, RtScene& out);

// Captured opaque geometry (entities, block entities) for ray tracing: one record per
// quad draw, as the advanced pipeline collected it.
struct RtEntityDraw {
    id<MTLBuffer> vb;
    size_t offset;              // byte offset of the draw's first vertex
    const VertexLayout* layout;
    uint32_t vertices;          // a multiple of 4
    simd_float4x4 toRt;         // object space -> ray tracing space
    simd_float4x4 texMat;
    simd_float4 color;          // current colour, for layouts without one
    simd_float2 lightmap;       // block, sky light (0..1)
    id<MTLTexture> tex;
    bool alphaTest;
    float alphaRef;
    float emissive;
};

// This frame's entity acceleration structure and the buffers its hit shading reads
// (RtEntVertex / RtEntDraw / RtEntTex in adv.metal). With no entities, `as` is a
// placeholder holding one degenerate triangle and `triangles` is 0.
struct RtEntities {
    id<MTLAccelerationStructure> as = nil;
    id<MTLBuffer> verts = nil, draws = nil, textures = nil;
    const std::vector<id<MTLResource>>* resources = nullptr;   // textures read through the table
    uint32_t triangles = 0;
};

// Converts the draws to ray tracing space and builds the structure into `cb`, ahead of
// the passes that trace it. Returns false when ray tracing is unavailable.
bool rtBuildEntities(id<MTLCommandBuffer> cb, const std::vector<RtEntityDraw>& draws, RtEntities& out);

} // namespace m189
