// metal189: advanced (deferred PBR) world renderer.
//
// Pass order: shadow map -> G-buffer (terrain + captured opaque geometry, into
// Minecraft's own depth buffer) -> deferred lighting + sky (HDR) -> forward
// water/translucent terrain -> bloom -> tonemap into Minecraft's framebuffer.
// Everything not consumed here (particles, weather, hand, outlines...) is then
// replayed by the baseline executor on top.

#import "advanced.h"
#import "raytrace.h"
#import "gpu_profiler.h"
#import "resources.h"
#include <cmath>

namespace m189 {
extern int g_optAdvDebug;
extern bool g_optGpuStats;

extern int g_optQuadDiagonal;

static bool g_enabled = false;
static uint32_t g_features = ADV_SHADOWS | ADV_BLOOM | ADV_SKY | ADV_WATER;
static id<MTLBuffer> g_materials, g_emissions;

bool advancedEnabled() { return g_enabled; }
static int g_shadowRes = 4096;
static float g_shadowDistance = 112.0f;
static float g_exposure = 1.0f;
static float g_bloomStrength = 1.0f;
static bool g_waving = true;
static int g_pbrNormal = 0, g_pbrSpecular = 0;

void advancedSetPbr(int normalTex, int specularTex) {
    g_pbrNormal = normalTex;
    g_pbrSpecular = specularTex;
}

void advancedSetParam(int key, int value) {
    switch (key) {
        case 10: g_shadowRes = std::clamp(value, 1024, 8192); break;
        case 11: g_shadowDistance = (float)std::clamp(value, 32, 256); break;
        case 12: g_exposure = std::clamp(value, 10, 1000) / 100.0f; break;
        case 13: g_bloomStrength = std::clamp(value, 0, 1000) / 100.0f; break;
        case 14: rtRelease(); break;
        case 15: g_waving = value != 0; break;
        default: break;
    }
}

void advancedSetEnabled(bool on) { g_enabled = on; }
bool advancedCloudsActive() { return g_enabled && (g_features & ADV_CLOUDS); }
void advancedSetFeatures(uint32_t f) { g_features = f; }

void advancedSetTables(const uint8_t* materials, const uint8_t* emissions) {
    g_materials = [device() newBufferWithBytes:materials length:65536 options:MTLResourceStorageModeShared];
    g_emissions = [device() newBufferWithBytes:emissions length:65536 options:MTLResourceStorageModeShared];
}

namespace {

struct Targets {
    int w = 0, h = 0;
    id<MTLTexture> albedo, normal, light, linZ, spec, hdr, sceneColor, sceneDepth, taa[2], vol;
    std::vector<id<MTLTexture>> bloom;
};

struct State {
    bool init = false;
    id<MTLRenderPipelineState> gTerrain[4], gGeneric[2], shadowTerrain[4], shadowGeneric[2];
    id<MTLRenderPipelineState> lightPso[2], waterPso[2], tonemapPso, bloomDown, bloomUp, skyLutPso, taaPso, cloudsPso;
    // volumetric clouds
    id<MTLComputePipelineState> cloudNoiseKernel;
    id<MTLRenderPipelineState> volPso, volCompPso;
    id<MTLComputePipelineState> exposureKernel;
    id<MTLBuffer> exposureState;
    id<MTLTexture> cloudNoise, cloudMap[2];
    id<MTLSamplerState> repeatLinear;
    bool cloudNoiseReady = false, cloudHistory = false;
    int cloudIndex = 0;
    // TAA history
    simd_float4x4 prevViewProj = matrix_identity_float4x4;
    double prevCam[3] = {0, 0, 0};
    int prevDim = 0;
    bool historyValid = false;
    int taaIndex = 0;
    id<MTLTexture> skyLut;
    id<MTLDepthStencilState> depthWrite, depthTestNoWrite, depthAlways;
    id<MTLSamplerState> shadowCmp, linearClamp, pointClamp;
    id<MTLTexture> shadowMap;
    int shadowRes = 0;
    Targets t;
    id<MTLBuffer> quadIdx;
    uint32_t quadIdxQuads = 0;
    uint64_t frame = 0;
};
State S;

id<MTLFunction> fn(NSString* name, bool alpha = false, bool waving = false, bool raytrace = false) {
    MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
    [cv setConstantValue:&alpha type:MTLDataTypeBool atIndex:10];
    [cv setConstantValue:&waving type:MTLDataTypeBool atIndex:11];
    [cv setConstantValue:&raytrace type:MTLDataTypeBool atIndex:12];
    NSError* err = nil;
    id<MTLFunction> f = [engine().library newFunctionWithName:name constantValues:cv error:&err];
    if (!f) log("advanced: function %s: %s", name.UTF8String, err.localizedDescription.UTF8String);
    return f;
}

id<MTLRenderPipelineState> pso(MTLRenderPipelineDescriptor* d) {
    NSError* err = nil;
    id<MTLRenderPipelineState> p = [device() newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) log("advanced: pipeline: %s", err.localizedDescription.UTF8String);
    return p;
}

MTLRenderPipelineDescriptor* gbufDesc(id<MTLFunction> v, id<MTLFunction> f) {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = v;
    d.fragmentFunction = f;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
    d.colorAttachments[2].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.colorAttachments[3].pixelFormat = MTLPixelFormatR32Float;
    d.colorAttachments[4].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    return d;
}

bool initState() {
    if (S.init) return true;
    for (int i = 0; i < 4; i++) {
        bool alpha = i & 1, waving = (i >> 1) & 1;
        S.gTerrain[i] = pso(gbufDesc(fn(@"gbuf_terrain_vertex", alpha, waving), fn(@"gbuf_terrain_fragment", alpha, waving)));
    }
    for (int i = 0; i < 4; i++) {
        bool alpha = i & 1, waving = (i >> 1) & 1;
        MTLRenderPipelineDescriptor* sd = [MTLRenderPipelineDescriptor new];
        sd.vertexFunction = fn(@"shadow_terrain_vertex", alpha, waving);
        sd.fragmentFunction = fn(@"shadow_fragment", alpha);
        sd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        S.shadowTerrain[i] = pso(sd);
    }
    for (int i = 0; i < 2; i++) {
        S.gGeneric[i] = pso(gbufDesc(fn(@"gbuf_generic_vertex", i), fn(@"gbuf_generic_fragment", i)));
        MTLRenderPipelineDescriptor* sd = [MTLRenderPipelineDescriptor new];
        sd.vertexFunction = fn(@"shadow_generic_vertex", i);
        sd.fragmentFunction = fn(@"shadow_fragment", i);
        sd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        S.shadowGeneric[i] = pso(sd);
    }
    MTLRenderPipelineDescriptor* ld = [MTLRenderPipelineDescriptor new];
    ld.vertexFunction = fn(@"fullscreen_vertex");
    ld.fragmentFunction = fn(@"light_fragment");
    ld.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.lightPso[0] = pso(ld);
    if (rtAvailable()) {
        ld.fragmentFunction = fn(@"light_fragment", false, false, true);
        S.lightPso[1] = pso(ld);
    }

    {
        NSError* err = nil;
        id<MTLFunction> k = fn(@"cloud_noise_kernel");
        S.cloudNoiseKernel = k ? [device() newComputePipelineStateWithFunction:k error:&err] : nil;
        if (!S.cloudNoiseKernel) log("advanced: cloud noise kernel: %s", err ? err.localizedDescription.UTF8String : "missing");
        MTLTextureDescriptor* nd = [MTLTextureDescriptor new];
        nd.textureType = MTLTextureType3D;
        nd.pixelFormat = MTLPixelFormatRGBA8Unorm;
        nd.width = nd.height = nd.depth = 128;
        nd.storageMode = MTLStorageModePrivate;
        nd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        S.cloudNoise = [device() newTextureWithDescriptor:nd];
        S.cloudNoise.label = @"cloudNoise";
        for (int i = 0; i < 2; i++) {
            MTLTextureDescriptor* cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                         width:768 height:320 mipmapped:NO];
            cd.storageMode = MTLStorageModePrivate;
            cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            S.cloudMap[i] = [device() newTextureWithDescriptor:cd];
            S.cloudMap[i].label = @"cloudMap";
        }
        MTLRenderPipelineDescriptor* cl = [MTLRenderPipelineDescriptor new];
        cl.vertexFunction = fn(@"fullscreen_vertex");
        cl.fragmentFunction = fn(@"clouds_fragment");
        cl.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        S.cloudsPso = pso(cl);
        MTLSamplerDescriptor* rs = [MTLSamplerDescriptor new];
        rs.minFilter = rs.magFilter = MTLSamplerMinMagFilterLinear;
        rs.sAddressMode = rs.tAddressMode = rs.rAddressMode = MTLSamplerAddressModeRepeat;
        S.repeatLinear = [device() newSamplerStateWithDescriptor:rs];
    }

