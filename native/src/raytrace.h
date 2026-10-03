// metal189: hardware ray tracing scene (terrain acceleration structures).
#pragma once
#import "engine.h"
#include <simd/simd.h>

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

// Builds pending section BLASes (budgeted) and, when needed, the TLAS over sections
// within `radius` blocks of the camera. Returns false when ray tracing is unavailable
// or nothing is built yet.
bool rtPrepare(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, float radius, RtScene& out);

} // namespace m189
