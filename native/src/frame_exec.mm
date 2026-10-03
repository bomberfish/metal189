// metal189: per-frame command-stream executor.
//
// Replays the GL-semantics state and draws captured on the Java side into
// Metal render passes. Offscreen targets keep GL row order (row 0 = bottom), so
// draws into them flip clip-space Y; the screen target is Metal-oriented.

#import "engine.h"
#import "commands.h"
#import "resources.h"
#include <unordered_map>
#include <cstring>

namespace m189 {

// Runtime options (set from Java, see metal189.engine.Native.setOption).
int g_optQuadDiagonal = 1; // 1: split quads along v1-v3 like Apple's GL, 0: along v0-v2

void setOption(int key, int value) {
    switch (key) {
        case 1: g_optQuadDiagonal = value; break;
        default: break;
    }
}

// ---------------------------------------------------------------------------
// persistent GL state mirror

struct GLMirror {
    PipeState pipe{0, 1, 0, 1, 0, 0x8006, 0xF, 0, 0x1503};
    DepthState depth{0, 0x201, 1, 0};
    RasterState raster{0, 0x405, 0x901, 0, 0, 0, 1, 0};
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

// ---------------------------------------------------------------------------
// pipeline / depth-state caches

struct PipeKey {
    uint32_t color, depth, stencil;
    uint32_t blend;      // packed blend state, 0 = disabled
    uint32_t blendEq;
    uint32_t writeMask;
    uint32_t variant;    // bit0 alphaTest, bit1 logicOp, bit2 flat
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
static std::unordered_map<uint32_t, id<MTLDepthStencilState>> g_dss;
static id<MTLFunction> g_vfn[8], g_ffn[8];
static id<MTLFunction> g_clearV, g_clearF;
static id<MTLBuffer> g_quadIndices;
static uint32_t g_quadIndexQuads = 0;

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
    for (int v = 0; v < 8; v++) {
        MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
        bool alpha = v & 1, logic = (v >> 1) & 1, flat = (v >> 2) & 1;
        [cv setConstantValue:&alpha type:MTLDataTypeBool atIndex:0];
        [cv setConstantValue:&logic type:MTLDataTypeBool atIndex:1];
        [cv setConstantValue:&flat type:MTLDataTypeBool atIndex:2];
        NSError* err = nil;
        g_vfn[v] = [e.library newFunctionWithName:@"ff_vertex" constantValues:cv error:&err];
        if (!g_vfn[v]) { log("ff_vertex: %s", err.localizedDescription.UTF8String); return false; }
        g_ffn[v] = [e.library newFunctionWithName:@"ff_fragment" constantValues:cv error:&err];
        if (!g_ffn[v]) { log("ff_fragment: %s", err.localizedDescription.UTF8String); return false; }
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
    d.vertexFunction = g_vfn[k.variant & 7];
    d.fragmentFunction = g_ffn[k.variant & 7];
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

static id<MTLDepthStencilState> depthState(bool test, uint32_t func, bool write) {
    uint32_t key = (test ? 1 : 0) | (write ? 2 : 0) | (func & 0xF) << 4;
    auto it = g_dss.find(key);
    if (it != g_dss.end()) return it->second;
    MTLDepthStencilDescriptor* d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = test ? compareFn(func) : MTLCompareFunctionAlways;
    d.depthWriteEnabled = test && write; // GL never writes depth with the test disabled
    id<MTLDepthStencilState> s = [device() newDepthStencilStateWithDescriptor:d];
    g_dss[key] = s;
    return s;
}

static id<MTLBuffer> quadIndices(uint32_t quads) {
    if (quads <= g_quadIndexQuads && g_quadIndices) return g_quadIndices;
    uint32_t n = std::max<uint32_t>(quads, 65536);
    n = (n + 65535) & ~65535u;
    id<MTLBuffer> b = [device() newBufferWithLength:(size_t)n * 6 * 4 options:MTLResourceStorageModeShared];
    uint32_t* p = (uint32_t*)b.contents;
    for (uint32_t q = 0; q < n; q++) {
        uint32_t v = q * 4;
        p[q * 6 + 0] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 2;
        p[q * 6 + 3] = v; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
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
    x.enc = [x.cb renderCommandEncoderWithDescriptor:rp];
    x.bPso = nil;
    x.bDss = nil;
    x.bCull = x.bWinding = -1;
    x.bBiasUnits = x.bBiasFactor = NAN;
    x.bViewportValid = x.bScissorValid = false;
    for (int i = 0; i < 3; i++) x.bTex[i] = x.bSmp[i] = nil;
    x.bVb = nil;
    x.bVbOffset = SIZE_MAX;
    x.bFormat = -1;
    x.bUniOffset = SIZE_MAX;
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
static bool prepareDraw(Exec& x, uint32_t glPrim, int format) {
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
    k.variant = (g.frag.alphaTest && g.frag.alphaFunc != 0x207 ? 1 : 0) | (logic ? 2 : 0) | (flat ? 4 : 0);
    id<MTLRenderPipelineState> pso = pipeline(k);
    if (!pso) return false;
    if (pso != x.bPso) { [x.enc setRenderPipelineState:pso]; x.bPso = pso; }

    id<MTLDepthStencilState> dss = depthState(g.depth.test && x.cur.depth, g.depth.func, g.depth.mask);
    if (dss != x.bDss) { [x.enc setDepthStencilState:dss]; x.bDss = dss; }

    int cull = g.raster.cull ? (g.raster.cullFace == 0x404 ? (int)MTLCullModeFront : (int)MTLCullModeBack) : (int)MTLCullModeNone;
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
    if (format != x.bFormat) {
        const VertexLayout* L = layout(format);
        if (!L) return false;
        [x.enc setVertexBytes:L length:sizeof(VertexLayout) atIndex:1];
        x.bFormat = format;
    }
    for (int i = 0; i < 3; i++) {
        if (!units[i]) continue;
        id<MTLTexture> t = units[i]->tex;
        id<MTLSamplerState> s = textureSampler(*units[i]);
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

static void drawArena(Exec& x, const DrawCmd& d) {
    const VertexLayout* L = layout((int)d.format);
    if (!L || L->stride.x == 0 || d.chunk >= x.fr->arenas.size()) return;
    uint32_t n = indexCount(d.prim, d.count);
    if (n == 0) return;
    id<MTLBuffer> vb = x.fr->arenas[d.chunk];
    uint32_t base = d.offset / L->stride.x;
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
    id<MTLBuffer> vb = mesh((int)d.mesh);
    if (!vb) return;
    uint32_t n = indexCount(d.prim, d.count);
    if (n == 0) return;
    if (!prepareDraw(x, d.prim, (int)d.format)) return;
    if (vb != x.bVb || x.bVbOffset != d.offset) {
        [x.enc setVertexBuffer:vb offset:d.offset atIndex:0];
        x.bVb = vb;
        x.bVbOffset = d.offset;
    }
    bool flat = g.raster.flat != 0;
    PrimClass pc = primClass(d.prim);
    if (d.prim == 7 && !flat && !g_optQuadDiagonal) {
        id<MTLBuffer> qi = quadIndices(d.count / 4);
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
    id<MTLDepthStencilState> dss = depthState(wantDepth, 0x207, wantDepth);
    [x.enc setDepthStencilState:dss];
    x.bDss = dss;
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

static void copyTex(Exec& x, const CopyTexCmd& c) {
    endPass(x);
    TexEntry* dst = texture((int)c.tex);
    if (!dst || !dst->tex || !x.cur.color || c.w <= 0 || c.h <= 0) return;
    int sx = c.x, sy = x.cur.flip ? c.y : x.cur.h - (c.y + c.h);
    int w = std::min(c.w, std::min(x.cur.w - sx, (int)dst->tex.width - c.xoff));
    int h = std::min(c.h, std::min(x.cur.h - sy, (int)dst->tex.height - c.yoff));
    if (w <= 0 || h <= 0 || sx < 0 || sy < 0) return;
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

void executeFrame(id<MTLCommandBuffer> cb, const uint8_t* cmds, size_t len) {
    Exec x;
    x.cb = cb;
    x.fr = engine().cur;
    CmdReader rd(cmds, len);
    while (const CmdHeader* h = rd.next()) {
        switch (h->op) {
            case OP_STATE_PIPE: flushBatch(x); g.pipe = payload<PipeState>(h); g.uniformsDirty = true; break;
            case OP_STATE_DEPTH: flushBatch(x); g.depth = payload<DepthState>(h); break;
            case OP_STATE_RASTER: flushBatch(x); g.raster = payload<RasterState>(h); break;
            case OP_STATE_FRAG: flushBatch(x); g.frag = payload<FragState>(h); g.uniformsDirty = true; break;
            case OP_STATE_UNITS: flushBatch(x); memcpy(g.units, h + 1, sizeof g.units); g.uniformsDirty = true; break;
            case OP_STATE_TEXGEN: flushBatch(x); g.texgen = payload<TexGenState>(h); g.uniformsDirty = true; break;
            case OP_STATE_LIGHT: flushBatch(x); g.light = payload<LightState>(h); g.uniformsDirty = true; break;
            case OP_STATE_ATTRIB: flushBatch(x); g.attrib = payload<AttribState>(h); g.uniformsDirty = true; break;
            case OP_STATE_VIEWPORT: flushBatch(x); g.vp = payload<ViewportState>(h); break;
            case OP_MATRIX: {
                flushBatch(x);
                const uint32_t which = *(const uint32_t*)(h + 1);
                simd_float4x4 m = loadMatrix((const float*)(h + 1) + 1);
                if (which == 0) { g.mv = m; g.normal = normalMatrix(m); }
                else if (which == 1) g.proj = m;
                else if (which - 2 < 3) g.tex[which - 2] = m;
                g.uniformsDirty = true;
                break;
            }
            case OP_TARGET: flushBatch(x); resolveTarget(x, payload<TargetCmd>(h)); break;
            case OP_CLEAR: doClear(x, payload<ClearCmd>(h)); break;
            case OP_DRAW: drawArena(x, payload<DrawCmd>(h)); break;
            case OP_DRAW_MESH: drawMesh(x, payload<DrawMeshCmd>(h)); break;
            case OP_COPY_TEX: copyTex(x, payload<CopyTexCmd>(h)); break;
            case OP_PHASE: break;
            default: break;
        }
    }
    endPass(x);
}

} // namespace m189