    {
        NSError* err = nil;
        id<MTLFunction> k = fn(@"exposure_kernel");
        S.exposureKernel = k ? [device() newComputePipelineStateWithFunction:k error:&err] : nil;
        S.exposureState = [device() newBufferWithLength:16 options:MTLResourceStorageModeShared];
        memset(S.exposureState.contents, 0, 16);
    }

    MTLRenderPipelineDescriptor* vd = [MTLRenderPipelineDescriptor new];
    vd.vertexFunction = fn(@"fullscreen_vertex");
    vd.fragmentFunction = fn(@"volumetric_fragment");
    vd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.volPso = pso(vd);
    vd.fragmentFunction = fn(@"volcomp_fragment");
    vd.colorAttachments[0].blendingEnabled = YES;
    vd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    vd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    vd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
    vd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    S.volCompPso = pso(vd);

    MTLRenderPipelineDescriptor* ta = [MTLRenderPipelineDescriptor new];
    ta.vertexFunction = fn(@"fullscreen_vertex");
    ta.fragmentFunction = fn(@"taa_fragment");
    ta.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.taaPso = pso(ta);

    MTLRenderPipelineDescriptor* sl = [MTLRenderPipelineDescriptor new];
    sl.vertexFunction = fn(@"fullscreen_vertex");
    sl.fragmentFunction = fn(@"skylut_fragment");
    sl.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.skyLutPso = pso(sl);
    MTLTextureDescriptor* ltd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:256 height:128 mipmapped:YES];
    ltd.storageMode = MTLStorageModePrivate;
    ltd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    S.skyLut = [device() newTextureWithDescriptor:ltd];

    MTLRenderPipelineDescriptor* wd = [MTLRenderPipelineDescriptor new];
    wd.vertexFunction = fn(@"water_vertex");
    wd.fragmentFunction = fn(@"water_fragment");
    wd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    wd.colorAttachments[0].blendingEnabled = YES;
    wd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    wd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    wd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    wd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    wd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    S.waterPso[0] = pso(wd);
    if (rtAvailable()) {
        wd.fragmentFunction = fn(@"water_fragment", false, false, true);
        S.waterPso[1] = pso(wd);
    }

    MTLRenderPipelineDescriptor* td = [MTLRenderPipelineDescriptor new];
    td.vertexFunction = fn(@"fullscreen_vertex");
    td.fragmentFunction = fn(@"tonemap_fragment");
    td.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    S.tonemapPso = pso(td);

