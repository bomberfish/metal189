// metal189: advanced (deferred PBR) world renderer interface.
#pragma once
#import "engine.h"
#import "commands.h"
#include "adv.h"
#include <vector>

namespace m189 {

struct AdvTerrainEntry {
    uint32_t section;
    float x, y, z;      // camera-relative section origin offset (vanilla preRenderChunk values)
};

// Captured non-terrain geometry routed into the G-buffer / shadow passes.
struct AdvGeometry {
    id<MTLBuffer> vb;
    uint32_t vbOffset;
    int format;
    uint32_t prim, count;
    uint32_t firstVertex;  // arena draws index absolute vertices
    bool indexedArena;
    simd_float4x4 mv;
    simd_float4x4 normal;
    simd_float4x4 texMat;
    int tex;
    uint32_t sampler[8];   // GL sampling parameters at draw time
    bool alphaTest;
    float alphaRef;
    bool cull;
    uint32_t cullFace, frontFace;
    AdvItem item;
};

struct AdvWorld {
    std::vector<AdvTerrainEntry> terrain[4];
    int atlasTex = 0;
    uint32_t layerSampler[4][8] = {};   // atlas sampling parameters per layer (vanilla toggles mipmaps for CUTOUT)
    std::vector<AdvGeometry> geometry;
    simd_float4x4 view, proj;
    EnvCmd env;
    bool hasEnv = false;
    float fogStart = 0, fogEnd = 1;
    float fogColor[4] = {0, 0, 0, 1};
    bool cullOn = true;
};

bool advancedEnabled();
void advancedSetEnabled(bool on);
void advancedSetFeatures(uint32_t flags);
void advancedSetTables(const uint8_t* materials, const uint8_t* emissions);
// Runtime parameters (Pipeline.java OPT_*): 10 shadow resolution, 11 shadow distance,
// 12 exposure %, 13 bloom strength %, 14 release ray tracing resources, 15 waving foliage.
void advancedSetParam(int key, int value);

// Renders the collected world into `color`/`depth` (GL row order).
void advancedRender(id<MTLCommandBuffer> cb, const AdvWorld& w, id<MTLTexture> color, id<MTLTexture> depth);

} // namespace m189
