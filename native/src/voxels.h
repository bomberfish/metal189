// metal189: block voxel volume around the camera for world-space reflections
// (reflections of off-screen terrain without hardware ray tracing).
#pragma once
#import "engine.h"
#include <simd/simd.h>

namespace m189 {

struct VoxelScene {
    id<MTLTexture> tex = nil;   // RGBA16Uint, N^3, toroidal: texel = (block + wrap) mod N
    id<MTLTexture> shape = nil; // RG32Uint, N^3: the shapes of partial blocks
    id<MTLTexture> occ = nil;   // R8Uint, (N/4)^3: 1 where a 4-block brick holds any block
    simd_int4 wrap = {0, 0, 0, 0};     // xyz: volume origin mod N, w: N
    simd_float4 cam = {0, 0, 0, 0};    // xyz: camera position relative to the volume origin (blocks)
    bool valid = false;
};

// Re-voxelizes the sections that changed or came into range (budgeted, closest first)
// into `cb` and describes the volume for the shaders.
bool voxelsUpdate(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, int atlasW, int atlasH, VoxelScene& out);
// Frees the volume (about 34 MB) while world-space reflections are not in use.
void voxelsRelease();

} // namespace m189