    MTLRenderPipelineDescriptor* bd = [MTLRenderPipelineDescriptor new];
    bd.vertexFunction = fn(@"fullscreen_vertex");
    bd.fragmentFunction = fn(@"bloom_down_fragment");
    bd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.bloomDown = pso(bd);
    bd.fragmentFunction = fn(@"bloom_up_fragment");
    bd.colorAttachments[0].blendingEnabled = YES;
    bd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    bd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    bd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    bd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    S.bloomUp = pso(bd);

    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLessEqual;
    dd.depthWriteEnabled = YES;
    S.depthWrite = [device() newDepthStencilStateWithDescriptor:dd];
    dd.depthWriteEnabled = NO;
    S.depthTestNoWrite = [device() newDepthStencilStateWithDescriptor:dd];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    S.depthAlways = [device() newDepthStencilStateWithDescriptor:dd];

    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.compareFunction = MTLCompareFunctionLessEqual;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    S.shadowCmp = [device() newSamplerStateWithDescriptor:sd];
    MTLSamplerDescriptor* lin = [MTLSamplerDescriptor new];
    lin.minFilter = lin.magFilter = MTLSamplerMinMagFilterLinear;
    lin.sAddressMode = lin.tAddressMode = MTLSamplerAddressModeClampToEdge;
    S.linearClamp = [device() newSamplerStateWithDescriptor:lin];
    MTLSamplerDescriptor* pt = [MTLSamplerDescriptor new];
    pt.minFilter = pt.magFilter = MTLSamplerMinMagFilterNearest;
    pt.sAddressMode = pt.tAddressMode = MTLSamplerAddressModeClampToEdge;
    S.pointClamp = [device() newSamplerStateWithDescriptor:pt];
    S.init = S.lightPso[0] && S.tonemapPso && S.gTerrain[0];
    return S.init;
}

id<MTLTexture> rt(MTLPixelFormat f, int w, int h, NSString* label) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [device() newTextureWithDescriptor:d];
    t.label = label;
    return t;
}

void ensureTargets(int w, int h) {
    if (S.t.w == w && S.t.h == h && S.t.albedo) return;
    S.t.w = w;
    S.t.h = h;
    S.t.albedo = rt(MTLPixelFormatRGBA8Unorm, w, h, @"gAlbedo");
    S.t.normal = rt(MTLPixelFormatRGBA16Float, w, h, @"gNormal");
    S.t.light = rt(MTLPixelFormatRGBA8Unorm, w, h, @"gLight");
    S.t.linZ = rt(MTLPixelFormatR32Float, w, h, @"gLinZ");
    S.t.spec = rt(MTLPixelFormatRGBA8Unorm, w, h, @"gSpec");
    S.t.hdr = rt(MTLPixelFormatRGBA16Float, w, h, @"hdr");
    S.t.taa[0] = rt(MTLPixelFormatRGBA16Float, w, h, @"taa0");
    S.t.taa[1] = rt(MTLPixelFormatRGBA16Float, w, h, @"taa1");
    S.t.vol = rt(MTLPixelFormatRGBA16Float, (w + 1) / 2, (h + 1) / 2, @"volumetric");
    S.historyValid = false;
    S.t.sceneColor = rt(MTLPixelFormatRGBA16Float, w, h, @"sceneColor");
    S.t.sceneDepth = rt(MTLPixelFormatDepth32Float, w, h, @"sceneDepth");
    S.t.bloom.clear();
    int bw = w, bh = h;
    for (int i = 0; i < 6 && bw > 8 && bh > 8; i++) {
        bw = std::max(1, bw / 2);
        bh = std::max(1, bh / 2);
        S.t.bloom.push_back(rt(MTLPixelFormatRGBA16Float, bw, bh, @"bloom"));
    }
}

void ensureShadowMap(int res) {
    if (S.shadowMap && S.shadowRes == res) return;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:res height:res mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    S.shadowMap = [device() newTextureWithDescriptor:d];
    S.shadowRes = res;
}

id<MTLBuffer> quadIndices(uint32_t quads) {
    if (S.quadIdx && quads <= S.quadIdxQuads) return S.quadIdx;
    uint32_t n = std::max<uint32_t>(65536, (quads + 65535) & ~65535u);
    id<MTLBuffer> b = [device() newBufferWithLength:(size_t)n * 24 options:MTLResourceStorageModeShared];
    uint32_t* p = (uint32_t*)b.contents;
    for (uint32_t q = 0; q < n; q++) {
        uint32_t v = q * 4;
        if (g_optQuadDiagonal) {
            p[q * 6] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 3; p[q * 6 + 3] = v + 1; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        } else {
            p[q * 6] = v; p[q * 6 + 1] = v + 1; p[q * 6 + 2] = v + 2; p[q * 6 + 3] = v; p[q * 6 + 4] = v + 2; p[q * 6 + 5] = v + 3;
        }
    }
    S.quadIdx = b;
    S.quadIdxQuads = n;
    return b;
}

simd_float4x4 m4(const float* f) { simd_float4x4 m; memcpy(&m, f, sizeof m); return m; }

