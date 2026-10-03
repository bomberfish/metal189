// metal189: structures shared by the fixed-function-equivalent shaders and the
// native executor. Only 16-byte vector types are used so C++ and MSL layouts match.
#pragma once

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
typedef float4x4 m189_float4x4;
typedef float4 m189_float4;
typedef uint4 m189_uint4;
typedef int4 m189_int4;
#else
#include <simd/simd.h>
typedef simd_float4x4 m189_float4x4;
typedef simd_float4 m189_float4;
typedef simd_uint4 m189_uint4;
typedef simd_int4 m189_int4;
#endif

// Vertex layout for vertex pulling. Each attribute: x = byte offset (-1 = absent),
// y = GL type enum, z = component count, w = normalised flag.
struct VertexLayout {
    m189_int4 pos;
    m189_int4 color;
    m189_int4 tex0;
    m189_int4 tex1;
    m189_int4 normal;
    m189_uint4 stride; // x = stride in bytes
};

// flags (FFUniforms.flags.x)
#define FF_LIGHTING        (1u << 0)
#define FF_LIGHT0          (1u << 1)
#define FF_LIGHT1          (1u << 2)
#define FF_COLOR_MATERIAL  (1u << 3)
#define FF_CM_AMBIENT_ONLY (1u << 4)   // glColorMaterial(.., GL_AMBIENT)
#define FF_NORMALIZE       (1u << 5)
#define FF_FOG             (1u << 6)
#define FF_TEX0            (1u << 7)
#define FF_TEX1            (1u << 8)
#define FF_TEX2            (1u << 9)
#define FF_TEXGEN_S        (1u << 10)
#define FF_TEXGEN_T        (1u << 11)
#define FF_TEXGEN_R        (1u << 12)
#define FF_TEXGEN_Q        (1u << 13)
#define FF_FOG_RADIAL      (1u << 14)
#define FF_FLIP_Y          (1u << 15)

// texgen mode per coordinate (2 bits each in FFUniforms.flags.y): 0 object, 1 eye
// fog mode in flags.z: 0 linear, 1 exp, 2 exp2. alpha func in flags.w (GL enum - 0x200).

// Texture environment per unit, packed:
//   env[u].x = mode (0 modulate, 1 replace, 2 decal, 3 blend, 4 add, 5 combine)
//   env[u].y = combine RGB fn | combine A fn << 8  (0 replace,1 modulate,2 add,3 add_signed,4 interpolate,5 subtract,6 dot3rgb,7 dot3rgba)
//   env[u].z = sources: 3 bits each, rgb0 rgb1 rgb2 a0 a1 a2 (0 texture,1 constant,2 primary,3 previous,4+n texture unit n)
//   env[u].w = operands: 2 bits each, rgb0 rgb1 rgb2 a0 a1 a2 (0 src_color,1 one_minus_src_color,2 src_alpha,3 one_minus_src_alpha)
struct FFUniforms {
    m189_float4x4 proj;        // GL projection, already followed by the clip-space fix-up
    m189_float4x4 modelview;
    m189_float4x4 normalMatrix;
    m189_float4x4 texMatrix0;
    m189_float4x4 texMatrix1;
    m189_float4 color;         // current colour (used when the layout has no colour)
    m189_float4 normal;        // current normal
    m189_float4 texCoord0;
    m189_float4 texCoord1;
    m189_float4 lightPos[2];   // eye space
    m189_float4 lightDiffuse[2];
    m189_float4 lightAmbient[2];
    m189_float4 lightModelAmbient;
    m189_float4 fogColor;
    m189_float4 fogParams;     // start, end, density, 1/(end-start)
    m189_float4 envColor[3];
    m189_float4 envScale[3];   // x = rgb scale, y = alpha scale
    m189_float4 texGenPlane[4];
    m189_float4 alpha;         // x = alpha ref
    m189_uint4 flags;
    m189_uint4 env[3];
    m189_float4 raster;        // x: point size, y: line stipple factor (0 = off), z: stipple pattern
};

// Per-draw transform, bound inline at buffer(3) for every draw.
struct DrawTransform {
    m189_float4x4 modelview;
    m189_float4 normal0, normal1, normal2; // columns of the normal matrix
};

// Clear quad parameters.
struct ClearUniforms {
    m189_float4 color;
    m189_float4 depth;          // x = depth (0..1)
};
