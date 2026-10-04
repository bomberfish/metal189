// metal189: per-frame command-stream executor.
//
// Replays the GL-semantics state and draws captured on the Java side into
// Metal render passes. Offscreen targets keep GL row order (row 0 = bottom), so
// draws into them flip clip-space Y; the screen target is Metal-oriented.

#import "engine.h"
#import "commands.h"
#import "resources.h"
#import "advanced.h"
#import "gpu_profiler.h"
#include <unordered_map>
#include <cstring>

namespace m189 {

// Per-frame statistics (logged with -Dmetal189.gpuStats=true).
struct FrameStats { uint64_t draws, terrainDraws, terrainQuads, arenaDraws, meshDraws, passes, terrainDrawn, drawCalls; };
bool g_optFaceCull = true;
bool g_optTerrainSplit = false;
static FrameStats g_stats, g_statsAcc;
static int g_statsFrames;

// Runtime options (set from Java, see metal189.engine.Native.setOption).
int g_optQuadDiagonal = 1; // 1: split quads along v1-v3 like Apple's GL, 0: along v0-v2

extern bool g_optPresent;
extern bool g_optGpuStats;
extern bool g_optSerialGpu;
int g_optAdvDebug = 0; // advanced pipeline debug view (see light_fragment)
extern bool g_ctrlClickRight;

void setOption(int key, int value) {
    switch (key) {
        case 1: g_optQuadDiagonal = value; break;
        case 2: g_optPresent = value != 0; break;
        case 3: g_optGpuStats = value != 0; break;
        case 4: g_optAdvDebug = value; break;
        case 5: g_ctrlClickRight = value != 0; break;
        case 7: g_optFaceCull = value != 0; break;
        case 8: g_optSerialGpu = value != 0; break;
        case 9: g_optTerrainSplit = value != 0; break;
        default: if (key >= 10) advancedSetParam(key, value); break;
    }
}

// ---------------------------------------------------------------------------
// persistent GL state mirror

struct GLMirror {
    // GL's initial state (the Java side sends the real state before the first draw)
    PipeState pipe{0, 1, 0, 1, 0, 0x8006, 0xF, 0, 0x1503, {0, 0, 0, 0}};
    DepthState depth{0, 0x201, 1, 0, 0x207, 0, 0xFFFFFFFFu, 0x1E00, 0x1E00, 0x1E00, 0xFFFFFFFFu};
    RasterState raster{0, 0x405, 0x901, 0, 0, 0, 1, 0, 1, 0x1B02, 0, 0};
    FragState frag{0, 0x207, 0, 0, 0x0800, 0x855C, 0, 1, 1, {0, 0, 0, 0}};
    UnitState units[3];
    TexGenState texgen{};
    LightState light{};
    AttribState attrib{{1, 1, 1, 1}, {0, 0, 1}, {0, 0, 0, 1}, {0, 0, 0, 1}};
    ViewportState vp{{0, 0, 1, 1}, 0, {0, 0, 1, 1}};
    simd_float4x4 mv = matrix_identity_float4x4, proj = matrix_identity_float4x4;
    simd_float4x4 tex[3] = {matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4};
    simd_float4x4 normal = matrix_identity_float4x4;
    bool uniformsDirty = true;
};
static GLMirror g;

// Latest environment (camera, sun, sky) and the current world phase.
EnvCmd g_env{};
bool g_envValid = false;
uint32_t g_phase = PH_UI;

// ---------------------------------------------------------------------------
// pipeline / depth-state caches

struct PipeKey {
    uint32_t color, depth, stencil;
    uint32_t blend;      // packed blend state, 0 = disabled
    uint32_t blendEq;
    uint32_t writeMask;
    uint32_t variant;    // bit0 alphaTest, bit1 logicOp, bit2 flat, bit3 terrain, bit4 modulate, bit5 wide line,
                         // bit6 lit by the advanced pipeline
    bool operator==(const PipeKey& o) const { return memcmp(this, &o, sizeof *this) == 0; }
};
struct PipeKeyHash {
    size_t operator()(const PipeKey& k) const {
        const uint32_t* p = (const uint32_t*)&k;
        size_t h = 1469598103934665603ull;
        for (size_t i = 0; i < sizeof k / 4; i++) h = (h ^ p[i]) * 1099511628211ull;
        return h;
    }
};

static std::unordered_map<PipeKey, id<MTLRenderPipelineState>, PipeKeyHash> g_pipes;
static std::unordered_map<uint64_t, id<MTLDepthStencilState>> g_dss;
static id<MTLFunction> g_vfn[32], g_ffn[32], g_lineVfn[32];
static id<MTLFunction> g_litVfn[32], g_litFfn[32];   // fc_advLit variants (non-terrain)
static id<MTLFunction> g_clearV, g_clearF;
static id<MTLBuffer> g_quadIndices, g_flatQuadIndices;
static uint32_t g_quadIndexQuads = 0, g_flatQuadIndexQuads = 0;

static MTLBlendFactor blendFactor(uint32_t gl) {
    switch (gl) {
        case 0: return MTLBlendFactorZero;
        case 1: return MTLBlendFactorOne;
        case 0x300: return MTLBlendFactorSourceColor;
        case 0x301: return MTLBlendFactorOneMinusSourceColor;
        case 0x302: return MTLBlendFactorSourceAlpha;
        case 0x303: return MTLBlendFactorOneMinusSourceAlpha;
        case 0x304: return MTLBlendFactorDestinationAlpha;
        case 0x305: return MTLBlendFactorOneMinusDestinationAlpha;
        case 0x306: return MTLBlendFactorDestinationColor;
        case 0x307: return MTLBlendFactorOneMinusDestinationColor;
        case 0x308: return MTLBlendFactorSourceAlphaSaturated;
        case 0x8001: return MTLBlendFactorBlendColor;
        case 0x8002: return MTLBlendFactorOneMinusBlendColor;
        case 0x8003: return MTLBlendFactorBlendAlpha;
        case 0x8004: return MTLBlendFactorOneMinusBlendAlpha;
        default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blendOp(uint32_t gl) {
    switch (gl) {
        case 0x800A: return MTLBlendOperationSubtract;
        case 0x800B: return MTLBlendOperationReverseSubtract;
        case 0x8007: return MTLBlendOperationMin;
        case 0x8008: return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

static MTLCompareFunction compareFn(uint32_t gl) {
    switch (gl) {
        case 0x200: return MTLCompareFunctionNever;
        case 0x201: return MTLCompareFunctionLess;
        case 0x202: return MTLCompareFunctionEqual;
        case 0x203: return MTLCompareFunctionLessEqual;
        case 0x204: return MTLCompareFunctionGreater;
        case 0x205: return MTLCompareFunctionNotEqual;
        case 0x206: return MTLCompareFunctionGreaterEqual;
        default: return MTLCompareFunctionAlways;
    }
}

static uint32_t blendIndex(uint32_t gl) {
    switch (gl) {
        case 0: return 0; case 1: return 1;
        case 0x8001: return 12; case 0x8002: return 13; case 0x8003: return 14; case 0x8004: return 15;
        default: return gl >= 0x300 && gl <= 0x308 ? 2 + (gl - 0x300) : 1;
    }
}

static uint32_t indexToGL(uint32_t i) {
    static const uint32_t t[16] = {0, 1, 0x300, 0x301, 0x302, 0x303, 0x304, 0x305, 0x306, 0x307, 0x308, 1, 0x8001, 0x8002, 0x8003, 0x8004};
    return t[i & 15];
}

bool executorInit() {
    Engine& e = engine();
    if (!e.library) { log("no shader library"); return false; }
    for (int v = 0; v < 32; v++) {
        MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
        bool alpha = v & 1, logic = (v >> 1) & 1, flat = (v >> 2) & 1, terrain = (v >> 3) & 1, modulate = (v >> 4) & 1;
        [cv setConstantValue:&alpha type:MTLDataTypeBool atIndex:0];
        [cv setConstantValue:&logic type:MTLDataTypeBool atIndex:1];
        [cv setConstantValue:&flat type:MTLDataTypeBool atIndex:2];
        [cv setConstantValue:&terrain type:MTLDataTypeBool atIndex:3];
        [cv setConstantValue:&modulate type:MTLDataTypeBool atIndex:4];
        bool lit = false;
        [cv setConstantValue:&lit type:MTLDataTypeBool atIndex:5];
        NSError* err = nil;
        bool slim = terrain && modulate && !flat && !logic;   // terrain_vertex_slim / terrain_fragment
        g_vfn[v] = [e.library newFunctionWithName:(slim ? @"terrain_vertex_slim" : terrain ? @"terrain_vertex" : @"ff_vertex")
                                    constantValues:cv error:&err];
        if (!g_vfn[v]) { log("ff_vertex: %s", err.localizedDescription.UTF8String); return false; }
        g_ffn[v] = [e.library newFunctionWithName:(slim ? @"terrain_fragment" : @"ff_fragment") constantValues:cv error:&err];
        if (!g_ffn[v]) { log("ff_fragment: %s", err.localizedDescription.UTF8String); return false; }
        if (!terrain) {
            g_lineVfn[v] = [e.library newFunctionWithName:@"ff_line_vertex" constantValues:cv error:&err];
            if (!g_lineVfn[v]) log("ff_line_vertex: %s", err.localizedDescription.UTF8String);
            MTLFunctionConstantValues* lv = [cv copy];
            lit = true;
            [lv setConstantValue:&lit type:MTLDataTypeBool atIndex:5];
            g_litVfn[v] = [e.library newFunctionWithName:@"ff_vertex" constantValues:lv error:&err];
            g_litFfn[v] = [e.library newFunctionWithName:@"ff_fragment" constantValues:lv error:&err];
            if (!g_litVfn[v] || !g_litFfn[v]) log("ff advLit variant: %s", err.localizedDescription.UTF8String);
        }
    }
    g_clearV = [e.library newFunctionWithName:@"clear_vertex"];
    g_clearF = [e.library newFunctionWithName:@"clear_fragment"];
    for (int u = 0; u < 3; u++) {
        UnitState& s = g.units[u];
        memset(&s, 0, sizeof s);
        s.mode = 0x2100;
        s.combineRGB = s.combineA = 0x2100;
        s.srcRGB[0] = s.srcA[0] = 0x1702; s.srcRGB[1] = s.srcA[1] = 0x8578; s.srcRGB[2] = s.srcA[2] = 0x8576;
        s.opRGB[0] = s.opRGB[1] = 0x300; s.opRGB[2] = 0x302;
        s.opA[0] = s.opA[1] = s.opA[2] = 0x302;
        s.rgbScale = s.alphaScale = 1;
        s.minFilter = 0x2702; s.magFilter = 0x2601; s.wrapS = s.wrapT = 0x2901;
        s.maxLevel = 1000; s.minLod = -1000; s.maxLod = 1000; s.aniso = 1;
    }
    g.light.lightBits = 0;
    g.light.modelAmbient[0] = g.light.modelAmbient[1] = g.light.modelAmbient[2] = 0.2f;
    g.light.modelAmbient[3] = 1.0f;
    return true;
}

static id<MTLRenderPipelineState> pipeline(const PipeKey& k) {
    auto it = g_pipes.find(k);
    if (it != g_pipes.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    bool lit = (k.variant & 64) != 0;
    d.vertexFunction = (k.variant & 32) ? g_lineVfn[k.variant & 31] : lit ? g_litVfn[k.variant & 31] : g_vfn[k.variant & 31];
    if (!d.vertexFunction) return nil;
    d.fragmentFunction = lit ? g_litFfn[k.variant & 31] : g_ffn[k.variant & 31];
    if (!d.fragmentFunction) return nil;
    MTLRenderPipelineColorAttachmentDescriptor* c = d.colorAttachments[0];
    c.pixelFormat = (MTLPixelFormat)k.color;
    if (k.blend) {
        c.blendingEnabled = YES;
        c.sourceRGBBlendFactor = blendFactor(indexToGL(k.blend & 15));
        c.destinationRGBBlendFactor = blendFactor(indexToGL((k.blend >> 4) & 15));
        c.sourceAlphaBlendFactor = blendFactor(indexToGL((k.blend >> 8) & 15));
        c.destinationAlphaBlendFactor = blendFactor(indexToGL((k.blend >> 12) & 15));
        c.rgbBlendOperation = c.alphaBlendOperation = blendOp(k.blendEq);
    }
    MTLColorWriteMask m = MTLColorWriteMaskNone;
    if (k.writeMask & 1) m |= MTLColorWriteMaskRed;
    if (k.writeMask & 2) m |= MTLColorWriteMaskGreen;
    if (k.writeMask & 4) m |= MTLColorWriteMaskBlue;
    if (k.writeMask & 8) m |= MTLColorWriteMaskAlpha;
    c.writeMask = m;
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k.depth;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k.stencil;
    NSError* err = nil;
    id<MTLRenderPipelineState> ps = [device() newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) log("pipeline creation failed: %s", err.localizedDescription.UTF8String);
    g_pipes[k] = ps;
    return ps;
}

static id<MTLRenderPipelineState> clearPipeline(uint32_t color, uint32_t depth, uint32_t stencil, uint32_t mask) {
    PipeKey k{color, depth, stencil, 0, 0, mask, 0x100};
    auto it = g_pipes.find(k);
    if (it != g_pipes.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = g_clearV;
    d.fragmentFunction = g_clearF;
    d.colorAttachments[0].pixelFormat = (MTLPixelFormat)color;
    MTLColorWriteMask m = MTLColorWriteMaskNone;
    if (mask & 1) m |= MTLColorWriteMaskRed;
    if (mask & 2) m |= MTLColorWriteMaskGreen;
    if (mask & 4) m |= MTLColorWriteMaskBlue;
    if (mask & 8) m |= MTLColorWriteMaskAlpha;
    d.colorAttachments[0].writeMask = m;
    d.depthAttachmentPixelFormat = (MTLPixelFormat)depth;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)stencil;
    NSError* err = nil;
    id<MTLRenderPipelineState> ps = [device() newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) log("clear pipeline failed: %s", err.localizedDescription.UTF8String);
    g_pipes[k] = ps;
    return ps;
}

static MTLStencilOperation stencilOperation(uint32_t gl) {
    switch (gl) {
        case 0: return MTLStencilOperationZero;
        case 0x1E01: return MTLStencilOperationReplace;
        case 0x1E02: return MTLStencilOperationIncrementClamp;
        case 0x1E03: return MTLStencilOperationDecrementClamp;
        case 0x150A: return MTLStencilOperationInvert;
        case 0x8507: return MTLStencilOperationIncrementWrap;
        case 0x8508: return MTLStencilOperationDecrementWrap;
        default: return MTLStencilOperationKeep;   // GL_KEEP
    }
}

// st: stencil state to apply (null when the stencil test is off or the target has no stencil).
static id<MTLDepthStencilState> depthState(bool test, uint32_t func, bool write, const DepthState* st = nullptr) {
    uint64_t key = (test ? 1 : 0) | (write ? 2 : 0) | (uint64_t)(func & 0xF) << 4;
    if (st) {
        key |= 1ull << 8 | (uint64_t)(st->sFunc & 0xF) << 9 | (uint64_t)stencilOperation(st->sFail) << 13 |
               (uint64_t)stencilOperation(st->sZFail) << 16 | (uint64_t)stencilOperation(st->sZPass) << 19 |
               (uint64_t)(st->sValueMask & 0xFF) << 22 | (uint64_t)(st->sWriteMask & 0xFF) << 30;
    }
    auto it = g_dss.find(key);
    if (it != g_dss.end()) return it->second;
    MTLDepthStencilDescriptor* d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = test ? compareFn(func) : MTLCompareFunctionAlways;
    d.depthWriteEnabled = test && write; // GL never writes depth with the test disabled
    if (st) {
        MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = compareFn(st->sFunc);
        sd.stencilFailureOperation = stencilOperation(st->sFail);
        sd.depthFailureOperation = stencilOperation(st->sZFail);
        sd.depthStencilPassOperation = stencilOperation(st->sZPass);
        sd.readMask = st->sValueMask & 0xFF;
        sd.writeMask = st->sWriteMask & 0xFF;
        d.frontFaceStencil = sd;
        d.backFaceStencil = sd;
    }
    id<MTLDepthStencilState> s = [device() newDepthStencilStateWithDescriptor:d];
    g_dss[key] = s;
    return s;
}

// Flat-shaded quads: GL's provoking vertex (v3) first in both triangles.
static id<MTLBuffer> flatQuadIndices(uint32_t quads) {
    if (quads <= g_flatQuadIndexQuads && g_flatQuadIndices) return g_flatQuadIndices;
    uint32_t n = std::max<uint32_t>(quads, 65536);
    n = (n + 65535) & ~65535u;
    id<MTLBuffer> b = [device() newBufferWithLength:(size_t)n * 6 * 4 options:MTLResourceStorageModeShared];
    uint32_t* p = (uint32_t*)b.contents;
    for (uint32_t q = 0; q < n; q++) {
        uint32_t v = q * 4;
        p[q * 6 + 0] = v + 3; p[q * 6 + 1] = v; p[q * 6 + 2] = v + 1;
        p[q * 6 + 3] = v + 3; p[q * 6 + 4] = v + 1; p[q * 6 + 5] = v + 2;
    }
    g_flatQuadIndices = b;
    g_flatQuadIndexQuads = n;
    return b;
}

static id<MTLBuffer> quadIndices(uint32_t quads) {
    if (quads <= g_quadIndexQuads && g_quadIndices) return g_quadIndices;
    uint32_t n = std::max<uint32_t>(quads, 65536);
    n = (n + 65535) & ~65535u;
    id<MTLBuffer> b = [device() newBufferWithLength:(size_t)n * 6 * 4 options:MTLResourceStorageModeShared];
    uint32_t* p = (uint32_t*)b.contents;
    for (uint32_t q = 0; q < n; q++) {
        uint32_t v = q * 4;
        if (g_optQuadDiagonal) {
            p[q * 6 + 0] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 3;
            p[q * 6 + 3] = v + 1; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        } else {
            p[q * 6 + 0] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 2;
            p[q * 6 + 3] = v; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        }
    }
    g_quadIndices = b;
    g_quadIndexQuads = n;
    return b;
}

// ---------------------------------------------------------------------------
// executor

namespace {

enum PrimClass { PC_TRI = 0, PC_LINE = 1, PC_POINT = 2 };

static PrimClass primClass(uint32_t glPrim) {
    if (glPrim == 0) return PC_POINT;
    if (glPrim >= 1 && glPrim <= 3) return PC_LINE;
    return PC_TRI;
}

static MTLPrimitiveType metalPrim(PrimClass c) {
    return c == PC_POINT ? MTLPrimitiveTypePoint : c == PC_LINE ? MTLPrimitiveTypeLine : MTLPrimitiveTypeTriangle;
}

// Number of indices generated for a GL primitive of n vertices.
static uint32_t indexCount(uint32_t prim, uint32_t n) {
    switch (prim) {
        case 0: return n;
        case 1: return n & ~1u;
        case 2: return n >= 2 ? n * 2 : 0;
        case 3: return n >= 2 ? (n - 1) * 2 : 0;
        case 4: return n - n % 3;
        case 5: case 6: case 9: return n >= 3 ? (n - 2) * 3 : 0;
        case 7: return (n / 4) * 6;
        case 8: return n >= 4 ? ((n - 2) / 2) * 6 : 0;
        default: return 0;
    }
}

// Writes GL-equivalent indices. With flat shading the GL provoking vertex is
// placed first in every primitive (Metal's provoking-vertex convention).
static void writeIndices(uint32_t* o, uint32_t prim, uint32_t n, uint32_t b, bool flat) {
    switch (prim) {
        case 0: for (uint32_t i = 0; i < n; i++) *o++ = b + i; break;
        case 1:
            for (uint32_t i = 0; i + 1 < n; i += 2) {
                if (flat) { *o++ = b + i + 1; *o++ = b + i; } else { *o++ = b + i; *o++ = b + i + 1; }
            }
            break;
        case 2: case 3: {
            uint32_t segs = prim == 2 ? n : n - 1;
            for (uint32_t i = 0; i < segs; i++) {
                uint32_t a = b + i, c = b + (i + 1) % n;
                if (flat) { *o++ = c; *o++ = a; } else { *o++ = a; *o++ = c; }
            }
            break;
        }
        case 4:
            for (uint32_t i = 0; i + 2 < n; i += 3) {
                if (flat) { *o++ = b + i + 2; *o++ = b + i; *o++ = b + i + 1; }
                else { *o++ = b + i; *o++ = b + i + 1; *o++ = b + i + 2; }
            }
            break;
        case 5:
            for (uint32_t k = 0; k + 2 < n; k++) {
                uint32_t a = b + k, c = b + k + 1, d = b + k + 2;
                if (k & 1) std::swap(a, c);
                if (flat) { *o++ = d; *o++ = a; *o++ = c; } else { *o++ = a; *o++ = c; *o++ = d; }
            }
            break;
        case 6:
            for (uint32_t k = 0; k + 2 < n; k++) {
                if (flat) { *o++ = b + k + 2; *o++ = b; *o++ = b + k + 1; }
                else { *o++ = b; *o++ = b + k + 1; *o++ = b + k + 2; }
            }
            break;
        case 9:
            for (uint32_t k = 0; k + 2 < n; k++) { *o++ = b; *o++ = b + k + 1; *o++ = b + k + 2; }
            break;
        case 7:
            for (uint32_t q = 0; q + 3 < n; q += 4) {
                uint32_t v0 = b + q, v1 = v0 + 1, v2 = v0 + 2, v3 = v0 + 3;
                if (flat) { *o++ = v3; *o++ = v0; *o++ = v1; *o++ = v3; *o++ = v1; *o++ = v2; }
                else if (g_optQuadDiagonal) { *o++ = v0; *o++ = v1; *o++ = v3; *o++ = v1; *o++ = v2; *o++ = v3; }
                else { *o++ = v0; *o++ = v1; *o++ = v2; *o++ = v0; *o++ = v2; *o++ = v3; }
            }
            break;
        case 8:
            for (uint32_t k = 0; k + 3 < n; k += 2) {
                uint32_t v0 = b + k, v1 = v0 + 1, v2 = v0 + 3, v3 = v0 + 2; // quad (2k, 2k+1, 2k+3, 2k+2)
                if (flat) { *o++ = v2; *o++ = v0; *o++ = v1; *o++ = v2; *o++ = v3; *o++ = v0; }
                else { *o++ = v0; *o++ = v1; *o++ = v2; *o++ = v0; *o++ = v2; *o++ = v3; }
            }
            break;
        default: break;
    }
}

struct Target {
    uint32_t fbo = 0xFFFFFFFF, colorId = 0, depthId = 0;
    id<MTLTexture> color = nil, depth = nil;
    int w = 1, h = 1;
    bool flip = false;
    bool valid = false;
};

struct Exec {
    id<MTLCommandBuffer> cb;
    FrameResources* fr;
    Target cur;
    id<MTLRenderCommandEncoder> enc = nil;
    // clear to fold into the next pass's load actions
    bool pendColor = false, pendDepth = false, pendStencil = false;
    MTLClearColor pendColorValue = {0, 0, 0, 0};
    double pendDepthValue = 1.0;
    uint32_t pendStencilValue = 0;
    // encoder state cache
    id<MTLRenderPipelineState> bPso = nil;
    id<MTLDepthStencilState> bDss = nil;
    int bCull = -1, bWinding = -1;
    float bBlendColor[4] = {NAN, NAN, NAN, NAN};
    bool wideLine = false;  // the draw being prepared expands lines into quads (glLineWidth > 1)
    bool bLitBound = false; // advanced lighting inputs bound on this encoder
    int bStencilRef = -1;
    float bBiasUnits = NAN, bBiasFactor = NAN;
    bool bViewportValid = false, bScissorValid = false;
    MTLViewport bViewport{};
    MTLScissorRect bScissor{};
    id bTex[3] = {nil, nil, nil}, bSmp[3] = {nil, nil, nil};
    id<MTLBuffer> bVb = nil;
    size_t bVbOffset = SIZE_MAX;
    int bFormat = -1;
    size_t bUniOffset = SIZE_MAX;
    bool flipForUniforms = false;
    size_t uniOffset = SIZE_MAX;
    uint32_t uniMask = 0;
    bool xfDirty = true;    // modelview changed since the transform was last bound
    bool stateDirty = true; // any non-matrix GL state changed since the last fully prepared draw
    uint32_t lastPrimClass = 0xFF;
    int lastFormat = -1;
    bool lastTerrain = false;
    bool lastOk = false;
    bool advReplay = false;  // replaying a world segment already rendered by the advanced pipeline
    int auxDepth = 0;        // inside auxiliary world segments (rendered with the baseline, no filtering)
    bool advReplaySaved = false;
    // batch of merged arena draws
    bool batchOpen = false;
    PrimClass batchClass = PC_TRI;
    id<MTLBuffer> batchVb = nil;
    int batchFormat = 0;
    id<MTLBuffer> batchIdx = nil;
    size_t batchIdxStart = 0;
    uint32_t batchIdxCount = 0;
    bool batchFlat = false;
};

static void flushBatch(Exec& x) {
    if (!x.batchOpen) return;
    x.batchOpen = false;
    if (x.batchIdxCount == 0 || !x.enc) return;
    [x.enc drawIndexedPrimitives:metalPrim(x.batchClass) indexCount:x.batchIdxCount indexType:MTLIndexTypeUInt32
                     indexBuffer:x.batchIdx indexBufferOffset:x.batchIdxStart * 4];
    g_stats.arenaDraws++;
}

static void endPass(Exec& x) {
    flushBatch(x);
    if (x.enc) {
        [x.enc endEncoding];
        x.enc = nil;
    }
}

static void resolveTarget(Exec& x, const TargetCmd& t) {
    Engine& e = engine();
    Target nt;
    nt.fbo = t.fbo;
    nt.colorId = t.colorTex;
    nt.depthId = t.depth;
    if (t.fbo == 0) {
        ensureScreenTargets();
        nt.color = e.screenColor;
        nt.depth = e.screenDepth;
        nt.flip = false;
    } else {
        TexEntry* c = t.colorTex ? texture(t.colorTex) : nullptr;
        nt.color = c ? c->tex : nil;
        if (t.depth & 0x40000000) {
            TexEntry* r = renderbuffer(t.depth & 0x3FFFFFFF);
            nt.depth = r ? r->tex : nil;
        } else if (t.depth) {
            TexEntry* d = texture(t.depth);
            nt.depth = d ? d->tex : nil;
        }
        nt.flip = true;
    }
    id<MTLTexture> ref = nt.color ?: nt.depth;
    nt.valid = ref != nil;
    if (ref) {
        nt.w = (int)ref.width;
        nt.h = (int)ref.height;
    }
    if (nt.color && nt.depth && (nt.depth.width != nt.color.width || nt.depth.height != nt.color.height)) nt.depth = nil;
    bool same = nt.color == x.cur.color && nt.depth == x.cur.depth;
    if (!same) {
        endPass(x);
        x.pendColor = x.pendDepth = x.pendStencil = false;
    }
    if (nt.flip != x.cur.flip) g.uniformsDirty = true;
    x.cur = nt;
}

static bool beginPass(Exec& x) {
    if (x.enc) return true;
    if (!x.cur.valid) return false;
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (x.cur.color) {
        rp.colorAttachments[0].texture = x.cur.color;
        rp.colorAttachments[0].loadAction = x.pendColor ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.colorAttachments[0].clearColor = x.pendColorValue;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    if (x.cur.depth) {
        rp.depthAttachment.texture = x.cur.depth;
        rp.depthAttachment.loadAction = x.pendDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.depthAttachment.clearDepth = x.pendDepthValue;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (x.cur.depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            rp.stencilAttachment.texture = x.cur.depth;
            rp.stencilAttachment.loadAction = x.pendStencil ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.stencilAttachment.clearStencil = x.pendStencilValue;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    x.pendColor = x.pendDepth = x.pendStencil = false;
    if (profEnabled()) {
        static const char* names[] = {"pass 0", "pass 1", "pass 2", "pass 3", "pass 4", "pass 5", "pass 6", "pass 7+"};
        profRender(rp, names[std::min<uint64_t>(g_stats.passes, 7)]);
    }
    x.enc = [x.cb renderCommandEncoderWithDescriptor:rp];
    g_stats.passes++;
    x.bPso = nil;
    x.bDss = nil;
    x.bCull = x.bWinding = -1;
    x.bLitBound = false;
    x.bStencilRef = -1;
    for (float& c : x.bBlendColor) c = NAN;
    x.bBiasUnits = x.bBiasFactor = NAN;
    x.bViewportValid = x.bScissorValid = false;
    for (int i = 0; i < 3; i++) x.bTex[i] = x.bSmp[i] = nil;
    x.bVb = nil;
    x.bVbOffset = SIZE_MAX;
    x.bFormat = -1;
    x.bUniOffset = SIZE_MAX;
    x.xfDirty = true;
    x.stateDirty = true;
    if (x.cur.fbo == 0) engine().screenDirty = true;
    return true;
}

static uint32_t depthFormat(const Target& t) { return t.depth ? (uint32_t)t.depth.pixelFormat : (uint32_t)MTLPixelFormatInvalid; }
static uint32_t stencilFormat(const Target& t) {
    return t.depth && t.depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? (uint32_t)MTLPixelFormatDepth32Float_Stencil8 : (uint32_t)MTLPixelFormatInvalid;
}

static MTLScissorRect glToMetalRect(const Target& t, int x, int y, int w, int h) {
    int x0 = std::clamp(x, 0, t.w), x1 = std::clamp(x + w, 0, t.w);
    int y0, y1;
    if (t.flip) { y0 = std::clamp(y, 0, t.h); y1 = std::clamp(y + h, 0, t.h); }
    else { y0 = std::clamp(t.h - (y + h), 0, t.h); y1 = std::clamp(t.h - y, 0, t.h); }
    return MTLScissorRect{(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)std::max(0, x1 - x0), (NSUInteger)std::max(0, y1 - y0)};
}

static void applyViewportScissor(Exec& x, bool& skip) {
    const ViewportState& v = g.vp;
    MTLViewport vp;
    vp.originX = v.vp[0];
    vp.originY = x.cur.flip ? v.vp[1] : x.cur.h - (v.vp[1] + v.vp[3]);
    vp.width = v.vp[2];
    vp.height = v.vp[3];
    vp.znear = 0;
    vp.zfar = 1;
    if (!x.bViewportValid || memcmp(&vp, &x.bViewport, sizeof vp) != 0) {
        [x.enc setViewport:vp];
        x.bViewport = vp;
        x.bViewportValid = true;
    }
    MTLScissorRect sc = v.scissor ? glToMetalRect(x.cur, v.sc[0], v.sc[1], v.sc[2], v.sc[3])
                                  : MTLScissorRect{0, 0, (NSUInteger)x.cur.w, (NSUInteger)x.cur.h};
    if (sc.width == 0 || sc.height == 0) { skip = true; return; }
    if (!x.bScissorValid || memcmp(&sc, &x.bScissor, sizeof sc) != 0) {
        [x.enc setScissorRect:sc];
        x.bScissor = sc;
        x.bScissorValid = true;
    }
}

static uint32_t mapTexEnvMode(uint32_t m) {
    switch (m) {
        case 0x2100: return 0; case 0x1E01: return 1; case 0x2101: return 2;
        case 0x0BE2: return 3; case 0x0104: return 4; case 0x8570: return 5;
        default: return 0;
    }
}

static uint32_t mapCombine(uint32_t f) {
    switch (f) {
        case 0x1E01: return 0; case 0x2100: return 1; case 0x0104: return 2; case 0x8574: return 3;
        case 0x8575: return 4; case 0x84E7: return 5; case 0x86AE: return 6; case 0x86AF: return 7;
        default: return 1;
    }
}

static uint32_t mapSource(uint32_t s) {
    switch (s) {
        case 0x1702: return 0; case 0x8576: return 1; case 0x8577: return 2; case 0x8578: return 3;
        default: return s >= 0x84C0 && s < 0x84C3 ? 4 + (s - 0x84C0) : 0;
    }
}

static uint32_t mapOperand(uint32_t o) { return o >= 0x300 && o <= 0x303 ? o - 0x300 : 0; }

static simd_float4 v4(const float* f) { return simd_make_float4(f[0], f[1], f[2], f[3]); }

// Builds the uniform block for the current state into the frame's uniform stream.
static size_t buildUniforms(Exec& x, uint32_t texMask) {
    FrameResources& f = *x.fr;
    size_t size = (sizeof(FFUniforms) + 255) & ~(size_t)255;
    if (f.uniformOffset + size > f.uniformCapacity) {
        flushBatch(x);
        f.retired.push_back(f.uniforms);
        f.uniformCapacity *= 2;
        f.uniforms = [device() newBufferWithLength:f.uniformCapacity options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        f.uniformOffset = 0;
        x.bUniOffset = SIZE_MAX;
    }
    size_t off = f.uniformOffset;
    f.uniformOffset += size;
    FFUniforms* u = (FFUniforms*)((uint8_t*)f.uniforms.contents + off);
    u->proj = g.proj;
    u->modelview = g.mv;
    u->normalMatrix = g.normal;
    u->texMatrix0 = g.tex[0];
    u->texMatrix1 = g.tex[1];
    u->color = v4(g.attrib.color);
    u->normal = simd_make_float4(g.attrib.normal[0], g.attrib.normal[1], g.attrib.normal[2], 0);
    u->texCoord0 = v4(g.attrib.tex0);
    u->texCoord1 = v4(g.attrib.tex1);
    for (int l = 0; l < 2; l++) {
        u->lightPos[l] = v4(g.light.pos[l]);
        u->lightDiffuse[l] = v4(g.light.diffuse[l]);
        u->lightAmbient[l] = v4(g.light.ambient[l]);
    }
    u->lightModelAmbient = v4(g.light.modelAmbient);
    u->fogColor = v4(g.frag.fogColor);
    float range = g.frag.fogEnd - g.frag.fogStart;
    u->fogParams = simd_make_float4(g.frag.fogStart, g.frag.fogEnd, g.frag.fogDensity, range != 0 ? 1.0f / range : 0.0f);
    uint32_t flags = texMask;
    if (g.light.lighting) {
        flags |= FF_LIGHTING;
        if (g.light.lightBits & 1) flags |= FF_LIGHT0;
        if (g.light.lightBits & 2) flags |= FF_LIGHT1;
        if (g.light.colorMaterial) flags |= FF_COLOR_MATERIAL;
        if (g.light.colorMaterialMode == 0x1200) flags |= FF_CM_AMBIENT_ONLY;
        if (g.light.normFlags) flags |= FF_NORMALIZE;
    }
    if (g.frag.fog) flags |= FF_FOG;
    if (g.frag.fogDistMode == 0x855B) flags |= FF_FOG_RADIAL;
    if (x.cur.flip) flags |= FF_FLIP_Y;
    uint32_t genModes = 0;
    if (texMask & FF_TEX0) {
        for (int c = 0; c < 4; c++) {
            if (!(g.texgen.bits & (1u << c))) continue;
            flags |= FF_TEXGEN_S << c;
            bool eye = g.texgen.mode[c] == 0x2400;
            genModes |= (eye ? 1u : 0u) << (c * 2);
            u->texGenPlane[c] = v4(eye ? &g.texgen.eyePlane[c * 4] : &g.texgen.objPlane[c * 4]);
        }
    }
    uint32_t fogMode = g.frag.fogMode == 0x2601 ? 0 : g.frag.fogMode == 0x0801 ? 2 : 1;
    u->flags = simd_make_uint4(flags, genModes, fogMode, g.frag.alphaFunc - 0x200);
    u->alpha = simd_make_float4(g.frag.alphaRef, (float)g.pipe.logicOp, 0, 0);
    u->raster = simd_make_float4(std::max(1.0f, g.raster.pointSize),
                                 g.raster.stipple ? (float)(g.raster.stipple >> 16) : 0.0f,
                                 (float)(g.raster.stipple & 0xFFFF), 0);
    for (int i = 0; i < 3; i++) {
        const UnitState& s = g.units[i];
        u->envColor[i] = v4(s.envColor);
        u->envScale[i] = simd_make_float4(s.rgbScale, s.alphaScale, 0, 0);
        uint32_t src = 0, ops = 0;
        for (int k = 0; k < 3; k++) {
            src |= mapSource(s.srcRGB[k]) << (k * 3);
            src |= mapSource(s.srcA[k]) << (9 + k * 3);
            ops |= mapOperand(s.opRGB[k]) << (k * 2);
            ops |= mapOperand(s.opA[k]) << (6 + k * 2);
        }
        u->env[i] = simd_make_uint4(mapTexEnvMode(s.mode), mapCombine(s.combineRGB) | mapCombine(s.combineA) << 8, src, ops);
    }
    return off;
}

// Applies every piece of encoder state a draw needs. Returns false to skip the draw.
static bool prepareDrawFull(Exec& x, uint32_t glPrim, int format, bool terrain);

// Fast path: when only the modelview changed since the previous prepared draw
// (typical for consecutive entity model parts), rebind just the transform.
static bool prepareDraw(Exec& x, uint32_t glPrim, int format, bool terrain = false) {
    uint32_t pc0 = (uint32_t)primClass(glPrim) | (x.wideLine ? 4u : 0u);
    if (!x.stateDirty && x.enc && x.lastOk && x.lastPrimClass == pc0 && x.lastFormat == format && x.lastTerrain == terrain) {
        if (!terrain && x.xfDirty) {
            DrawTransform xf;
            xf.modelview = g.mv;
            xf.normal0 = g.normal.columns[0];
            xf.normal1 = g.normal.columns[1];
            xf.normal2 = g.normal.columns[2];
            [x.enc setVertexBytes:&xf length:sizeof xf atIndex:3];
            x.xfDirty = false;
        }
        return true;
    }
    bool ok = prepareDrawFull(x, glPrim, format, terrain);
    x.stateDirty = false;
    x.lastOk = ok;
    x.lastPrimClass = pc0;
    x.lastFormat = format;
    x.lastTerrain = terrain;
    return ok;
}

static bool prepareDrawFull(Exec& x, uint32_t glPrim, int format, bool terrain) {
    if (!beginPass(x)) return false;
    if (!x.cur.color) return false;
    PrimClass pc = primClass(glPrim);
    // Culling (polygons only). GL_FRONT_AND_BACK culls every polygon.
    if (pc == PC_TRI && g.raster.cull && g.raster.cullFace == 0x408) return false;

    bool flat = g.raster.flat != 0;
    uint32_t texMask = 0;
    TexEntry* units[3] = {nullptr, nullptr, nullptr};
    for (int i = 0; i < 3; i++) {
        if (!g.units[i].enabled || !g.units[i].tex) continue;
        TexEntry* t = texture((int)g.units[i].tex);
        if (!t || !t->tex || t->isDepth) continue;
        units[i] = t;
        texMask |= FF_TEX0 << i;
    }

    PipeKey k{};
    k.color = (uint32_t)x.cur.color.pixelFormat;
    k.depth = depthFormat(x.cur);
    k.stencil = stencilFormat(x.cur);
    bool logic = g.pipe.logicOn && g.pipe.logicOp != 0x1503;
    if (g.pipe.blend && !logic) {
        k.blend = blendIndex(g.pipe.srcRGB) | blendIndex(g.pipe.dstRGB) << 4 | blendIndex(g.pipe.srcA) << 8 |
                  blendIndex(g.pipe.dstA) << 12 | 1u << 16;
        k.blendEq = g.pipe.eq;
    }
    k.writeMask = g.pipe.colorMask;
    bool modulate = true;
    for (int i = 0; i < 3; i++) if ((texMask & (FF_TEX0 << i)) && g.units[i].mode != 0x2100) modulate = false;
    // shaders mode: the hand, particles and weather are drawn with the advanced lighting
    const AdvLitContext& litc = advancedLitContext();
    bool advLit = x.advReplay && x.auxDepth == 0 && litc.valid && !terrain && !x.wideLine && !logic &&
                  (texMask & FF_TEX0) && g_litFfn[0] &&
                  (g_phase == PH_HAND || g_phase == PH_PARTICLES || g_phase == PH_LIT_PARTICLES || g_phase == PH_WEATHER);
    k.variant = (g.frag.alphaTest && g.frag.alphaFunc != 0x207 ? 1 : 0) | (logic ? 2 : 0) | (flat ? 4 : 0) |
                (terrain ? 8 : 0) | (modulate ? 16 : 0) | (x.wideLine ? 32 : 0) | (advLit ? 64 : 0);
    id<MTLRenderPipelineState> pso = pipeline(k);
    if (!pso) return false;
    if (pso != x.bPso) { [x.enc setRenderPipelineState:pso]; x.bPso = pso; }
    if (advLit && !x.bLitBound) {
        [x.enc setFragmentBytes:&litc.frame length:sizeof litc.frame atIndex:6];
        [x.enc setFragmentBuffer:litc.exposure offset:0 atIndex:7];
        [x.enc setFragmentTexture:litc.shadowMap atIndex:3];
        [x.enc setFragmentTexture:litc.skyLut atIndex:4];
        [x.enc setFragmentSamplerState:litc.shadowCmp atIndex:3];
        [x.enc setFragmentSamplerState:litc.linear atIndex:4];
        x.bLitBound = true;
    }

    bool stencilOn = g.depth.stencil && stencilFormat(x.cur) != (uint32_t)MTLPixelFormatInvalid;
    id<MTLDepthStencilState> dss = depthState(g.depth.test && x.cur.depth, g.depth.func, g.depth.mask, stencilOn ? &g.depth : nullptr);
    if (dss != x.bDss) { [x.enc setDepthStencilState:dss]; x.bDss = dss; }
    if (stencilOn && x.bStencilRef != (int)(g.depth.sRef & 0xFF)) {
        [x.enc setStencilReferenceValue:g.depth.sRef & 0xFF];
        x.bStencilRef = (int)(g.depth.sRef & 0xFF);
    }

    // lines are never culled, also when expanded into quads
    int cull = g.raster.cull && !x.wideLine ? (g.raster.cullFace == 0x404 ? (int)MTLCullModeFront : (int)MTLCullModeBack)
                                             : (int)MTLCullModeNone;
    if (cull != x.bCull) { [x.enc setCullMode:(MTLCullMode)cull]; x.bCull = cull; }
    bool ccw = g.raster.frontFace == 0x901;
    if (x.cur.flip) ccw = !ccw;
    int winding = ccw ? (int)MTLWindingCounterClockwise : (int)MTLWindingClockwise;
    if (winding != x.bWinding) { [x.enc setFrontFacingWinding:(MTLWinding)winding]; x.bWinding = winding; }
    float bu = g.raster.polyFill ? g.raster.units : 0.0f, bf = g.raster.polyFill ? g.raster.factor : 0.0f;
    if (bu != x.bBiasUnits || bf != x.bBiasFactor) {
        [x.enc setDepthBias:bu slopeScale:bf clamp:0];
        x.bBiasUnits = bu;
        x.bBiasFactor = bf;
    }
    if (k.blend && memcmp(x.bBlendColor, g.pipe.blendColor, sizeof x.bBlendColor) != 0) {
        [x.enc setBlendColorRed:g.pipe.blendColor[0] green:g.pipe.blendColor[1] blue:g.pipe.blendColor[2] alpha:g.pipe.blendColor[3]];
        memcpy(x.bBlendColor, g.pipe.blendColor, sizeof x.bBlendColor);
    }
    bool skip = false;
    applyViewportScissor(x, skip);
    if (skip) return false;

    if (g.uniformsDirty || x.uniOffset == SIZE_MAX || x.flipForUniforms != x.cur.flip || texMask != (x.uniMask)) {
        x.uniOffset = buildUniforms(x, texMask);
        x.flipForUniforms = x.cur.flip;
        x.uniMask = texMask;
        g.uniformsDirty = false;
    }
    if (x.uniOffset != x.bUniOffset) {
        [x.enc setVertexBuffer:x.fr->uniforms offset:x.uniOffset atIndex:2];
        [x.enc setFragmentBuffer:x.fr->uniforms offset:x.uniOffset atIndex:2];
        x.bUniOffset = x.uniOffset;
    }
    if (!terrain && x.xfDirty) {
        DrawTransform xf;
        xf.modelview = g.mv;
        xf.normal0 = g.normal.columns[0];
        xf.normal1 = g.normal.columns[1];
        xf.normal2 = g.normal.columns[2];
        [x.enc setVertexBytes:&xf length:sizeof xf atIndex:3];
        x.xfDirty = false;
    }
    if (format != x.bFormat) {
        const VertexLayout* L = layout(format);
        if (!L) return false;
        [x.enc setVertexBytes:L length:sizeof(VertexLayout) atIndex:1];
        x.bFormat = format;
    }
    for (int i = 0; i < 3; i++) {
        if (!units[i]) continue;
        id<MTLTexture> t = units[i]->tex;
        const UnitState& us = g.units[i];
        id<MTLSamplerState> s = samplerFor((int)us.minFilter, (int)us.magFilter, (int)us.wrapS, (int)us.wrapT,
                                           (int)us.maxLevel, us.minLod, us.maxLod, us.aniso);
        if (t != x.bTex[i]) { [x.enc setFragmentTexture:t atIndex:i]; x.bTex[i] = t; }
        if (s != x.bSmp[i]) { [x.enc setFragmentSamplerState:s atIndex:i]; x.bSmp[i] = s; }
    }
    return true;
}

static uint32_t* allocIndices(Exec& x, uint32_t count, id<MTLBuffer>* buf, size_t* start) {
    FrameResources& f = *x.fr;
    size_t bytes = (size_t)count * 4;
    if (f.indexOffset + bytes > f.indexCapacity) {
        flushBatch(x);
        f.retired.push_back(f.indices);
        f.indexCapacity = std::max(f.indexCapacity * 2, bytes * 2);
        f.indices = [device() newBufferWithLength:f.indexCapacity options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        f.indexOffset = 0;
    }
    *buf = f.indices;
    *start = f.indexOffset / 4;
    uint32_t* p = (uint32_t*)((uint8_t*)f.indices.contents + f.indexOffset);
    f.indexOffset += bytes;
    return p;
}

// GL's line width in pixels: rounded (at least 1) for aliased lines, exact for smooth ones.
static float lineWidthPx() {
    return g.raster.lineSmooth ? std::max(0.1f, g.raster.lineWidth) : std::max(1.0f, std::round(g.raster.lineWidth));
}

// Lines expanded into quads by ff_line_vertex: wider than 1 px, stippled or antialiased.
static bool expandLines() {
    return (lineWidthPx() > 1.0f || g.raster.stipple != 0 || g.raster.lineSmooth) && g_lineVfn[0];
}
static bool isWideLine(uint32_t prim) { return primClass(prim) == PC_LINE && expandLines(); }

// Draws n segment endpoint indices (written by `write`) as expanded lines: pairs go to
// buffer(4), six vertices per segment. `prim` only selects the GL state (a line type).
template <typename Write>
static void drawExpandedLines(Exec& x, id<MTLBuffer> vb, size_t vbOffset, uint32_t prim, uint32_t n, int format, Write write) {
    flushBatch(x);
    if (n < 2) return;
    x.wideLine = true;
    bool ok = prepareDraw(x, prim, format);
    x.wideLine = false;
    if (!ok) return;
    if (vb != x.bVb || x.bVbOffset != vbOffset) {
        [x.enc setVertexBuffer:vb offset:vbOffset atIndex:0];
        x.bVb = vb;
        x.bVbOffset = vbOffset;
    }
    id<MTLBuffer> ib;
    size_t start;
    uint32_t* idx = allocIndices(x, n, &ib, &start);
    write(idx);
    [x.enc setVertexBuffer:ib offset:start * 4 atIndex:4];
    float vw = (float)std::max(1, std::abs(g.vp.vp[2])), vh = (float)std::max(1, std::abs(g.vp.vp[3]));
    simd_float4 lp = simd_make_float4(vw, vh, lineWidthPx(), g.raster.lineSmooth ? 1.0f : 0.0f);
    [x.enc setVertexBytes:&lp length:sizeof lp atIndex:5];
    [x.enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(n / 2) * 6];
    g_stats.arenaDraws++;
    x.stateDirty = true;   // the next draw rebinds its own pipeline
}

static void drawWideLines(Exec& x, id<MTLBuffer> vb, size_t vbOffset, uint32_t prim, uint32_t count, uint32_t base, int format) {
    uint32_t n = indexCount(prim, count);
    drawExpandedLines(x, vb, vbOffset, prim, n, format, [&](uint32_t* idx) { writeIndices(idx, prim, count, base, false); });
}

// glPolygonMode(GL_FRONT_AND_BACK, GL_LINE): the edges GL draws for each polygon.
static uint32_t edgeIndexCount(uint32_t prim, uint32_t n) {
    switch (prim) {
        case 4: return (n / 3) * 6;                        // triangles
        case 5: case 6: return n >= 3 ? (n - 2) * 6 : 0;   // strip / fan: each triangle's edges
        case 7: return (n / 4) * 8;                        // quads: four edges, no diagonal
        case 8: return n >= 4 ? ((n - 2) / 2) * 8 : 0;     // quad strip
        case 9: return n >= 2 ? n * 2 : 0;                 // polygon: its outline
        default: return 0;
    }
}

static void writeEdgeIndices(uint32_t* o, uint32_t prim, uint32_t n, uint32_t b) {
    auto edge = [&](uint32_t p, uint32_t q) { *o++ = b + p; *o++ = b + q; };
    switch (prim) {
        case 4: for (uint32_t i = 0; i + 2 < n; i += 3) { edge(i, i + 1); edge(i + 1, i + 2); edge(i + 2, i); } break;
        case 5: for (uint32_t k = 0; k + 2 < n; k++) { edge(k, k + 1); edge(k + 1, k + 2); edge(k + 2, k); } break;
        case 6: for (uint32_t k = 1; k + 1 < n; k++) { edge(0, k); edge(k, k + 1); edge(k + 1, 0); } break;
        case 7: for (uint32_t q = 0; q + 3 < n; q += 4) { edge(q, q + 1); edge(q + 1, q + 2); edge(q + 2, q + 3); edge(q + 3, q); } break;
        case 8: for (uint32_t k = 0; k + 3 < n; k += 2) { edge(k, k + 1); edge(k + 1, k + 3); edge(k + 3, k + 2); edge(k + 2, k); } break;
        case 9: for (uint32_t i = 0; i < n; i++) edge(i, (i + 1) % n); break;
        default: break;
    }
}

// Polygons drawn in GL_LINE or GL_POINT polygon mode. Returns false for normal fill.
// (GL would still cull back-facing polygons first; edges are drawn for all of them.)
static bool drawPolygonMode(Exec& x, id<MTLBuffer> vb, size_t vbOffset, uint32_t prim, uint32_t count, uint32_t base, int format) {
    uint32_t mode = g.raster.polyMode;
    if (primClass(prim) != PC_TRI || (mode != 0x1B01 && mode != 0x1B00)) return false;
    flushBatch(x);
    if (mode == 0x1B01) {
        uint32_t n = edgeIndexCount(prim, count);
        if (n < 2) return true;
        if (expandLines()) {
            drawExpandedLines(x, vb, vbOffset, 1, n, format, [&](uint32_t* idx) { writeEdgeIndices(idx, prim, count, base); });
            return true;
        }
        if (!prepareDraw(x, 1, format)) return true;
        if (vb != x.bVb || x.bVbOffset != vbOffset) {
            [x.enc setVertexBuffer:vb offset:vbOffset atIndex:0];
            x.bVb = vb;
            x.bVbOffset = vbOffset;
        }
        id<MTLBuffer> ib;
        size_t start;
        uint32_t* idx = allocIndices(x, n, &ib, &start);
        writeEdgeIndices(idx, prim, count, base);
        [x.enc drawIndexedPrimitives:MTLPrimitiveTypeLine indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:start * 4];
    } else {
        if (!prepareDraw(x, 0, format)) return true;
        if (vb != x.bVb || x.bVbOffset != vbOffset) {
            [x.enc setVertexBuffer:vb offset:vbOffset atIndex:0];
            x.bVb = vb;
            x.bVbOffset = vbOffset;
        }
        [x.enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:base vertexCount:count];
    }
    g_stats.arenaDraws++;
    x.stateDirty = true;
    return true;
}

static void drawArena(Exec& x, const DrawCmd& d) {
    const VertexLayout* L = layout((int)d.format);
    if (!L || L->stride.x == 0 || d.chunk >= x.fr->arenas.size()) return;
    uint32_t n = indexCount(d.prim, d.count);
    if (n == 0) return;
    id<MTLBuffer> vb = x.fr->arenas[d.chunk];
    uint32_t base = d.offset / L->stride.x;
    if (isWideLine(d.prim)) { drawWideLines(x, vb, 0, d.prim, d.count, base, (int)d.format); return; }
    if (g.raster.polyMode != 0 && drawPolygonMode(x, vb, 0, d.prim, d.count, base, (int)d.format)) return;
    PrimClass pc = primClass(d.prim);
    bool flat = g.raster.flat != 0;
    bool canMerge = x.batchOpen && x.batchVb == vb && x.batchFormat == (int)d.format && x.batchClass == pc && x.batchFlat == flat;
    if (!canMerge) {
        flushBatch(x);
        if (!prepareDraw(x, d.prim, (int)d.format)) return;
        if (vb != x.bVb || x.bVbOffset != 0) {
            [x.enc setVertexBuffer:vb offset:0 atIndex:0];
            x.bVb = vb;
            x.bVbOffset = 0;
        }
    }
    id<MTLBuffer> ib;
    size_t start;
    uint32_t* idx = allocIndices(x, n, &ib, &start);
    if (canMerge && ib != x.batchIdx) {
        // the index stream was reallocated; the batch was flushed by allocIndices
        canMerge = false;
        if (!prepareDraw(x, d.prim, (int)d.format)) return;
        [x.enc setVertexBuffer:vb offset:0 atIndex:0];
        x.bVb = vb;
        x.bVbOffset = 0;
    }
    writeIndices(idx, d.prim, d.count, base, flat);
    if (canMerge && x.batchOpen) {
        x.batchIdxCount += n;
    } else {
        x.batchOpen = true;
        x.batchClass = pc;
        x.batchVb = vb;
        x.batchFormat = (int)d.format;
        x.batchIdx = ib;
        x.batchIdxStart = start;
        x.batchIdxCount = n;
        x.batchFlat = flat;
    }
}

static void drawMesh(Exec& x, const DrawMeshCmd& d) {
    flushBatch(x);
    g_stats.meshDraws++;
    id<MTLBuffer> vb = mesh((int)d.mesh);
    if (!vb) return;
    uint32_t n = indexCount(d.prim, d.count);
    if (n == 0) return;
    if (isWideLine(d.prim)) { drawWideLines(x, vb, d.offset, d.prim, d.count, 0, (int)d.format); return; }
    if (g.raster.polyMode != 0 && drawPolygonMode(x, vb, d.offset, d.prim, d.count, 0, (int)d.format)) return;
    if (!prepareDraw(x, d.prim, (int)d.format)) return;
    if (vb != x.bVb || x.bVbOffset != d.offset) {
        [x.enc setVertexBuffer:vb offset:d.offset atIndex:0];
        x.bVb = vb;
        x.bVbOffset = d.offset;
    }
    bool flat = g.raster.flat != 0;
    PrimClass pc = primClass(d.prim);
    if (d.prim == 7) {
        id<MTLBuffer> qi = flat ? flatQuadIndices(d.count / 4) : quadIndices(d.count / 4);
        [x.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:qi indexBufferOffset:0];
        return;
    }
    if (d.prim == 4 && !flat) {
        [x.enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:n];
        return;
    }
    id<MTLBuffer> ib;
    size_t start;
    uint32_t* idx = allocIndices(x, n, &ib, &start);
    writeIndices(idx, d.prim, d.count, 0, flat);
    [x.enc drawIndexedPrimitives:metalPrim(pc) indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:start * 4];
}

// Section transform, computed with the same float operations GL uses for
// glTranslatef(offset) followed by glMultMatrixf(chunk matrix).
static void sectionMatrix(const simd_float4x4& mv, float ox, float oy, float oz, float* out) {
    float m[16];
    memcpy(m, &mv, sizeof m);
    m[12] += m[0] * ox + m[4] * oy + m[8] * oz;
    m[13] += m[1] * ox + m[5] * oy + m[9] * oz;
    m[14] += m[2] * ox + m[6] * oy + m[10] * oz;
    m[15] += m[3] * ox + m[7] * oy + m[11] * oz;
    // chunk matrix from RenderChunk.initModelviewMatrix: T(-8) S(1.000001) T(8)
    static float chunk[16];
    static bool init = false;
    if (!init) {
        const float f = 1.000001f;
        float c[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -8, -8, -8, 1};
        for (int i = 0; i < 4; i++) { c[i] *= f; c[4 + i] *= f; c[8 + i] *= f; }
        c[12] += c[0] * 8 + c[4] * 8 + c[8] * 8;
        c[13] += c[1] * 8 + c[5] * 8 + c[9] * 8;
        c[14] += c[2] * 8 + c[6] * 8 + c[10] * 8;
        c[15] += c[3] * 8 + c[7] * 8 + c[11] * 8;
        memcpy(chunk, c, sizeof c);
        init = true;
    }
    for (int col = 0; col < 4; col++) {
        float b0 = chunk[col * 4], b1 = chunk[col * 4 + 1], b2 = chunk[col * 4 + 2], b3 = chunk[col * 4 + 3];
        for (int r = 0; r < 4; r++) out[col * 4 + r] = m[r] * b0 + m[4 + r] * b1 + m[8 + r] * b2 + m[12 + r] * b3;
    }
}

// One record per section draw, read by terrain_vertex at [[instance_id]] (ff.metal TerrainDraw).
struct TerrainDrawRecord {
    uint64_t vertices;   // GPU address of the section's layer buffer
    uint64_t pad;
    float mv[16];
};
static_assert(sizeof(TerrainDrawRecord) == 80, "matches TerrainDraw");

struct TerrainMeshlet { uint32_t record, first, count, pad; };   // ff.metal TerrainMeshlet
constexpr uint32_t kMeshletQuads = 64;

static void* allocTerrainBytes(Exec& x, size_t bytes, id<MTLBuffer>* buf, size_t* offset) {
    FrameResources& f = *x.fr;
    if (!f.terrainDraws || f.terrainOffset + bytes > f.terrainCapacity) {
        if (f.terrainDraws) f.retired.push_back(f.terrainDraws);
        f.terrainCapacity = std::max(f.terrainCapacity * 2, std::max<size_t>(bytes, 256u << 10));
        f.terrainDraws = [device() newBufferWithLength:f.terrainCapacity
                                               options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        f.terrainOffset = 0;
    }
    *buf = f.terrainDraws;
    *offset = f.terrainOffset;
    f.terrainOffset += (bytes + 255) & ~(size_t)255;
    return (uint8_t*)f.terrainDraws.contents + *offset;
}

static TerrainDrawRecord* allocTerrainDraws(Exec& x, uint32_t count, id<MTLBuffer>* buf, size_t* offset) {
    return (TerrainDrawRecord*)allocTerrainBytes(x, (size_t)count * sizeof(TerrainDrawRecord), buf, offset);
}

// A layer of the visible sections: the records go to one buffer bound once, and each
// section is one draw that changes no state (its record is its base instance).
static void drawTerrain(Exec& x, const CmdHeader* h) {
    flushBatch(x);
    const TerrainCmd& t = payload<TerrainCmd>(h);
    const TerrainEntry* e = (const TerrainEntry*)((const uint8_t*)(h + 1) + sizeof(TerrainCmd));
    if (t.layer > 3 || t.count == 0) return;
    if (!prepareDraw(x, 7, (int)t.format, true)) return;
    id<MTLBuffer> table;
    size_t tableOffset;
    TerrainDrawRecord* rec = allocTerrainDraws(x, t.count, &table, &tableOffset);
    // Every visible range of every section becomes 64-quad meshlets of one draw: a small draw
    // costs the GPU about as much as its vertices, so a layer is a single draw. terrain_vertex
    // finds a quad's meshlet (record + first quad) and drops the padding past its count.
    static std::vector<TerrainMeshlet> meshlets;
    static std::vector<uint32_t> sectionFirstMeshlet;   // per record, for one draw per section
    meshlets.clear();
    sectionFirstMeshlet.clear();
    uint32_t n = 0;
    auto addRun = [&](uint32_t record, uint32_t first, uint32_t quads) {
        g_stats.terrainDrawn += quads;
        for (uint32_t q = 0; q < quads; q += kMeshletQuads)
            meshlets.push_back({record, first + q, std::min<uint32_t>(kMeshletQuads, quads - q), 0});
    };
    // Back faces are culled (GL_BACK, counter-clockwise fronts): face groups whose every quad
    // faces away from the camera are left out.
    bool faceCull = g.raster.cull && g.raster.cullFace == 0x405 && g.raster.frontFace == 0x901 && g_optFaceCull;
    // the eye in the space the offsets are in (the modelview includes eye height, bobbing and
    // the third-person distance)
    simd_float4 ec = simd_mul(simd_inverse(g.mv), simd_make_float4(0, 0, 0, 1));
    float eyeX = ec.x / ec.w, eyeY = ec.y / ec.w, eyeZ = ec.z / ec.w;
    for (uint32_t i = 0; i < t.count; i++) {
        Section* s = section((int)e[i].section);
        if (!s || !s->layers[t.layer]) continue;
        uint32_t quads = s->vertices[t.layer] / 4;
        if (quads == 0) continue;
        const uint32_t* gs = s->groupStart[t.layer];
        const float* pl = s->plane[t.layer];
        // the chunk matrix scales about the section centre by 1.000001: a millimetre of slack
        const float eps = 1e-3f;
        float cx = eyeX - e[i].x, cy = eyeY - e[i].y, cz = eyeZ - e[i].z;
        bool vis[FG_COUNT] = {
            cy < pl[FG_NY] + eps, cx < pl[FG_NX] + eps, cz < pl[FG_NZ] + eps, cy > pl[FG_PY] - eps,
            true, cz > pl[FG_PZ] - eps, cx > pl[FG_PX] - eps,
        };
        uint32_t record = n++;
        sectionFirstMeshlet.push_back((uint32_t)meshlets.size());
        TerrainDrawRecord& r = rec[record];
        r.vertices = s->layers[t.layer].gpuAddress;
        sectionMatrix(g.mv, e[i].x, e[i].y, e[i].z, r.mv);
        uint32_t runStart = 0, runEnd = 0;   // the current run of visible groups (quads)
        bool open = false;
        for (int gi = 0; gi < FG_COUNT; gi++) {
            uint32_t a = gs[gi], b = gs[gi + 1];
            if (a == b) continue;   // empty groups never split a run
            if (!faceCull || vis[gi]) {
                if (!open) { runStart = a; open = true; }
                runEnd = b;
            } else if (open) {
                addRun(record, runStart, runEnd - runStart);
                open = false;
            }
        }
        if (open) addRun(record, runStart, runEnd - runStart);
        g_stats.terrainDraws++;
        g_stats.terrainQuads += quads;
    }
    if (meshlets.empty()) return;
    id<MTLBuffer> mbuf;
    size_t moff;
    void* mdst = allocTerrainBytes(x, meshlets.size() * sizeof(TerrainMeshlet), &mbuf, &moff);
    memcpy(mdst, meshlets.data(), meshlets.size() * sizeof(TerrainMeshlet));
    sectionHeapsUse(x.enc);
    [x.enc setVertexBuffer:table offset:tableOffset atIndex:3];
    [x.enc setVertexBuffer:mbuf offset:moff atIndex:4];
    uint32_t virtualQuads = (uint32_t)meshlets.size() * kMeshletQuads;
    id<MTLBuffer> qi = quadIndices(virtualQuads);
    if (g_optTerrainSplit) {
        // benchmarking: one draw per section
        sectionFirstMeshlet.push_back((uint32_t)meshlets.size());
        for (uint32_t r = 0; r + 1 < sectionFirstMeshlet.size(); r++) {
            uint32_t a = sectionFirstMeshlet[r], b = sectionFirstMeshlet[r + 1];
            if (a == b) continue;
            g_stats.drawCalls++;
            [x.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)(b - a) * kMeshletQuads * 6
                               indexType:MTLIndexTypeUInt32 indexBuffer:qi indexBufferOffset:(NSUInteger)a * kMeshletQuads * 24];
        }
    } else {
        g_stats.drawCalls++;
        [x.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)virtualQuads * 6 indexType:MTLIndexTypeUInt32
                         indexBuffer:qi indexBufferOffset:0];
    }
    x.xfDirty = true;
}

static void doClear(Exec& x, const ClearCmd& c) {
    flushBatch(x);
    if (!x.cur.valid) return;
    bool wantColor = (c.mask & 0x4000) && x.cur.color && g.pipe.colorMask != 0;
    bool wantDepth = (c.mask & 0x100) && x.cur.depth && g.depth.mask;
    bool wantStencil = (c.mask & 0x400) && x.cur.depth && x.cur.depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    if (!wantColor && !wantDepth && !wantStencil) return;
    bool fullMask = g.pipe.colorMask == 0xF;
    if (!x.enc && !g.vp.scissor && (!wantColor || fullMask)) {
        if (wantColor) { x.pendColor = true; x.pendColorValue = MTLClearColorMake(c.r, c.g, c.b, c.a); }
        if (wantDepth) { x.pendDepth = true; x.pendDepthValue = c.depth; }
        if (wantStencil) { x.pendStencil = true; x.pendStencilValue = c.stencil; }
        return;
    }
    if (!beginPass(x)) return;
    uint32_t mask = wantColor ? g.pipe.colorMask : 0;
    id<MTLRenderPipelineState> ps = clearPipeline((uint32_t)(x.cur.color ? x.cur.color.pixelFormat : MTLPixelFormatInvalid),
                                                  depthFormat(x.cur), stencilFormat(x.cur), mask);
    if (!ps) return;
    [x.enc setRenderPipelineState:ps];
    x.bPso = ps;
    x.stateDirty = true;
    DepthState clearStencil{};
    clearStencil.sFunc = 0x207;
    clearStencil.sFail = clearStencil.sZFail = clearStencil.sZPass = 0x1E01;   // replace with the clear value
    clearStencil.sValueMask = 0xFF;
    clearStencil.sWriteMask = g.depth.sWriteMask;   // glClear honours glStencilMask
    id<MTLDepthStencilState> dss = depthState(wantDepth, 0x207, wantDepth, wantStencil ? &clearStencil : nullptr);
    [x.enc setDepthStencilState:dss];
    x.bDss = dss;
    if (wantStencil) { [x.enc setStencilReferenceValue:c.stencil & 0xFF]; x.bStencilRef = (int)(c.stencil & 0xFF); }
    MTLViewport vp{0, 0, (double)x.cur.w, (double)x.cur.h, 0, 1};
    [x.enc setViewport:vp];
    x.bViewportValid = false;
    MTLScissorRect sc = g.vp.scissor ? glToMetalRect(x.cur, g.vp.sc[0], g.vp.sc[1], g.vp.sc[2], g.vp.sc[3])
                                     : MTLScissorRect{0, 0, (NSUInteger)x.cur.w, (NSUInteger)x.cur.h};
    if (sc.width == 0 || sc.height == 0) return;
    [x.enc setScissorRect:sc];
    x.bScissorValid = false;
    if (x.bCull != (int)MTLCullModeNone) { [x.enc setCullMode:MTLCullModeNone]; x.bCull = (int)MTLCullModeNone; }
    if (x.bBiasUnits != 0 || x.bBiasFactor != 0) { [x.enc setDepthBias:0 slopeScale:0 clamp:0]; x.bBiasUnits = x.bBiasFactor = 0; }
    ClearUniforms cu{simd_make_float4(c.r, c.g, c.b, c.a), simd_make_float4(c.depth, 0, 0, 0)};
    [x.enc setVertexBytes:&cu length:sizeof cu atIndex:0];
    [x.enc setFragmentBytes:&cu length:sizeof cu atIndex:0];
    x.bVb = nil;
    x.bVbOffset = SIZE_MAX;
    [x.enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

// Pipeline for copies out of top-down targets (the screen), per destination format.
static id<MTLRenderPipelineState> copyFlipPipeline(MTLPixelFormat fmt) {
    static std::unordered_map<uint32_t, id<MTLRenderPipelineState>> cache;
    auto it = cache.find((uint32_t)fmt);
    if (it != cache.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [engine().library newFunctionWithName:@"blit_vertex"];
    d.fragmentFunction = [engine().library newFunctionWithName:@"copy_flip_fragment"];
    d.colorAttachments[0].pixelFormat = fmt;
    NSError* err = nil;
    id<MTLRenderPipelineState> ps = [device() newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) log("copy pipeline: %s", err.localizedDescription.UTF8String);
    cache[(uint32_t)fmt] = ps;
    return ps;
}

static void copyTex(Exec& x, const CopyTexCmd& c) {
    endPass(x);
    TexEntry* dst = texture((int)c.tex);
    if (!dst || !dst->tex || !x.cur.color || c.w <= 0 || c.h <= 0) return;
    int sx = c.x, sy = x.cur.flip ? c.y : x.cur.h - (c.y + c.h);
    int w = std::min(c.w, std::min(x.cur.w - sx, (int)dst->tex.width - c.xoff));
    int h = std::min(c.h, std::min(x.cur.h - sy, (int)dst->tex.height - c.yoff));
    if (w <= 0 || h <= 0 || sx < 0 || sy < 0) return;
    if (!x.cur.flip) {
        // The screen is stored top-down but textures bottom-up (GL row order): GL's copy
        // takes the region's bottom row first, so the rows are reversed with a draw.
        id<MTLRenderPipelineState> ps = copyFlipPipeline(dst->tex.pixelFormat);
        if (!ps) return;
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dst->tex;
        rp.colorAttachments[0].level = (NSUInteger)c.level;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [x.cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"copyTexSubImage (screen)";
        [e setRenderPipelineState:ps];
        [e setViewport:(MTLViewport){(double)c.xoff, (double)c.yoff, (double)w, (double)h, 0, 1}];
        [e setScissorRect:(MTLScissorRect){(NSUInteger)c.xoff, (NSUInteger)c.yoff, (NSUInteger)w, (NSUInteger)h}];
        simd_float4 noFlip = simd_make_float4(0, 0, 0, 0);
        [e setVertexBytes:&noFlip length:sizeof noFlip atIndex:0];
        simd_int4 p = simd_make_int4(sx, sy + h - 1, c.xoff, c.yoff);
        [e setFragmentBytes:&p length:sizeof p atIndex:0];
        [e setFragmentTexture:x.cur.color atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        return;
    }
    id<MTLBlitCommandEncoder> b = [x.cb blitCommandEncoder];
    [b copyFromTexture:x.cur.color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx, sy, 0)
            sourceSize:MTLSizeMake(w, h, 1) toTexture:dst->tex destinationSlice:0 destinationLevel:c.level
     destinationOrigin:MTLOriginMake(c.xoff, c.yoff, 0)];
    [b endEncoding];
}

static simd_float4x4 loadMatrix(const float* f) {
    simd_float4x4 m;
    memcpy(&m, f, sizeof m);
    return m;
}

static simd_float4x4 normalMatrix(const simd_float4x4& mv) {
    simd_float3x3 u = simd_matrix(simd_make_float3(mv.columns[0]), simd_make_float3(mv.columns[1]), simd_make_float3(mv.columns[2]));
    float det = simd_determinant(u);
    simd_float3x3 n = det != 0 ? simd_transpose(simd_inverse(u)) : u;
    simd_float4x4 r = matrix_identity_float4x4;
    r.columns[0] = simd_make_float4(n.columns[0], 0);
    r.columns[1] = simd_make_float4(n.columns[1], 0);
    r.columns[2] = simd_make_float4(n.columns[2], 0);
    return r;
}

} // namespace

// Opaque captured geometry the advanced pipeline renders itself (G-buffer + shadows).
static bool advConsumes(const GLMirror& m, uint32_t phase, uint32_t prim) {
    return phase == PH_ENTITIES && prim == 7 && !m.pipe.blend && m.depth.test && m.depth.mask && !m.pipe.logicOn &&
           m.units[0].enabled && m.units[0].tex;
}

static void applyState(GLMirror& m, const CmdHeader* h) {
    switch (h->op) {
        case OP_STATE_PIPE: m.pipe = payload<PipeState>(h); break;
        case OP_STATE_DEPTH: m.depth = payload<DepthState>(h); break;
        case OP_STATE_RASTER: m.raster = payload<RasterState>(h); break;
        case OP_STATE_FRAG: m.frag = payload<FragState>(h); break;
        case OP_STATE_UNITS: memcpy(m.units, h + 1, sizeof m.units); break;
        case OP_STATE_TEXGEN: m.texgen = payload<TexGenState>(h); break;
        case OP_STATE_LIGHT: m.light = payload<LightState>(h); break;
        case OP_STATE_ATTRIB: m.attrib = payload<AttribState>(h); break;
        case OP_STATE_VIEWPORT: m.vp = payload<ViewportState>(h); break;
        case OP_MATRIX: {
            const uint32_t which = *(const uint32_t*)(h + 1);
            simd_float4x4 mm = loadMatrix((const float*)(h + 1) + 1);
            if (which == 0) { m.mv = mm; m.normal = normalMatrix(mm); }
            else if (which == 1) m.proj = mm;
            else if (which - 2 < 3) m.tex[which - 2] = mm;
            break;
        }
        default: break;
    }
}

// Scans the world segment (up to WORLD_END) and collects what the advanced
// pipeline renders: terrain lists, opaque captured geometry, environment and
// the world's render target.
static void advCollect(Exec& x, CmdReader rd, AdvWorld& w, TargetCmd& target, bool& haveTarget) {
    GLMirror m = g;
    uint32_t phase = PH_WORLD_BEGIN;
    bool sampledLayer[4] = {false, false, false, false};
    int auxDepth = 0;   // auxiliary world segments nested in this one are not collected
    while (const CmdHeader* h = rd.next()) {
        if (auxDepth > 0) {
            if (h->op == OP_PHASE) {
                uint32_t ph = payload<uint32_t>(h);
                if (ph == PH_WORLD_BEGIN_AUX) auxDepth++;
                else if (ph == PH_WORLD_END) auxDepth--;
            }
            if (h->op != OP_TERRAIN && h->op != OP_ENV && h->op != OP_DRAW && h->op != OP_DRAW_MESH && h->op != OP_PHASE &&
                h->op != OP_TARGET)
                applyState(m, h);   // keep the GL mirror in sync with what the replay will see
            continue;
        }
        switch (h->op) {
            case OP_PHASE:
                phase = payload<uint32_t>(h);
                if (phase == PH_WORLD_BEGIN_AUX) { auxDepth = 1; break; }
                if (phase == PH_WORLD_END) return;
                break;
            case OP_ENV: w.env = payload<EnvCmd>(h); w.hasEnv = true; w.view = loadMatrix(w.env.view); w.proj = loadMatrix(w.env.proj); break;
            case OP_TARGET:
                if (w.terrain[0].empty()) { target = payload<TargetCmd>(h); haveTarget = true; }
                break;
            case OP_TERRAIN: {
                const TerrainCmd& t = payload<TerrainCmd>(h);
                if (t.layer > 3) break;
                const TerrainEntry* e = (const TerrainEntry*)((const uint8_t*)(h + 1) + sizeof(TerrainCmd));
                for (uint32_t i = 0; i < t.count; i++) w.terrain[t.layer].push_back({e[i].section, e[i].x, e[i].y, e[i].z});
                if (!sampledLayer[t.layer]) {
                    sampledLayer[t.layer] = true;
                    w.atlasTex = (int)m.units[0].tex;
                    const UnitState& u = m.units[0];
                    uint32_t* sp = w.layerSampler[t.layer];
                    sp[0] = u.minFilter; sp[1] = u.magFilter; sp[2] = u.wrapS; sp[3] = u.wrapT; sp[4] = u.maxLevel;
                    memcpy(&sp[5], &u.minLod, 4); memcpy(&sp[6], &u.maxLod, 4); memcpy(&sp[7], &u.aniso, 4);
                    if (t.layer == 0) {
                        w.fogStart = m.frag.fogStart;
                        w.fogEnd = m.frag.fogEnd;
                        memcpy(w.fogColor, m.frag.fogColor, sizeof w.fogColor);
                    }
                }
                break;
            }
            case OP_DRAW: case OP_DRAW_MESH: {
                uint32_t prim = h->op == OP_DRAW ? payload<DrawCmd>(h).prim : payload<DrawMeshCmd>(h).prim;
                bool shadowOnly = phase == PH_ENTITIES_SHADOW;
                if (!advConsumes(m, shadowOnly ? PH_ENTITIES : phase, prim)) break;
                AdvGeometry gm{};
                gm.shadowOnly = shadowOnly;
                if (h->op == OP_DRAW) {
                    const DrawCmd& d = payload<DrawCmd>(h);
                    const VertexLayout* L = layout((int)d.format);
                    if (!L || L->stride.x == 0 || d.chunk >= x.fr->arenas.size()) break;
                    gm.vb = x.fr->arenas[d.chunk];
                    gm.vbOffset = 0;
                    gm.firstVertex = d.offset / L->stride.x;
                    gm.format = (int)d.format;
                    gm.count = d.count;
                } else {
                    const DrawMeshCmd& d = payload<DrawMeshCmd>(h);
                    gm.vb = mesh((int)d.mesh);
                    if (!gm.vb) break;
                    gm.vbOffset = d.offset;
                    gm.format = (int)d.format;
                    gm.count = d.count;
                }
                gm.prim = prim;
                gm.mv = m.mv;
                gm.normal = m.normal;
                gm.texMat = m.tex[0];
                gm.tex = (int)m.units[0].tex;
                const UnitState& u = m.units[0];
                gm.sampler[0] = u.minFilter; gm.sampler[1] = u.magFilter; gm.sampler[2] = u.wrapS; gm.sampler[3] = u.wrapT;
                gm.sampler[4] = u.maxLevel;
                memcpy(&gm.sampler[5], &u.minLod, 4); memcpy(&gm.sampler[6], &u.maxLod, 4); memcpy(&gm.sampler[7], &u.aniso, 4);
                gm.alphaTest = m.frag.alphaTest && m.frag.alphaFunc != 0x207;
                gm.alphaRef = m.frag.alphaRef;
                gm.cull = m.raster.cull;
                gm.cullFace = m.raster.cullFace;
                gm.frontFace = m.raster.frontFace;
                gm.item.color = v4(m.attrib.color);
                gm.item.normal = simd_make_float4(m.attrib.normal[0], m.attrib.normal[1], m.attrib.normal[2], 0);
                gm.item.lightmap = simd_make_float4(m.attrib.tex1[0], m.attrib.tex1[1], 0, 0);
                gm.item.alpha = simd_make_float4(m.frag.alphaRef, (float)(m.frag.alphaFunc - 0x200), 0, 7);
                // vanilla's hurt flash and creeper flash: unit 1 set to GL_COMBINE / GL_INTERPOLATE
                // between its constant colour and the textured colour, weighted by the constant's alpha
                const UnitState& u1 = m.units[1];
                if (u1.enabled && u1.mode == 0x8570 && u1.combineRGB == 0x8575 && u1.srcRGB[0] == 0x8576 && u1.srcRGB[2] == 0x8576)
                    gm.item.overlay = simd_make_float4(u1.envColor[0], u1.envColor[1], u1.envColor[2], u1.envColor[3]);
                w.geometry.push_back(gm);
                break;
            }
            default:
                applyState(m, h);
                break;
        }
    }
}

static void advRenderWorld(Exec& x, CmdReader rd) {
    AdvWorld w;
    // The world normally renders into whatever is bound at WORLD_BEGIN (Minecraft's framebuffer).
    TargetCmd target{x.cur.fbo, x.cur.colorId, x.cur.depthId};
    bool haveTarget = x.cur.valid;
    advCollect(x, rd, w, target, haveTarget);
    if (!w.hasEnv || !haveTarget || w.terrain[0].empty()) return;
    id<MTLTexture> color = nil, depth = nil;
    if (target.fbo == 0) {
        ensureScreenTargets();
        color = engine().screenColor;
        depth = engine().screenDepth;
    } else {
        TexEntry* c = texture((int)target.colorTex);
        color = c ? c->tex : nil;
        if (target.depth & 0x40000000) { TexEntry* r = renderbuffer(target.depth & 0x3FFFFFFF); depth = r ? r->tex : nil; }
        else if (target.depth) { TexEntry* d = texture((int)target.depth); depth = d ? d->tex : nil; }
    }
    if (!color || !depth) return;
    endPass(x);
    advancedRender(x.cb, w, color, depth);
    x.advReplay = true;
    if (target.fbo == 0) engine().screenDirty = true;
}

void executeFrame(id<MTLCommandBuffer> cb, const uint8_t* cmds, size_t len) {
    Exec x;
    x.cb = cb;
    x.fr = engine().cur;
    CmdReader rd(cmds, len);
    while (const CmdHeader* h = rd.next()) {
        switch (h->op) {
            case OP_STATE_PIPE: flushBatch(x); x.stateDirty = true; g.pipe = payload<PipeState>(h); g.uniformsDirty = true; break;
            case OP_STATE_DEPTH: flushBatch(x); x.stateDirty = true; g.depth = payload<DepthState>(h); break;
            case OP_STATE_RASTER: flushBatch(x); x.stateDirty = true; g.raster = payload<RasterState>(h); g.uniformsDirty = true; break;
            case OP_STATE_FRAG: flushBatch(x); x.stateDirty = true; g.frag = payload<FragState>(h); g.uniformsDirty = true; break;
            case OP_STATE_UNITS: flushBatch(x); x.stateDirty = true; memcpy(g.units, h + 1, sizeof g.units); g.uniformsDirty = true; break;
            case OP_STATE_TEXGEN: flushBatch(x); x.stateDirty = true; g.texgen = payload<TexGenState>(h); g.uniformsDirty = true; break;
            case OP_STATE_LIGHT: flushBatch(x); x.stateDirty = true; g.light = payload<LightState>(h); g.uniformsDirty = true; break;
            case OP_STATE_ATTRIB: flushBatch(x); x.stateDirty = true; g.attrib = payload<AttribState>(h); g.uniformsDirty = true; break;
            case OP_STATE_VIEWPORT: flushBatch(x); x.stateDirty = true; g.vp = payload<ViewportState>(h); break;
            case OP_MATRIX: {
                flushBatch(x);
                const uint32_t which = *(const uint32_t*)(h + 1);
                simd_float4x4 m = loadMatrix((const float*)(h + 1) + 1);
                if (which == 0) { g.mv = m; g.normal = normalMatrix(m); x.xfDirty = true; }
                else if (which == 1) { g.proj = m; g.uniformsDirty = true; x.stateDirty = true; }
                else if (which - 2 < 3) { g.tex[which - 2] = m; g.uniformsDirty = true; x.stateDirty = true; }
                break;
            }
            case OP_TARGET: flushBatch(x); resolveTarget(x, payload<TargetCmd>(h)); x.stateDirty = true; break;
            case OP_CLEAR:
                if (x.advReplay && (g_phase == PH_WORLD_BEGIN || g_phase == PH_SKY)) break;
                doClear(x, payload<ClearCmd>(h));
                break;
            case OP_DRAW:
                if (g_phase == PH_ENTITIES_SHADOW) break;   // never on screen
                if (x.advReplay && (g_phase == PH_SKY || (g_phase == PH_CLOUDS && advancedCloudsActive()) ||
                                    advConsumes(g, g_phase, payload<DrawCmd>(h).prim))) break;
                drawArena(x, payload<DrawCmd>(h));
                break;
            case OP_DRAW_MESH:
                if (g_phase == PH_ENTITIES_SHADOW) break;
                if (x.advReplay && (g_phase == PH_SKY || (g_phase == PH_CLOUDS && advancedCloudsActive()) ||
                                    advConsumes(g, g_phase, payload<DrawMeshCmd>(h).prim))) break;
                drawMesh(x, payload<DrawMeshCmd>(h));
                break;
            case OP_COPY_TEX: copyTex(x, payload<CopyTexCmd>(h)); break;
            case OP_PHASE:
                flushBatch(x);
                g_phase = payload<uint32_t>(h);
                x.stateDirty = true;   // some draws pick their pipeline by phase
                if (g_phase == PH_WORLD_BEGIN_AUX) {
                    if (x.auxDepth++ == 0) { x.advReplaySaved = x.advReplay; x.advReplay = false; }
                    break;
                }
                if (g_phase == PH_WORLD_BEGIN && advancedEnabled() && x.auxDepth == 0) advRenderWorld(x, rd);
                if (g_phase == PH_WORLD_END) {
                    if (x.auxDepth > 0) { if (--x.auxDepth == 0) x.advReplay = x.advReplaySaved; }
                    else x.advReplay = false;
                }
                break;
            case OP_ENV: g_env = payload<EnvCmd>(h); g_envValid = true; break;
            case OP_TERRAIN: if (!x.advReplay) drawTerrain(x, h); break;
            default: break;
        }
    }
    endPass(x);
    if (g_optGpuStats) {
        g_statsAcc.terrainDraws += g_stats.terrainDraws; g_statsAcc.terrainQuads += g_stats.terrainQuads;
        g_statsAcc.arenaDraws += g_stats.arenaDraws; g_statsAcc.meshDraws += g_stats.meshDraws; g_statsAcc.passes += g_stats.passes;
        g_statsAcc.terrainDrawn += g_stats.terrainDrawn; g_statsAcc.drawCalls += g_stats.drawCalls;
        if (++g_statsFrames == 600) {
            double n = g_statsFrames;
            log("per frame: terrain sections %.0f (%.0fk quads, %.0fk drawn in %.0f draws), arena draws %.0f, mesh draws %.0f, passes %.1f",
                g_statsAcc.terrainDraws / n, g_statsAcc.terrainQuads / n / 1000.0, g_statsAcc.terrainDrawn / n / 1000.0,
                g_statsAcc.drawCalls / n, g_statsAcc.arenaDraws / n,
                g_statsAcc.meshDraws / n, g_statsAcc.passes / n);
            g_statsAcc = {};
            g_statsFrames = 0;
        }
    }
    g_stats = {};
}

} // namespace m189