// Section transform: same float math as glTranslatef + the chunk matrix.
void sectionMatrix(const simd_float4x4& mv, float ox, float oy, float oz, float* out) {
    float m[16];
    memcpy(m, &mv, sizeof m);
    m[12] += m[0] * ox + m[4] * oy + m[8] * oz;
    m[13] += m[1] * ox + m[5] * oy + m[9] * oz;
    m[14] += m[2] * ox + m[6] * oy + m[10] * oz;
    m[15] += m[3] * ox + m[7] * oy + m[11] * oz;
    const float f = 1.000001f, t = 8.0f * f - 8.0f;
    float c[16] = {f, 0, 0, 0, 0, f, 0, 0, 0, 0, f, 0, t, t, t, 1};
    for (int col = 0; col < 4; col++)
        for (int r = 0; r < 4; r++)
            out[col * 4 + r] = m[r] * c[col * 4] + m[4 + r] * c[col * 4 + 1] + m[8 + r] * c[col * 4 + 2] + m[12 + r] * c[col * 4 + 3];
}

simd_float3 normalize3(simd_float3 v) { float l = simd_length(v); return l > 0 ? v / l : v; }

// Transmittance of the atmosphere towards `dir` from the ground (matches adv.metal's model).
simd_float3 transmittance(simd_float3 dir) {
    const double Re = 6360e3, Ra = 6460e3;
    double ox = 0, oy = Re + 120.0, oz = 0;
    double b = oy * dir.y, c = oy * oy - Ra * Ra;
    double t = -b + sqrt(std::max(0.0, b * b - c));
    double bg = oy * dir.y, cg = oy * oy - Re * Re, hg = bg * bg - cg;
    if (dir.y < 0 && hg > 0 && -bg - sqrt(hg) > 0) return simd_make_float3(0, 0, 0);
    const int N = 32;
    double ds = t / N, odR = 0, odM = 0;
    for (int i = 0; i < N; i++) {
        double s = (i + 0.5) * ds;
        double px = ox + dir.x * s, py = oy + dir.y * s, pz = oz + dir.z * s;
        double h = sqrt(px * px + py * py + pz * pz) - Re;
        odR += exp(-h / 8000.0) * ds;
        odM += exp(-h / 1200.0) * ds;
    }
    return simd_make_float3((float)exp(-(5.8e-6 * odR + 21e-6 * 1.1 * odM)), (float)exp(-(13.5e-6 * odR + 21e-6 * 1.1 * odM)),
                            (float)exp(-(33.1e-6 * odR + 21e-6 * 1.1 * odM)));
}

// Orthographic light projection centred on the camera, snapped to shadow texels
// in absolute world space so shadows do not shimmer as the camera moves.
simd_float4x4 shadowMatrix(const EnvCmd& env, simd_float3 sunWorld, float radius, int res) {
    simd_float3 fwd = -sunWorld;
    simd_float3 up = fabsf(fwd.y) > 0.99f ? simd_make_float3(0, 0, 1) : simd_make_float3(0, 1, 0);
    simd_float3 right = normalize3(simd_cross(up, fwd));
    simd_float3 u = simd_cross(fwd, right);
    double ax = env.camBlockX + (double)env.camFracX, ay = env.camBlockY + (double)env.camFracY, az = env.camBlockZ + (double)env.camFracZ;
    float texel = 2.0f * radius / res;
    double pr = ax * right.x + ay * right.y + az * right.z;
    double pu = ax * u.x + ay * u.y + az * u.z;
    float offR = (float)(floor(pr / texel) * texel - pr);
    float offU = (float)(floor(pu / texel) * texel - pu);
    // light view: columns are the basis; translate so the snapped centre maps to 0
    simd_float4x4 view = {{
        {right.x, u.x, fwd.x, 0}, {right.y, u.y, fwd.y, 0}, {right.z, u.z, fwd.z, 0}, {-offR, -offU, 0, 1}}};
    float depth = 256.0f;
    simd_float4x4 ortho = {{
        {1.0f / radius, 0, 0, 0}, {0, 1.0f / radius, 0, 0}, {0, 0, 0.5f / depth, 0}, {0, 0, 0.5f, 1}}};
    return simd_mul(ortho, view);
}

} // namespace

