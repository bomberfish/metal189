// metal189: Java -> native per-frame command stream format.
//
// The stream is a sequence of 4-byte aligned records. Each record starts with
// a header word: low 16 bits = opcode, high 16 bits = record length in words
// (including the header). Payload layouts are mirrored in
// metal189.engine.Cmd on the Java side.
#pragma once
#include <cstdint>
#include <cstddef>

namespace m189 {

enum Op : uint16_t {
    OP_NOP = 0,
    OP_STATE_PIPE = 2,
    OP_STATE_DEPTH = 3,
    OP_STATE_RASTER = 4,
    OP_STATE_FRAG = 5,
    OP_STATE_UNITS = 6,
    OP_STATE_TEXGEN = 7,
    OP_STATE_LIGHT = 8,
    OP_STATE_ATTRIB = 9,
    OP_STATE_VIEWPORT = 10,
    OP_MATRIX = 11,
    OP_DRAW = 12,
    OP_DRAW_MESH = 13,
    OP_TARGET = 14,
    OP_CLEAR = 15,
    OP_COPY_TEX = 16,
    OP_PHASE = 17,
    OP_TERRAIN = 18,
    OP_ENV = 19,
};

enum Phase : uint32_t {
    PH_UI = 0, PH_WORLD_BEGIN = 1, PH_SKY = 2, PH_CLOUDS = 3, PH_TERRAIN = 4, PH_ENTITIES = 5, PH_OUTLINE = 6,
    PH_DESTROY = 7, PH_LIT_PARTICLES = 8, PH_PARTICLES = 9, PH_WEATHER = 10, PH_WORLD_BORDER = 11,
    PH_ENTITIES_TRANSLUCENT = 12, PH_RENDER_LAST = 13, PH_HAND = 14, PH_WORLD_END = 15,
};

struct PipeState { uint32_t blend, srcRGB, dstRGB, srcA, dstA, eq, colorMask, logicOn, logicOp; };
struct DepthState { uint32_t test, func, mask, stencil; };
struct RasterState { uint32_t cull, cullFace, frontFace, polyFill; float factor, units, lineWidth; uint32_t flat; };
struct FragState {
    uint32_t alphaTest, alphaFunc; float alphaRef;
    uint32_t fog, fogMode, fogDistMode; float fogStart, fogEnd, fogDensity; float fogColor[4];
};
struct UnitState {
    uint32_t enabled, tex, mode, combineRGB, combineA;
    uint32_t srcRGB[3], srcA[3], opRGB[3], opA[3];
    float envColor[4]; float rgbScale, alphaScale;
    // sampling parameters of the bound texture at draw time (GL texture-object state)
    uint32_t minFilter, magFilter, wrapS, wrapT, maxLevel;
    float minLod, maxLod, aniso;
};
struct TexGenState { uint32_t bits; uint32_t mode[4]; float objPlane[16]; float eyePlane[16]; };
struct LightState {
    uint32_t lighting, lightBits, colorMaterial, colorMaterialMode, normFlags;
    float pos[2][4], diffuse[2][4], ambient[2][4], modelAmbient[4];
};
struct AttribState { float color[4]; float normal[3]; float tex0[4]; float tex1[4]; };
struct ViewportState { int32_t vp[4]; uint32_t scissor; int32_t sc[4]; };

static_assert(sizeof(PipeState) == 9 * 4, "");
static_assert(sizeof(DepthState) == 4 * 4, "");
static_assert(sizeof(RasterState) == 8 * 4, "");
static_assert(sizeof(FragState) == 13 * 4, "");
static_assert(sizeof(UnitState) == 31 * 4, "");
static_assert(sizeof(TexGenState) == 37 * 4, "");
static_assert(sizeof(LightState) == 33 * 4, "");
static_assert(sizeof(AttribState) == 15 * 4, "");
static_assert(sizeof(ViewportState) == 9 * 4, "");

struct DrawCmd { uint32_t prim, format, count, chunk, offset; };
struct DrawMeshCmd { uint32_t prim, format, mesh, offset, count; };
struct TargetCmd { uint32_t fbo, colorTex, depth; };
struct ClearCmd { uint32_t mask; float r, g, b, a, depth; uint32_t stencil; };
struct CopyTexCmd { uint32_t tex, level; int32_t xoff, yoff, x, y, w, h; };
struct TerrainCmd { uint32_t layer, format, count; };
struct EnvCmd {
    float view[16];       // modelview at terrain setup (camera transform)
    float proj[16];       // world projection
    int32_t camBlockX; float camFracX; int32_t camBlockY; float camFracY; int32_t camBlockZ; float camFracZ;
    float partialTicks, celestialAngle, sunBrightness, starBrightness;
    float skyR, skyG, skyB;
    float rain, thunder;
    int32_t moonPhase, dimension, dayTime;
    float timeSeconds;
    int32_t inFluid;      // 0 none, 1 water, 2 lava
    float renderDistance;
    float rotationX;
    int32_t handLight;    // light level of the player's held item (dynamic light), 0-15
};
struct TerrainEntry { uint32_t section; float x, y, z; };

struct CmdHeader {
    uint16_t op;
    uint16_t words;
};
static_assert(sizeof(CmdHeader) == 4, "header is one word");

class CmdReader {
public:
    CmdReader(const uint8_t* p, size_t len) : p_(p), end_(p + len) {}
    const CmdHeader* next() {
        if (p_ + sizeof(CmdHeader) > end_) return nullptr;
        const CmdHeader* h = (const CmdHeader*)p_;
        if (h->words == 0 || p_ + h->words * 4u > end_) return nullptr;
        p_ += h->words * 4u;
        return h;
    }
private:
    const uint8_t* p_;
    const uint8_t* end_;
};

template <typename T> inline const T& payload(const CmdHeader* h) { return *(const T*)(h + 1); }

} // namespace m189
