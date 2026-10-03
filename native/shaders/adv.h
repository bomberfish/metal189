// metal189 advanced pipeline: shared structures.
#pragma once
#include "ff.h"

// Per-frame constants for the advanced passes. All "view" quantities are in
// Minecraft's eye space (the camera transform recorded at terrain setup).
struct AdvFrame {
    m189_float4x4 proj;          // world projection (GL clip conventions, before the Metal z fix-up)
    m189_float4x4 invProj;
    m189_float4x4 view;          // eye-from-world (world = relative to camera position)
    m189_float4x4 invView;
    m189_float4x4 shadowViewProj; // shadow clip-from-world (Metal clip space)
    m189_float4 sunDirView;      // xyz: towards the sun, eye space; w: sun visible weight (0 night)
    m189_float4 moonDirView;
    m189_float4 sunDirWorld;
    m189_float4 sunColor;        // rgb radiance, a: shadow strength
    m189_float4 moonColor;
    m189_float4 skyZenith;       // rgb
    m189_float4 skyHorizon;      // rgb
    m189_float4 ambient;         // rgb: sky ambient irradiance at full skylight
    m189_float4 blockLight;      // rgb: torch light colour, a: curve exponent
    m189_float4 fog;             // x: start, y: end, z: density (rain), w: in-fluid
    m189_float4 fogColor;
    m189_float4 params;          // x: time seconds, y: rain, z: exposure, w: shadow distance
    m189_float4 screen;          // x: width, y: height, z: 1/width, w: 1/height
    m189_float4 camera;          // xyz: camera position mod 1024 blocks (world-space noise), w: star brightness
    m189_uint4 flags;            // x: feature bits, y: dimension, z: frame index, w: debug view
    m189_float4 rtCam;           // xyz: camera position in ray tracing space (relative to the TLAS origin)
    m189_float4 post;            // x: bloom strength (1 = default)
    m189_float4 jitter;          // xy: sub-pixel projection jitter (GL NDC units), zw: unused
    m189_float4x4 prevViewProj;  // previous frame's proj * view (GL clip, unjittered)
    m189_float4 taa;             // xyz: camera position minus previous camera position, w: history valid
};

#define ADV_SHADOWS   (1u << 0)
#define ADV_BLOOM     (1u << 1)
#define ADV_SKY       (1u << 2)
#define ADV_WATER     (1u << 3)
#define ADV_SSAO      (1u << 4)
#define ADV_PCSS      (1u << 5)
#define ADV_RT_SHADOW (1u << 6)
#define ADV_RT_REFL   (1u << 7)
#define ADV_TAA       (1u << 8)

// Per-item data for G-buffer/shadow draws of captured (non-terrain) geometry.
struct AdvItem {
    m189_float4 color;      // current colour (when the layout has none)
    m189_float4 normal;     // current normal (when the layout has none), w unused
    m189_float4 lightmap;   // xy: current lightmap coords (0..240) for layouts without them
    m189_float4 alpha;      // x: alpha ref, y: alpha func (GL enum - 0x200), z: emissive, w: material id
};