void advancedRender(id<MTLCommandBuffer> cb, const AdvWorld& w, id<MTLTexture> color, id<MTLTexture> depth) {
    if (!color || !depth || !initState() || !g_materials || !w.hasEnv) return;
    int W = (int)color.width, H = (int)color.height;
    ensureTargets(W, H);
    const EnvCmd& env = w.env;
    S.frame++;

    // ---- frame constants ----
    AdvFrame fr{};
    fr.proj = m4(env.proj);
    fr.invProj = simd_inverse(fr.proj);
    fr.view = m4(env.view);
    fr.invView = simd_inverse(fr.view);
    float ang = env.celestialAngle * 2.0f * (float)M_PI;
    simd_float3 sun = simd_make_float3(-sinf(ang), cosf(ang), 0.0f);
    float sunH = sun.y;
    float day = std::clamp((sunH + 0.05f) / 0.2f, 0.0f, 1.0f);
    float night = std::clamp(-sunH / 0.2f, 0.0f, 1.0f);
    float rain = env.rain;
    simd_float3 sunViewDir = simd_make_float3(simd_mul(fr.view, simd_make_float4(sun, 0)));
    fr.sunDirView = simd_make_float4(normalize3(sunViewDir), day > 0.001f ? 1.0f : 0.0f);
    fr.moonDirView = simd_make_float4(normalize3(-sunViewDir), 0);
    fr.sunDirWorld = simd_make_float4(sun, day);
    simd_float3 sunCol = transmittance(simd_make_float3(sun.x, std::max(sun.y, 0.02f), sun.z));
    fr.sunColor = simd_make_float4(sunCol * 2.5f * day * (1.0f - rain * 0.85f), 1);
    fr.moonColor = simd_make_float4(simd_make_float3(0.13f, 0.16f, 0.25f) * night * (1.0f - rain * 0.7f), 1);
    auto lin = [](float c) { return powf(std::max(c, 0.0f), 2.2f); };
    simd_float3 skyV = simd_make_float3(lin(env.skyR), lin(env.skyG), lin(env.skyB));
    simd_float3 fogV = simd_make_float3(lin(w.fogColor[0]), lin(w.fogColor[1]), lin(w.fogColor[2]));
    fr.skyZenith = simd_make_float4(skyV * 1.1f, 1);
    fr.skyHorizon = simd_make_float4(simd_mix(skyV, fogV, simd_make_float3(0.7f, 0.7f, 0.7f)) * 1.2f, 1);
    // sky ambient: the sky colour with most of its saturation removed (it is an integral over the dome)
    simd_float3 skyMix = skyV * 0.6f + fogV * 0.4f;
    float skyLum = simd_dot(skyMix, simd_make_float3(0.2126f, 0.7152f, 0.0722f));
    simd_float3 amb = simd_mix(simd_make_float3(skyLum, skyLum, skyLum), skyMix, simd_make_float3(0.45f, 0.45f, 0.45f)) * 0.75f;
    amb += simd_make_float3(0.030f, 0.036f, 0.052f) * night;   // moonlit sky
    fr.ambient = simd_make_float4(amb, 1.0f);
    fr.blockLight = simd_make_float4(1.0f * 1.7f, 0.60f * 1.7f, 0.30f * 1.7f, 2.2f);
    fr.fog = simd_make_float4(w.fogStart, w.fogEnd, rain, (float)env.inFluid);
    fr.fogColor = simd_make_float4(w.fogColor[0], w.fogColor[1], w.fogColor[2], 1);
    float shadowRadius = g_shadowDistance;
    fr.params = simd_make_float4(env.timeSeconds, rain, g_exposure, shadowRadius);
    fr.post = simd_make_float4(g_bloomStrength, 0, 0, 0);
    fr.screen = simd_make_float4(W, H, 1.0f / W, 1.0f / H);
    fr.camera = simd_make_float4(env.camFracX + (float)(env.camBlockX & 1023), env.camFracY + (float)(env.camBlockY & 1023),
                                 env.camFracZ + (float)(env.camBlockZ & 1023), env.starBrightness);
    uint32_t features = g_features;
    if (env.dimension != 0) features &= ~(ADV_SHADOWS | ADV_RT_SHADOW); // no sun in the Nether / End
    double camX = env.camBlockX + (double)env.camFracX, camY = env.camBlockY + (double)env.camFracY,
           camZ = env.camBlockZ + (double)env.camFracZ;
    RtScene rts;
    bool rtOn = (features & (ADV_RT_SHADOW | ADV_RT_REFL)) && S.lightPso[1] && S.waterPso[1] &&
                rtPrepare(cb, camX, camY, camZ, std::max(env.renderDistance, 32.0f) + 16.0f, rts);
    if (!rtOn) features &= ~(ADV_RT_SHADOW | ADV_RT_REFL);
    fr.rtCam = simd_make_float4(rts.camera, 0);

    // TAA: Halton(2,3) sub-pixel jitter; history is reprojected with the camera motion
    bool taaOn = (features & ADV_TAA) && S.taaPso;
    if (!taaOn) features &= ~ADV_TAA;
    {
        static const float h2[8] = {0.5f, 0.25f, 0.75f, 0.125f, 0.625f, 0.375f, 0.875f, 0.0625f};
        static const float h3[8] = {1 / 3.0f, 2 / 3.0f, 1 / 9.0f, 4 / 9.0f, 7 / 9.0f, 2 / 9.0f, 5 / 9.0f, 8 / 9.0f};
        int k = (int)(S.frame % 8);
        if (taaOn) fr.jitter = simd_make_float4((h2[k] - 0.5f) * 2.0f / W, (h3[k] - 0.5f) * 2.0f / H, 0, 0);
        double dx = camX - S.prevCam[0], dy = camY - S.prevCam[1], dz = camZ - S.prevCam[2];
        bool valid = taaOn && S.historyValid && S.prevDim == env.dimension && fabs(dx) + fabs(dy) + fabs(dz) < 16.0;
        fr.prevViewProj = S.prevViewProj;
        fr.taa = simd_make_float4((float)dx, (float)dy, (float)dz, valid ? 1.0f : 0.0f);
        S.prevViewProj = simd_mul(fr.proj, fr.view);
        S.prevCam[0] = camX; S.prevCam[1] = camY; S.prevCam[2] = camZ;
        S.prevDim = env.dimension;
        S.historyValid = taaOn;
    }
    if (env.dimension != 0 || !S.cloudsPso || !S.cloudNoiseKernel) features &= ~ADV_CLOUDS;
    if (!(features & ADV_SHADOWS) || !S.volPso) features &= ~ADV_VOLUMETRIC;
    if (!S.exposureKernel) features &= ~ADV_AUTOEXP;
    TexEntry* pbrN = g_pbrNormal ? texture(g_pbrNormal) : nullptr;
    TexEntry* pbrS = g_pbrSpecular ? texture(g_pbrSpecular) : nullptr;
    if (pbrN && pbrN->tex && pbrS && pbrS->tex) features |= ADV_PBR;
    else features &= ~ADV_PBR;
    bool cloudsOn = (features & ADV_CLOUDS) != 0;
    fr.post.y = cloudsOn && S.cloudHistory && fr.taa.w > 0.5f ? 1.0f : 0.0f; // teleports reset the cloud history too
    if (!taaOn) fr.post.y = cloudsOn && S.cloudHistory ? 1.0f : 0.0f;
    S.cloudHistory = cloudsOn;
    fr.flags = simd_make_uint4(features, (uint32_t)env.dimension, (uint32_t)S.frame, (uint32_t)g_optAdvDebug);
    int shadowRes = g_shadowRes;
    if (features & ADV_SHADOWS) {
        ensureShadowMap(shadowRes);
        simd_float3 lightDir = day > 0.001f ? sun : -sun;
        fr.shadowViewProj = shadowMatrix(env, lightDir, shadowRadius, shadowRes);
    }

    // ---- shadow pass ----
    if (features & ADV_SHADOWS) {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = S.shadowMap;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1.0;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        profRender(rp, "shadow");
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"shadow";
        [e setDepthStencilState:S.depthWrite];
        [e setCullMode:MTLCullModeNone];
        [e setDepthBias:1.0f slopeScale:1.5f clamp:0.01f];
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        // Every loaded section near the camera casts shadows, not just the visible ones
        // (with ray-traced shadows the map only holds dynamic geometry).
        float reach = shadowRadius + 24.0f;
        // (volumetric light still needs terrain in the map)
        bool terrainInMap = !(features & ADV_RT_SHADOW) || (features & ADV_VOLUMETRIC);
        for (int layer = 0; layer < (terrainInMap ? 3 : 0); layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.shadowTerrain[(alpha ? 1 : 0) | (g_waving ? 2 : 0)]];
            const uint32_t* sp = w.layerSampler[layer];
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            for (const auto& kv : allSections()) {
                const Section* s = &kv.second;
                if (!s->layers[layer]) continue;
                float tx = (float)(s->ox - camX), ty = (float)(s->oy - camY), tz = (float)(s->oz - camZ);
                if (fabsf(tx + 8) > reach || fabsf(tz + 8) > reach || fabsf(ty + 8) > reach + 64) continue;
                simd_float4 off = simd_make_float4(tx, ty, tz, 0);
                [e setVertexBytes:&off length:sizeof off atIndex:4];
                [e setVertexBuffer:s->layers[layer] offset:0 atIndex:0];
                uint32_t quads = s->vertices[layer] / 4;
                [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                             indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
        }
        // captured opaque geometry (entities, block entities)
        for (const AdvGeometry& g : w.geometry) {
            const VertexLayout* L = layout(g.format);
            TexEntry* tex = texture(g.tex);
            if (!L || !tex || !tex->tex || g.prim != 7) continue;
            [e setRenderPipelineState:S.shadowGeneric[g.alphaTest ? 1 : 0]];
            DrawTransform xf;
            xf.modelview = g.mv;
            xf.normal0 = g.normal.columns[0];
            xf.normal1 = g.normal.columns[1];
            xf.normal2 = g.normal.columns[2];
            [e setVertexBytes:&xf length:sizeof xf atIndex:3];
            [e setVertexBytes:L length:sizeof(VertexLayout) atIndex:2];
            [e setVertexBytes:&g.item length:sizeof g.item atIndex:4];
            [e setVertexBytes:&g.texMat length:sizeof g.texMat atIndex:5];
            [e setFragmentTexture:tex->tex atIndex:0];
            const uint32_t* sp = g.sampler;
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            [e setVertexBuffer:g.vb offset:g.vbOffset + (size_t)g.firstVertex * L->stride.x atIndex:0];
            uint32_t quads = g.count / 4;
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                         indexBuffer:quadIndices(quads) indexBufferOffset:0];
        }
        [e endEncoding];
    }

    // ---- G-buffer ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLTexture> att[5] = {S.t.albedo, S.t.normal, S.t.light, S.t.linZ, S.t.spec};
        for (int i = 0; i < 5; i++) {
            rp.colorAttachments[i].texture = att[i];
            rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        }
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1.0;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            rp.stencilAttachment.texture = depth;
            rp.stencilAttachment.loadAction = MTLLoadActionClear;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        profRender(rp, "gbuffer");
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"gbuffer";
        [e setDepthStencilState:S.depthWrite];
        [e setCullMode:MTLCullModeBack];
        [e setFrontFacingWinding:MTLWindingClockwise]; // GL CCW, flipped target
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        [e setVertexBuffer:g_emissions offset:0 atIndex:6];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        bool pbr = (features & ADV_PBR) != 0;
        [e setFragmentTexture:pbr ? pbrN->tex : (atlas ? atlas->tex : nil) atIndex:1];
        [e setFragmentTexture:pbr ? pbrS->tex : (atlas ? atlas->tex : nil) atIndex:2];
        for (int layer = 0; layer < 3; layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.gTerrain[(alpha ? 1 : 0) | (g_waving ? 2 : 0)]];
            const uint32_t* sp = w.layerSampler[layer];
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            for (const AdvTerrainEntry& t : w.terrain[layer]) {
                Section* s = section((int)t.section);
                if (!s || !s->layers[layer]) continue;
                float mv[16];
                sectionMatrix(w.view, t.x, t.y, t.z, mv);
                [e setVertexBytes:mv length:sizeof mv atIndex:3];
                simd_float4 off = simd_make_float4(t.x, t.y, t.z, 0);
                [e setVertexBytes:&off length:sizeof off atIndex:4];
                [e setVertexBuffer:s->layers[layer] offset:0 atIndex:0];
                uint32_t quads = s->vertices[layer] / 4;
                [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                             indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
        }
        // captured opaque geometry (entities, block entities)
        for (const AdvGeometry& g : w.geometry) {
            const VertexLayout* L = layout(g.format);
            TexEntry* tex = texture(g.tex);
            if (!L || !tex || !tex->tex || g.prim != 7) continue;
            [e setRenderPipelineState:S.gGeneric[g.alphaTest ? 1 : 0]];
            [e setCullMode:g.cull ? (g.cullFace == 0x404 ? MTLCullModeFront : MTLCullModeBack) : MTLCullModeNone];
            DrawTransform xf;
            xf.modelview = g.mv;
            xf.normal0 = g.normal.columns[0];
            xf.normal1 = g.normal.columns[1];
            xf.normal2 = g.normal.columns[2];
            [e setVertexBytes:&xf length:sizeof xf atIndex:3];
            [e setVertexBytes:L length:sizeof(VertexLayout) atIndex:2];
            [e setVertexBytes:&g.item length:sizeof g.item atIndex:4];
            [e setFragmentBytes:&g.item length:sizeof g.item atIndex:4];
            [e setVertexBytes:&g.texMat length:sizeof g.texMat atIndex:5];
            [e setFragmentTexture:tex->tex atIndex:0];
            const uint32_t* sp = g.sampler;
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            [e setVertexBuffer:g.vb offset:g.vbOffset + (size_t)g.firstVertex * L->stride.x atIndex:0];
            uint32_t quads = g.count / 4;
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                         indexBuffer:quadIndices(quads) indexBufferOffset:0];
        }
        [e endEncoding];
    }

    // ---- sky-view LUT (+ mips used as ambient irradiance) ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.skyLut;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "skylut", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"skylut";
        [e setRenderPipelineState:S.skyLutPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        MTLBlitPassDescriptor* bp = [MTLBlitPassDescriptor blitPassDescriptor];
        profBlit(bp, "skylut mips");
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoderWithDescriptor:bp];
        [b generateMipmapsForTexture:S.skyLut];
        [b endEncoding];
    }

    // ---- volumetric clouds -> direction-space cloud map ----
    id<MTLTexture> cloudMap = S.skyLut;   // placeholder binding when clouds are off
    if (cloudsOn) {
        if (!S.cloudNoiseReady) {
            id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
            c.label = @"cloud noise";
            [c setComputePipelineState:S.cloudNoiseKernel];
            [c setTexture:S.cloudNoise atIndex:0];
            [c dispatchThreads:MTLSizeMake(128, 128, 128) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
            [c endEncoding];
            S.cloudNoiseReady = true;
        }
        id<MTLTexture> out = S.cloudMap[S.cloudIndex], prev = S.cloudMap[S.cloudIndex ^ 1];
        S.cloudIndex ^= 1;
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = out;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "clouds", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"clouds";
        [e setRenderPipelineState:S.cloudsPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.cloudNoise atIndex:0];
        [e setFragmentTexture:S.skyLut atIndex:1];
        [e setFragmentTexture:prev atIndex:2];
        [e setFragmentSamplerState:S.repeatLinear atIndex:0];
        [e setFragmentSamplerState:S.linearClamp atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        cloudMap = out;
    }

    // ---- lighting + sky -> HDR ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.hdr;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "lighting", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"lighting";
        bool rtLight = (features & (ADV_RT_SHADOW | ADV_RT_REFL)) != 0;
        [e setRenderPipelineState:S.lightPso[rtLight ? 1 : 0]];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.t.albedo atIndex:0];
        [e setFragmentTexture:S.t.normal atIndex:1];
        [e setFragmentTexture:S.t.light atIndex:2];
        [e setFragmentTexture:depth atIndex:3];
        [e setFragmentTexture:(features & ADV_SHADOWS) ? S.shadowMap : depth atIndex:4];
        [e setFragmentTexture:S.skyLut atIndex:5];
        [e setFragmentSamplerState:S.shadowCmp atIndex:0];
        [e setFragmentSamplerState:S.linearClamp atIndex:1];
        [e setFragmentTexture:S.t.linZ atIndex:6];
        [e setFragmentTexture:cloudMap atIndex:8];
        [e setFragmentTexture:S.cloudNoise atIndex:9];
        [e setFragmentTexture:S.t.spec atIndex:10];
        // last frame's resolved image (screen-space reflections on smooth surfaces)
        [e setFragmentTexture:taaOn ? S.t.taa[S.taaIndex ^ 1] : S.t.hdr atIndex:11];
        [e setFragmentSamplerState:S.repeatLinear atIndex:3];
        if (rtLight) {
            TexEntry* atlas = texture(w.atlasTex);
            [e setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [e setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [e setFragmentTexture:atlas && atlas->tex ? atlas->tex : S.t.albedo atIndex:7];
            [e setFragmentSamplerState:S.pointClamp atIndex:2];
            if (rts.resources)
                [e useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        }
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }

    // ---- translucent terrain (water, glass, ice) ----
    if (!w.terrain[3].empty()) {
        // refraction and screen-space reflections read the opaque scene from copies
        MTLBlitPassDescriptor* bp = [MTLBlitPassDescriptor blitPassDescriptor];
        profBlit(bp, "scene copy");
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoderWithDescriptor:bp];
        [b copyFromTexture:S.t.hdr toTexture:S.t.sceneColor];
        if (depth.pixelFormat == S.t.sceneDepth.pixelFormat) [b copyFromTexture:depth toTexture:S.t.sceneDepth];
        [b endEncoding];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.hdr;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionLoad;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            rp.stencilAttachment.texture = depth;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        profRender(rp, "translucent");
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"translucent";
        bool rtWater = (features & ADV_RT_REFL) != 0;
        [e setRenderPipelineState:S.waterPso[rtWater ? 1 : 0]];
        if (rtWater) {
            [e setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [e setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [e setFragmentSamplerState:S.pointClamp atIndex:3];
            if (rts.resources)
                [e useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        }
        [e setDepthStencilState:S.depthTestNoWrite];
        [e setCullMode:MTLCullModeBack];
        [e setFrontFacingWinding:MTLWindingClockwise];
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        [e setFragmentTexture:(features & ADV_SHADOWS) ? S.shadowMap : depth atIndex:4];
        [e setFragmentSamplerState:S.shadowCmp atIndex:1];
        [e setFragmentTexture:S.skyLut atIndex:5];
        [e setFragmentSamplerState:S.linearClamp atIndex:2];
        [e setFragmentTexture:S.t.sceneColor atIndex:6];
        [e setFragmentTexture:S.t.sceneDepth atIndex:7];
        [e setFragmentTexture:cloudMap atIndex:8];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        const uint32_t* sp = w.layerSampler[3];
        [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                              *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
        for (const AdvTerrainEntry& t : w.terrain[3]) {
            Section* s = section((int)t.section);
            if (!s || !s->layers[3]) continue;
            float mv[16];
            sectionMatrix(w.view, t.x, t.y, t.z, mv);
            [e setVertexBytes:mv length:sizeof mv atIndex:3];
            simd_float4 off = simd_make_float4(t.x, t.y, t.z, 0);
            [e setVertexBytes:&off length:sizeof off atIndex:4];
            [e setVertexBuffer:s->layers[3] offset:0 atIndex:0];
            uint32_t quads = s->vertices[3] / 4;
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                         indexBuffer:quadIndices(quads) indexBufferOffset:0];
        }
        [e endEncoding];
    }

    // ---- volumetric light (half resolution, added to HDR) ----
    if (features & ADV_VOLUMETRIC) {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.vol;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "volumetric", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"volumetric";
        [e setRenderPipelineState:S.volPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:depth atIndex:0];
        [e setFragmentTexture:S.t.linZ atIndex:1];
        [e setFragmentTexture:S.shadowMap atIndex:2];
        [e setFragmentTexture:S.cloudNoise atIndex:3];
        [e setFragmentSamplerState:S.shadowCmp atIndex:0];
        [e setFragmentSamplerState:S.repeatLinear atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        MTLRenderPassDescriptor* cp = [MTLRenderPassDescriptor renderPassDescriptor];
        cp.colorAttachments[0].texture = S.t.hdr;
        cp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        cp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(cp, "volumetric composite", true);
        e = [cb renderCommandEncoderWithDescriptor:cp];
        e.label = @"volumetric composite";
        [e setRenderPipelineState:S.volCompPso];
        [e setFragmentTexture:S.t.vol atIndex:0];
        [e setFragmentSamplerState:S.linearClamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }

    // ---- temporal anti-aliasing ----
    id<MTLTexture> post = S.t.hdr;
    if (taaOn) {
        id<MTLTexture> out = S.t.taa[S.taaIndex], prev = S.t.taa[S.taaIndex ^ 1];
        S.taaIndex ^= 1;
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = out;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "taa", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"taa";
        [e setRenderPipelineState:S.taaPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.t.hdr atIndex:0];
        [e setFragmentTexture:prev atIndex:1];
        [e setFragmentTexture:depth atIndex:2];
        [e setFragmentSamplerState:S.linearClamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        post = out;
    }

    // ---- auto exposure (GPU-side adaptation, read by the tonemap pass) ----
    if (features & ADV_AUTOEXP) {
        if (g_optGpuStats && (S.frame % 300) == 0) {
            const float* st = (const float*)S.exposureState.contents;
            log("auto exposure %.3f (scene log-average luminance %.4f)", st[0], st[3]);
        }
        MTLComputePassDescriptor* cpd = [MTLComputePassDescriptor computePassDescriptor];
        profCompute(cpd, "exposure");
        id<MTLComputeCommandEncoder> c = [cb computeCommandEncoderWithDescriptor:cpd];
        c.label = @"exposure";
        [c setComputePipelineState:S.exposureKernel];
        [c setTexture:post atIndex:0];
        [c setBuffer:S.exposureState offset:0 atIndex:0];
        [c setBytes:&fr length:sizeof fr atIndex:1];
        [c dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [c endEncoding];
    }

    // ---- bloom ----
    if ((features & ADV_BLOOM) && !S.t.bloom.empty()) {
        id<MTLTexture> src = post;
        for (size_t i = 0; i < S.t.bloom.size(); i++) {
            id<MTLTexture> dst = S.t.bloom[i];
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = dst;
            rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(rp, "bloom", true);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:S.bloomDown];
            simd_float4 p = simd_make_float4(i == 0 ? 1.0f : 0.0f, 1.2f, 1.0f / src.width, 1.0f / src.height);
            [e setFragmentBytes:&p length:sizeof p atIndex:0];
            [e setFragmentTexture:src atIndex:0];
            [e setFragmentSamplerState:S.linearClamp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            src = dst;
        }
        for (size_t i = S.t.bloom.size() - 1; i > 0; i--) {
            id<MTLTexture> s = S.t.bloom[i], d = S.t.bloom[i - 1];
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = d;
            rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(rp, "bloom", true);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:S.bloomUp];
            simd_float4 p = simd_make_float4(0.75f, 0, 1.0f / s.width, 1.0f / s.height); // x: weight of the coarser level
            [e setFragmentBytes:&p length:sizeof p atIndex:0];
            [e setFragmentTexture:s atIndex:0];
            [e setFragmentSamplerState:S.linearClamp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
        }
    }

    // ---- tonemap into Minecraft's framebuffer ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = color;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "tonemap", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"tonemap";
        [e setRenderPipelineState:S.tonemapPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:post atIndex:0];
        [e setFragmentTexture:S.t.bloom.empty() ? post : S.t.bloom[0] atIndex:1];
        [e setFragmentBuffer:S.exposureState offset:0 atIndex:2];
        [e setFragmentSamplerState:S.linearClamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }
}

} // namespace m189
