// metal189: advanced (deferred PBR) world renderer.
//
// Pass order: shadow map -> G-buffer (terrain + captured opaque geometry, into
// Minecraft's own depth buffer) -> deferred lighting + sky (HDR) -> forward
// water/translucent terrain -> bloom -> tonemap into Minecraft's framebuffer.
// Everything not consumed here (particles, weather, hand, outlines...) is then
// replayed by the baseline executor on top.

#import "advanced.h"
#import "raytrace.h"
#import "voxels.h"
#import "upscale.h"
#import "interp.h"
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
static bool g_rtEntities = true;
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
        case 16: g_rtEntities = value != 0; break;
        default: break;
    }
}

static float g_tuning[kTuningValues];

void advancedSetTuning(const float* v, int n) {
    n = std::clamp(n, 0, kTuningValues);
    memcpy(g_tuning, v, (size_t)n * sizeof(float));
}

void advancedSetEnabled(bool on) { g_enabled = on; }
bool advancedCloudsActive() { return g_enabled && (g_features & ADV_CLOUDS); }
void advancedSetFeatures(uint32_t f) { g_features = f; }

static id<MTLBuffer> g_lightColors = nil;

void advancedSetTables(const uint8_t* materials, const uint8_t* emissions, const uint8_t* lightColors) {
    g_materials = [device() newBufferWithBytes:materials length:65536 options:MTLResourceStorageModeShared];
    g_emissions = [device() newBufferWithBytes:emissions length:65536 options:MTLResourceStorageModeShared];
    g_lightColors = [device() newBufferWithBytes:lightColors length:65536 * 4 options:MTLResourceStorageModeShared];
}

id<MTLBuffer> advancedLightColors() { return g_lightColors; }
bool advancedFrameInterpolation() { return g_tuning[72] > 0.5f; }
id<MTLBuffer> advancedMaterials() { return g_materials; }

namespace {

struct Targets {
    int w = 0, h = 0;      // render resolution
    id<MTLTexture> albedo, normal, light, linZ, spec, hdr, sceneColor, sceneDepth, taa[2], vol, ao[2];
    id<MTLTexture> giSample, giHist[2], giZ[2], giBlur[2];
    id<MTLTexture> reflTrace;   // ray-traced reflections (refl_trace_fragment)
    id<MTLTexture> blockRt;     // ray-traced block light (blocklight_trace_fragment)
    id<MTLTexture> sunRt;       // the lighting pass's rays: sun visibility, held light visibility (sun_trace_fragment)
    id<MTLTexture> blockHist[2], blockZ[2], blockBlur[2];   // its temporal accumulation and denoising
    id<MTLTexture> renderDepth, motion;   // upscaling: the scene's own depth, motion vectors
    id<MTLTexture> guide[5];              // denoised upscaling: diffuse, specular, normal, roughness, mask
    int ow = 0, oh = 0;    // output resolution (Minecraft's framebuffer)
    id<MTLTexture> up[2];  // upscaled HDR (this frame's, last frame's)
    std::vector<id<MTLTexture>> bloom;
};

struct State {
    bool init = false;
    id<MTLRenderPipelineState> gTerrain[4], gGeneric[2], shadowTerrain[4], shadowGeneric[2], shadowWater, shadowGlass;
    id<MTLTexture> waterShadow;          // water surfaces in light space (half the shadow map's resolution)
    id<MTLTexture> glassDepth, glassColor;   // tinted translucents in light space: nearest depth, light let through
    int glassRes = 0;
    int waterShadowRes = 0;
    id<MTLRenderPipelineState> reflTracePso = nil, sunTracePso = nil, blockTracePso = nil, blockTemporalPso = nil, blockBlurPso = nil;
    int blockIndex = 0;
    bool blockHistory = false;
    // terrain shadow cache (see the shadow pass)
    id<MTLTexture> shadowTerrainMap = nil;
    bool shadowCacheValid = false;
    simd_float3 shadowSun = {0, 0, 0};
    double shadowRc = 0, shadowUc = 0, shadowFc = 0;
    float shadowCacheRadius = 0;
    uint64_t shadowGen = 0;
    double shadowAt = 0;
    bool shadowWaving = false, shadowTerrainIn = false;
    id<MTLRenderPipelineState> lightPso[2], waterPso[2], tonemapPso, bloomDown, bloomUp, skyLutPso, taaPso, cloudsPso;
    // volumetric clouds
    id<MTLComputePipelineState> cloudNoiseKernel;
    id<MTLRenderPipelineState> volPso, volCompPso, rtaoPso, aoBlurPso, giTracePso, giVoxPso, giTemporalPso, giBlurPso, ssaoPso;
    bool giHistory = false;
    int giIndex = 0;
    id<MTLComputePipelineState> exposureKernel, waveKernel;
    id<MTLTexture> waveTex;              // water wave height/slope field (wave_texture_kernel), mipmapped
    id<MTLSamplerState> waveSampler;
    bool waveReady = false;
    id<MTLBuffer> exposureState;
    AdvLitContext lit;
    id<MTLTexture> dummyDepth;
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
    // MetalFX upscaling
    int upIndex = 0;
    bool upHistory = false;
    int upMode = 0;
    id<MTLRenderPipelineState> motionPso, depthUpPso[2];   // depth refill: Depth32Float, Depth32Float_Stencil8
    id<MTLRenderPipelineState> guidesPso;                  // the denoiser's guides
    id<MTLDepthStencilState> depthAlwaysWrite;
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
    {
        MTLRenderPipelineDescriptor* sd = [MTLRenderPipelineDescriptor new];
        sd.vertexFunction = fn(@"shadow_water_vertex");
        sd.fragmentFunction = fn(@"shadow_water_fragment");
        sd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        S.shadowWater = pso(sd);
    }
    {
        // coloured shadows: nearest translucent depth (min) and the light passing them all (multiplied)
        MTLRenderPipelineDescriptor* sd = [MTLRenderPipelineDescriptor new];
        sd.vertexFunction = fn(@"shadow_glass_vertex");
        sd.fragmentFunction = fn(@"shadow_glass_fragment");
        sd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        sd.colorAttachments[0].blendingEnabled = YES;
        sd.colorAttachments[0].rgbBlendOperation = sd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationMin;
        sd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
        sd.colorAttachments[1].blendingEnabled = YES;
        sd.colorAttachments[1].sourceRGBBlendFactor = sd.colorAttachments[1].sourceAlphaBlendFactor = MTLBlendFactorDestinationColor;
        sd.colorAttachments[1].destinationRGBBlendFactor = sd.colorAttachments[1].destinationAlphaBlendFactor = MTLBlendFactorZero;
        S.shadowGlass = pso(sd);
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
        ld.fragmentFunction = fn(@"refl_trace_fragment");
        S.reflTracePso = pso(ld);
        ld.fragmentFunction = fn(@"sun_trace_fragment");
        ld.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
        S.sunTracePso = pso(ld);
        ld.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        ld.fragmentFunction = fn(@"blocklight_trace_fragment");
        S.blockTracePso = pso(ld);
        ld.fragmentFunction = fn(@"blockblur_fragment");
        S.blockBlurPso = pso(ld);
        ld.fragmentFunction = fn(@"block_temporal_fragment");
        ld.colorAttachments[1].pixelFormat = MTLPixelFormatRG32Float;   // depth, sample count
        S.blockTemporalPso = pso(ld);
        ld.colorAttachments[1].pixelFormat = MTLPixelFormatInvalid;
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
        id<MTLFunction> k = fn(@"wave_texture_kernel");
        S.waveKernel = k ? [device() newComputePipelineStateWithFunction:k error:&err] : nil;
        if (!S.waveKernel) log("advanced: wave kernel: %s", err ? err.localizedDescription.UTF8String : "missing");
        MTLTextureDescriptor* wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:256 height:256 mipmapped:YES];
        wd.storageMode = MTLStorageModePrivate;
        wd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        S.waveTex = [device() newTextureWithDescriptor:wd];
        S.waveTex.label = @"water waves";
        MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
        sd.maxAnisotropy = 8;
        S.waveSampler = [device() newSamplerStateWithDescriptor:sd];
    }

    {
        NSError* err = nil;
        id<MTLFunction> k = fn(@"exposure_kernel");
        S.exposureKernel = k ? [device() newComputePipelineStateWithFunction:k error:&err] : nil;
        S.exposureState = [device() newBufferWithLength:16 options:MTLResourceStorageModeShared];
        memset(S.exposureState.contents, 0, 16);
    }

    if (rtAvailable()) {
        MTLRenderPipelineDescriptor* ad = [MTLRenderPipelineDescriptor new];
        ad.vertexFunction = fn(@"fullscreen_vertex");
        ad.fragmentFunction = fn(@"rtao_fragment");
        ad.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
        S.rtaoPso = pso(ad);
        ad.fragmentFunction = fn(@"aoblur_fragment");
        S.aoBlurPso = pso(ad);
        MTLRenderPipelineDescriptor* gd = [MTLRenderPipelineDescriptor new];
        gd.vertexFunction = fn(@"fullscreen_vertex");
        gd.fragmentFunction = fn(@"gi_trace_fragment");
        gd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        S.giTracePso = pso(gd);
    }
    {
        // MetalFX upscaling: motion vectors; Minecraft's depth refilled at output resolution
        MTLRenderPipelineDescriptor* md = [MTLRenderPipelineDescriptor new];
        md.vertexFunction = fn(@"fullscreen_vertex");
        md.fragmentFunction = fn(@"motion_fragment");
        md.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
        S.motionPso = pso(md);
        MTLRenderPipelineDescriptor* gd = [MTLRenderPipelineDescriptor new];
        gd.vertexFunction = fn(@"fullscreen_vertex");
        gd.fragmentFunction = fn(@"fx_guides_fragment");
        const MTLPixelFormat gf[5] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float,
                                      MTLPixelFormatR8Unorm, MTLPixelFormatR8Unorm};
        for (int i = 0; i < 5; i++) gd.colorAttachments[i].pixelFormat = gf[i];
        S.guidesPso = pso(gd);
        for (int i = 0; i < 2; i++) {
            MTLRenderPipelineDescriptor* dd = [MTLRenderPipelineDescriptor new];
            dd.vertexFunction = fn(@"fullscreen_vertex");
            dd.fragmentFunction = fn(@"depth_upsample_fragment");
            dd.depthAttachmentPixelFormat = i == 0 ? MTLPixelFormatDepth32Float : MTLPixelFormatDepth32Float_Stencil8;
            if (i == 1) dd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            S.depthUpPso[i] = pso(dd);
        }
        MTLDepthStencilDescriptor* ad = [MTLDepthStencilDescriptor new];
        ad.depthCompareFunction = MTLCompareFunctionAlways;
        ad.depthWriteEnabled = YES;
        S.depthAlwaysWrite = [device() newDepthStencilStateWithDescriptor:ad];
    }
    {
        // GI denoising, and world-space GI (no ray tracing needed)
        MTLRenderPipelineDescriptor* gd = [MTLRenderPipelineDescriptor new];
        gd.vertexFunction = fn(@"fullscreen_vertex");
        gd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        gd.fragmentFunction = fn(@"gi_voxel_fragment");
        S.giVoxPso = pso(gd);
        gd.fragmentFunction = fn(@"giblur_fragment");
        S.giBlurPso = pso(gd);
        gd.fragmentFunction = fn(@"gi_temporal_fragment");
        gd.colorAttachments[1].pixelFormat = MTLPixelFormatRG32Float;   // depth, sample count
        S.giTemporalPso = pso(gd);
    }

    {
        MTLRenderPipelineDescriptor* sd2 = [MTLRenderPipelineDescriptor new];
        sd2.vertexFunction = fn(@"fullscreen_vertex");
        sd2.fragmentFunction = fn(@"ssao_fragment");
        sd2.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
        S.ssaoPso = pso(sd2);
        if (!S.aoBlurPso) {
            sd2.fragmentFunction = fn(@"aoblur_fragment");
            S.aoBlurPso = pso(sd2);
        }
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
    S.t.ao[0] = rt(MTLPixelFormatR16Float, (w + 1) / 2, (h + 1) / 2, @"rtao0");
    S.t.ao[1] = rt(MTLPixelFormatR16Float, (w + 1) / 2, (h + 1) / 2, @"rtao1");
    S.t.giSample = rt(MTLPixelFormatRGBA16Float, (w + 1) / 2, (h + 1) / 2, @"giSample");
    S.t.reflTrace = rt(MTLPixelFormatRGBA16Float, w, h, @"reflTrace");
    S.t.blockRt = rt(MTLPixelFormatRGBA16Float, w, h, @"blockLightRt");
    S.t.sunRt = rt(MTLPixelFormatRG8Unorm, w, h, @"sunRt");
    for (int i = 0; i < 2; i++) {
        S.t.blockHist[i] = rt(MTLPixelFormatRGBA16Float, w, h, @"blockLightHistory");
        S.t.blockZ[i] = rt(MTLPixelFormatRG32Float, w, h, @"blockLightDepth");
        S.t.blockBlur[i] = rt(MTLPixelFormatRGBA16Float, w, h, @"blockLightBlur");
    }
    S.blockHistory = false;
    for (int i = 0; i < 2; i++) {
        S.t.giHist[i] = rt(MTLPixelFormatRGBA16Float, (w + 1) / 2, (h + 1) / 2, @"giHistory");
        S.t.giZ[i] = rt(MTLPixelFormatRG32Float, (w + 1) / 2, (h + 1) / 2, @"giDepth");
        S.t.giBlur[i] = rt(MTLPixelFormatRGBA16Float, (w + 1) / 2, (h + 1) / 2, @"giBlur");
    }
    S.giHistory = false;
    S.historyValid = false;
    S.t.sceneColor = rt(MTLPixelFormatRGBA16Float, w, h, @"sceneColor");
    S.t.sceneDepth = rt(MTLPixelFormatDepth32Float, w, h, @"sceneDepth");
    S.t.renderDepth = rt(MTLPixelFormatDepth32Float, w, h, @"renderDepth");
    S.t.motion = rt(MTLPixelFormatRG16Float, w, h, @"motion");
    for (int i = 0; i < 5; i++) S.t.guide[i] = nil;   // made when the denoiser runs
    S.upHistory = false;
}

// Output-resolution targets: bloom, and the upscaled image when upscaling.
void ensureOutputTargets(int w, int h) {
    if (S.t.ow == w && S.t.oh == h && S.t.up[0]) return;
    S.t.ow = w;
    S.t.oh = h;
    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = upscaleOutputUsage();
        S.t.up[i] = [device() newTextureWithDescriptor:d];
        S.t.up[i].label = @"upscaled";
    }
    S.upHistory = false;
    S.t.bloom.clear();
    int bw = w, bh = h;
    for (int i = 0; i < 6 && bw > 8 && bh > 8; i++) {
        bw = std::max(1, bw / 2);
        bh = std::max(1, bh / 2);
        S.t.bloom.push_back(rt(MTLPixelFormatRGBA16Float, bw, bh, @"bloom"));
    }
}

void ensureWaterShadow(int res) {
    if (S.waterShadow && S.waterShadowRes == res) return;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:res height:res mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    S.waterShadow = [device() newTextureWithDescriptor:d];
    S.waterShadow.label = @"water shadow";
    S.waterShadowRes = res;
}

void ensureGlassShadow(int res) {
    if (S.glassDepth && S.glassRes == res) return;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:res height:res mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    S.glassDepth = [device() newTextureWithDescriptor:d];
    S.glassDepth.label = @"glass shadow depth";
    d.pixelFormat = MTLPixelFormatRGBA8Unorm;
    S.glassColor = [device() newTextureWithDescriptor:d];
    S.glassColor.label = @"glass shadow colour";
    S.glassRes = res;
}

void ensureShadowMap(int res) {
    if (S.shadowMap && S.shadowRes == res) return;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:res height:res mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    S.shadowMap = [device() newTextureWithDescriptor:d];
    S.shadowTerrainMap = [device() newTextureWithDescriptor:d];   // the terrain's part, kept between frames
    S.shadowTerrainMap.label = @"shadow terrain";
    S.shadowRes = res;
    S.shadowCacheValid = false;
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

// The light's basis for a sun direction (shadowMatrix's).
void shadowBasis(simd_float3 sunWorld, simd_float3& right, simd_float3& u, simd_float3& fwd) {
    fwd = -sunWorld;
    simd_float3 up = fabsf(fwd.y) > 0.99f ? simd_make_float3(0, 0, 1) : simd_make_float3(0, 1, 0);
    right = normalize3(simd_cross(up, fwd));
    u = simd_cross(fwd, right);
}

// Orthographic light projection around a fixed light-space centre (absolute world space,
// along the basis: rc, uc, fc), for camera-relative positions: the same world point maps to
// the same texel whatever the camera does, so a rendered map stays valid as the camera moves.
simd_float4x4 shadowMatrixAt(const EnvCmd& env, simd_float3 sunWorld, float radius, double rc, double uc, double fc) {
    simd_float3 right, u, fwd;
    shadowBasis(sunWorld, right, u, fwd);
    double ax = env.camBlockX + (double)env.camFracX, ay = env.camBlockY + (double)env.camFracY, az = env.camBlockZ + (double)env.camFracZ;
    float tr = (float)(ax * right.x + ay * right.y + az * right.z - rc);
    float tu = (float)(ax * u.x + ay * u.y + az * u.z - uc);
    float tf = (float)(ax * fwd.x + ay * fwd.y + az * fwd.z - fc);
    simd_float4x4 view = {{
        {right.x, u.x, fwd.x, 0}, {right.y, u.y, fwd.y, 0}, {right.z, u.z, fwd.z, 0}, {tr, tu, tf, 1}}};
    float depth = 256.0f;
    simd_float4x4 ortho = {{
        {1.0f / radius, 0, 0, 0}, {0, 1.0f / radius, 0, 0}, {0, 0, 0.5f / depth, 0}, {0, 0, 0.5f, 1}}};
    return simd_mul(ortho, view);
}

} // namespace

const AdvLitContext& advancedLitContext() { return S.lit; }

void advancedRender(id<MTLCommandBuffer> cb, const AdvWorld& w, id<MTLTexture> color, id<MTLTexture> outDepth) {
    if (!color || !outDepth || !initState() || !g_materials || !w.hasEnv) return;
    // MetalFX upscaling: the scene renders at a fraction of the output resolution (W x H),
    // MetalFX brings it to the output (OW x OH), and the post-processing runs there
    const int OW = (int)color.width, OH = (int)color.height;
    int upMode = (int)(g_tuning[65] + 0.5f);
    if (upMode != UPSCALE_OFF && !upscaleSupported(upMode)) upMode = UPSCALE_OFF;
    int W = OW, H = OH;
    if (upMode != UPSCALE_OFF) {
        float lo, hi;
        upscaleScaleRange(upMode, lo, hi);
        float ratio = std::clamp(1.0f / std::max(g_tuning[66], 0.01f), std::max(lo, 1.0f), hi);
        W = std::max(64, (int)lroundf(OW / ratio));
        H = std::max(64, (int)lroundf(OH / ratio));
        if (W >= OW && H >= OH && upMode == UPSCALE_SPATIAL) upMode = UPSCALE_OFF;   // nothing to scale
    }
    if (upMode != S.upMode) {
        S.upMode = upMode;
        S.upHistory = false;
        if (upMode == UPSCALE_OFF) upscaleRelease();
    }
    if (upMode == UPSCALE_DENOISED && !S.guidesPso) upMode = UPSCALE_TEMPORAL;
    const bool upscaling = upMode != UPSCALE_OFF, fxDenoised = upMode == UPSCALE_DENOISED,
               fxTemporal = upMode == UPSCALE_TEMPORAL || fxDenoised;   // jittered, MetalFX in TAA's place
    ensureTargets(W, H);
    ensureOutputTargets(OW, OH);
    // the scene's depth: its own at render resolution when upscaling (Minecraft's framebuffer
    // depth is refilled from it at the end, for what vanilla draws after)
    id<MTLTexture> depth = upscaling ? S.t.renderDepth : outDepth;
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
    // user settings (Pipeline.java tune[8]): sun, sky light and block light brightness, block light warmth
    float sunMul = g_tuning[32], skyMul = g_tuning[33], blockMul = g_tuning[34], warmth = g_tuning[35];
    fr.sunColor = simd_make_float4(sunCol * 2.5f * day * (1.0f - rain * 0.85f) * sunMul, 1);
    // vanilla's 8 moon phases (0 full ... 4 new): illuminated fraction and lit side
    static const float kMoonLit[8] = {1.0f, 0.75f, 0.5f, 0.25f, 0.0f, 0.25f, 0.5f, 0.75f};
    int phase = ((env.moonPhase % 8) + 8) % 8;
    fr.moon = simd_make_float4(kMoonLit[phase], phase >= 1 && phase <= 4 ? -1.0f : 1.0f, 0, 0);
    fr.moonColor = simd_make_float4(simd_make_float3(0.13f, 0.16f, 0.25f) * night * (1.0f - rain * 0.7f) *
                                    (0.35f + 0.65f * kMoonLit[phase]) * sunMul, 1);
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
    fr.ambient = simd_make_float4(amb, skyMul);   // .a scales sky light wherever it is applied
    // torch light: neutral white at warmth 0, vanilla-like orange at 1, deeper amber beyond
    simd_float3 neutral = simd_make_float3(1.2f, 1.2f, 1.2f), warm = simd_make_float3(1.7f, 1.02f, 0.51f);
    simd_float3 torch = simd_max(neutral + (warm - neutral) * warmth, simd_make_float3(0.05f, 0.05f, 0.05f)) * blockMul;
    fr.blockLight = simd_make_float4(torch, 2.2f);
    fr.fog = simd_make_float4(w.fogStart, w.fogEnd, rain, (float)env.inFluid);
    fr.fogColor = simd_make_float4(w.fogColor[0], w.fogColor[1], w.fogColor[2], 1);
    float shadowRadius = g_shadowDistance;
    fr.params = simd_make_float4(env.timeSeconds, rain, g_exposure, shadowRadius);
    fr.post = simd_make_float4(g_bloomStrength, 0, (float)env.handLight, 0);
    fr.screen = simd_make_float4(W, H, 1.0f / W, 1.0f / H);
    fr.camera = simd_make_float4(env.camFracX + (float)(env.camBlockX & 1023), env.camFracY + (float)(env.camBlockY & 1023),
                                 env.camFracZ + (float)(env.camBlockZ & 1023), env.starBrightness);
    uint32_t features = g_features;
    if (env.dimension != 0) features &= ~(ADV_SHADOWS | ADV_RT_SHADOW); // no sun in the Nether / End
    double camX = env.camBlockX + (double)env.camFracX, camY = env.camBlockY + (double)env.camFracY,
           camZ = env.camBlockZ + (double)env.camFracZ;
    RtScene rts;
    constexpr uint32_t kRtAll = ADV_RT_SHADOW | ADV_RT_REFL | ADV_RT_AO | ADV_RT_GI | ADV_RT_BLOCK | ADV_RT_SKY;
    bool rtOn = (features & kRtAll) && S.lightPso[1] && S.waterPso[1] &&
                rtPrepare(cb, camX, camY, camZ, std::max(env.renderDistance, 32.0f) + 16.0f, rts);
    if (!rtOn) features &= ~kRtAll;
    if (!S.blockTracePso) features &= ~ADV_RT_BLOCK;
    if (!S.sunTracePso) features &= ~ADV_RT_SHADOW;
    fr.rtCam = simd_make_float4(rts.camera, 0);

    // world-space reflections and GI without ray tracing (and where ray tracing is asked for but
    // unavailable, for GI): keep the voxel volume around the camera current
    VoxelScene vox;
    {
        int giMode = (int)(g_tuning[60] + 0.5f);
        bool wantWsr = (int)(g_tuning[48] + 0.5f) == 2 && !(features & ADV_RT_REFL);
        // (ray-traced sky light traces the GI rays even with GI off or world-space: those then
        // bring back the sky alone)
        bool wantWsgi = (giMode == 1 || giMode == 2) && !(features & ADV_RT_GI) && S.giVoxPso && S.giTemporalPso && S.giBlurPso;
        bool wantLight = g_tuning[64] > 0.5f;
        bool wantLights = (features & ADV_RT_BLOCK) != 0;   // ray-traced block light finds its lights there
        TexEntry* atlasV = (wantWsr || wantWsgi || wantLight || wantLights) ? texture(w.atlasTex) : nullptr;
        if (atlasV && atlasV->tex && voxelsUpdate(cb, camX, camY, camZ, atlasV->tex, wantLight, wantLights, vox)) {
            if (wantWsr) features |= ADV_WSR;
            if (wantWsgi) features |= ADV_WSGI;
            if (vox.light) features |= ADV_COLORED_LIGHT;
            if (!vox.lights) features &= ~ADV_RT_BLOCK;
            fr.voxel = vox.wrap;
            fr.voxCam = vox.cam;
        } else {
            features &= ~ADV_RT_BLOCK;
            if (!wantWsr && !wantWsgi && !wantLight && !wantLights) voxelsRelease();
        }
    }

    // TAA: Halton(2,3) sub-pixel jitter; history is reprojected with the camera motion. MetalFX
    // temporal upscaling takes TAA's place (it anti-aliases as it upscales) and wants more jitter
    // phases the more it upscales
    bool taaOn = (features & ADV_TAA) && S.taaPso && !fxTemporal;
    if (!taaOn && !fxTemporal) features &= ~ADV_TAA;
    float jitterPx[2] = {0, 0};
    bool cameraCut = false;
    {
        auto halton = [](uint32_t i, uint32_t b) {
            float f = 1.0f, r = 0.0f;
            for (; i > 0; i /= b) { f /= (float)b; r += f * (float)(i % b); }
            return r;
        };
        int phases = fxTemporal ? std::clamp((int)lroundf(8.0f * (float)(OW * OH) / (float)(W * H)), 8, 64) : 8;
        uint32_t k = (uint32_t)(S.frame % phases) + 1;
        jitterPx[0] = halton(k, 2) - 0.5f;
        jitterPx[1] = halton(k, 3) - 0.5f;
        if (taaOn || fxTemporal) fr.jitter = simd_make_float4(jitterPx[0] * 2.0f / W, jitterPx[1] * 2.0f / H, 0, 0);
        double dx = camX - S.prevCam[0], dy = camY - S.prevCam[1], dz = camZ - S.prevCam[2];
        bool cut = S.prevDim != env.dimension || fabs(dx) + fabs(dy) + fabs(dz) >= 16.0;
        cameraCut = cut;
        bool valid = (taaOn ? S.historyValid : fxTemporal && S.upHistory) && !cut;
        bool giOn = ((features & ADV_RT_GI) && S.giTracePso && S.giTemporalPso && S.giBlurPso) || (features & ADV_WSGI);
        fr.post.w = giOn && S.giHistory && S.prevDim == env.dimension && fabs(dx) + fabs(dy) + fabs(dz) < 16.0 ? 1.0f : 0.0f;
        S.giHistory = giOn;
        fr.prevViewProj = S.prevViewProj;
        fr.taa = simd_make_float4((float)dx, (float)dy, (float)dz, valid ? 1.0f : 0.0f);
        S.prevViewProj = simd_mul(fr.proj, fr.view);
        S.prevCam[0] = camX; S.prevCam[1] = camY; S.prevCam[2] = camZ;
        S.prevDim = env.dimension;
        S.historyValid = taaOn;
        if (cut) S.upHistory = false;
    }
    // entities (and the first-person player) for ray-traced reflections, AO and GI
    RtEntities ents;
    if (rtOn) {
        std::vector<RtEntityDraw> draws;   // empty: the placeholder structure is bound
        if (g_rtEntities && (features & (ADV_RT_REFL | ADV_RT_AO | ADV_RT_GI))) draws.reserve(w.geometry.size());
        simd_float4x4 rtFromEye = fr.invView;
        rtFromEye.columns[3] += simd_make_float4(rts.camera, 0);
        for (const AdvGeometry& g : w.geometry) {
            if (!g_rtEntities || !(features & (ADV_RT_REFL | ADV_RT_AO | ADV_RT_GI))) break;
            const VertexLayout* L = layout(g.format);
            TexEntry* tex = texture(g.tex);
            if (!L || !tex || !tex->tex || g.prim != 7 || g.count < 4) continue;
            RtEntityDraw d;
            d.vb = g.vb;
            d.offset = g.vbOffset + (size_t)g.firstVertex * L->stride.x;
            d.layout = L;
            d.vertices = g.count & ~3u;
            d.toRt = simd_mul(rtFromEye, g.mv);
            d.texMat = g.texMat;
            d.color = g.item.color;
            d.lightmap = simd_make_float2((float)((int)g.item.lightmap.x & 0xFF) / 240.0f,
                                          (float)((int)g.item.lightmap.y & 0xFF) / 240.0f);
            d.tex = tex->tex;
            d.alphaTest = g.alphaTest;
            d.alphaRef = g.alphaRef;
            d.emissive = g.item.alpha.z;
            draws.push_back(d);
        }
        if (rtBuildEntities(cb, draws, ents) && ents.triangles) features |= ADV_RT_ENTITIES;
    }
    auto bindEntities = [&](id<MTLRenderCommandEncoder> e) {
        if (!ents.as) return;
        [e setFragmentAccelerationStructure:ents.as atBufferIndex:12];
        [e setFragmentBuffer:ents.verts offset:0 atIndex:13];
        [e setFragmentBuffer:ents.draws offset:0 atIndex:14];
        [e setFragmentBuffer:ents.textures offset:0 atIndex:15];
        if (ents.resources && !ents.resources->empty())
            [e useResources:ents.resources->data() count:ents.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    };
    if (env.dimension != 0 || !S.cloudsPso || !S.cloudNoiseKernel) features &= ~ADV_CLOUDS;
    if (!(features & ADV_SHADOWS) || !S.volPso) features &= ~ADV_VOLUMETRIC;
    if (!S.exposureKernel) features &= ~ADV_AUTOEXP;
    TexEntry* pbrN = g_pbrNormal ? texture(g_pbrNormal) : nullptr;
    TexEntry* pbrS = g_pbrSpecular ? texture(g_pbrSpecular) : nullptr;
    if (pbrN && pbrN->tex && pbrS && pbrS->tex && g_tuning[31] > 0.5f) features |= ADV_PBR;   // tune[7].w: PBR enabled
    else features &= ~ADV_PBR;
    bool cloudsOn = (features & ADV_CLOUDS) != 0;
    fr.post.y = cloudsOn && S.cloudHistory && fr.taa.w > 0.5f ? 1.0f : 0.0f; // teleports reset the cloud history too
    if (!taaOn) fr.post.y = cloudsOn && S.cloudHistory ? 1.0f : 0.0f;
    S.cloudHistory = cloudsOn;
    fr.flags = simd_make_uint4(features, (uint32_t)env.dimension, (uint32_t)S.frame, (uint32_t)g_optAdvDebug);
    static_assert(sizeof fr.tune == sizeof g_tuning, "tuning block size");
    memcpy(fr.tune, g_tuning, sizeof fr.tune);
    int shadowRes = g_shadowRes;
    // The terrain's shadows are kept between frames (S.shadowTerrainMap) and drawn again only when
    // what they depend on changes: the sun's direction (beyond a hundredth of a degree), the
    // map's centre (it follows the camera in 8-block steps; the map reaches 8 blocks further),
    // sections (at most 10 times a second) or waving foliage (30 times a second). Entities are
    // drawn over a copy every frame.
    bool shadowRefresh = false;
    bool terrainInMap = !(features & ADV_RT_SHADOW) || (features & ADV_VOLUMETRIC);   // (RT shadows: the map holds entities)
    float shadowMapRadius = shadowRadius + 8.0f;
    if (features & ADV_SHADOWS) {
        ensureShadowMap(shadowRes);
        simd_float3 lightDir = day > 0.001f ? sun : -sun;
        double now = CACurrentMediaTime();
        bool sunMoved = !S.shadowCacheValid || simd_dot(lightDir, S.shadowSun) < 0.99999998f;
        simd_float3 sunUsed = sunMoved ? lightDir : S.shadowSun;
        simd_float3 right, u, fwd;
        shadowBasis(sunUsed, right, u, fwd);
        double ax = env.camBlockX + (double)env.camFracX, ay = env.camBlockY + (double)env.camFracY, az = env.camBlockZ + (double)env.camFracZ;
        double pr = ax * right.x + ay * right.y + az * right.z, pu = ax * u.x + ay * u.y + az * u.z, pf = ax * fwd.x + ay * fwd.y + az * fwd.z;
        double texel = 2.0 * shadowMapRadius / shadowRes;
        double step = std::max(texel, std::round(8.0 / texel) * texel);   // whole texels, so shadows do not shimmer
        bool recentre = sunMoved || fabs(pr - S.shadowRc) > step || fabs(pu - S.shadowUc) > step || fabs(pf - S.shadowFc) > 8.0;
        uint64_t gen = sectionsGeneration();
        shadowRefresh = recentre || S.shadowCacheRadius != shadowMapRadius || S.shadowTerrainIn != terrainInMap ||
                        (gen != S.shadowGen && now - S.shadowAt >= 0.1) || (g_waving && terrainInMap && now - S.shadowAt >= 1.0 / 30.0) ||
                        S.shadowWaving != g_waving;
        if (shadowRefresh) {
            if (recentre) {
                S.shadowRc = std::floor(pr / step) * step;
                S.shadowUc = std::floor(pu / step) * step;
                S.shadowFc = std::floor(pf / 8.0) * 8.0;
            }
            S.shadowSun = sunUsed;
            S.shadowCacheRadius = shadowMapRadius;
            S.shadowGen = gen;
            S.shadowAt = now;
            S.shadowWaving = g_waving;
            S.shadowTerrainIn = terrainInMap;
            S.shadowCacheValid = true;
        }
        fr.shadowViewProj = shadowMatrixAt(env, S.shadowSun, shadowMapRadius, S.shadowRc, S.shadowUc, S.shadowFc);
    } else {
        S.shadowCacheValid = false;
    }

    // ---- shadow pass ----
    if (features & ADV_SHADOWS) {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = shadowRefresh ? S.shadowTerrainMap : S.shadowMap;
        rp.depthAttachment.loadAction = shadowRefresh ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.depthAttachment.clearDepth = 1.0;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (!shadowRefresh) {
            // the kept terrain shadows, for this frame's entities to be drawn over
            id<MTLBlitCommandEncoder> bc = [cb blitCommandEncoder];
            bc.label = @"shadow terrain copy";
            [bc copyFromTexture:S.shadowTerrainMap toTexture:S.shadowMap];
            [bc endEncoding];
        }
        profRender(rp, "shadow");
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = shadowRefresh ? @"shadow terrain" : @"shadow";
        [e setDepthStencilState:S.depthWrite];
        [e setCullMode:MTLCullModeNone];
        [e setDepthBias:1.0f slopeScale:1.5f clamp:0.01f];
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        // Every loaded section near the camera casts shadows, not just the visible ones
        // (with ray-traced shadows the map only holds dynamic geometry).
        // Sections are culled against the shadow map's box itself (its footprint stretches
        // along the sun's path at low sun angles), with a 1-block margin for waving foliage.
        const simd_float4x4& SM = fr.shadowViewProj;
        auto outsideShadowBox = [&](float tx, float ty, float tz) {
            float cx = tx + 8, cy = ty + 8, cz = tz + 8;
            for (int r = 0; r < 3; r++) {
                float cc = SM.columns[0][r] * cx + SM.columns[1][r] * cy + SM.columns[2][r] * cz + SM.columns[3][r];
                float ex = 9.0f * (fabsf(SM.columns[0][r]) + fabsf(SM.columns[1][r]) + fabsf(SM.columns[2][r]));
                if (r < 2 ? fabsf(cc) - ex > 1.0f : (cc - ex > 1.0f || cc + ex < 0.0f)) return true;
            }
            return false;
        };
        float cullReach = shadowMapRadius * 4.0f + 32.0f;   // bounds the box footprint even near the horizon
        for (int layer = 0; layer < (terrainInMap && shadowRefresh ? 3 : 0); layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.shadowTerrain[(alpha ? 1 : 0) | (g_waving ? 2 : 0)]];
            const uint32_t* sp = w.layerSampler[layer];
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            for (const auto& kv : allSections()) {
                const Section* s = &kv.second;
                if (!s->layers[layer]) continue;
                float tx = (float)(s->ox - camX), ty = (float)(s->oy - camY), tz = (float)(s->oz - camZ);
                if (fabsf(tx + 8) > cullReach || fabsf(tz + 8) > cullReach) continue;   // cheap reject first
                if (outsideShadowBox(tx, ty, tz)) continue;
                simd_float4 off = simd_make_float4(tx, ty, tz, 0);
                [e setVertexBytes:&off length:sizeof off atIndex:4];
                [e setVertexBuffer:s->layers[layer] offset:0 atIndex:0];
                uint32_t quads = s->vertices[layer] / 4;
                [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                             indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
        }
        if (shadowRefresh) {
            // the terrain is kept; this frame's entities go over a copy
            [e endEncoding];
            id<MTLBlitCommandEncoder> bc = [cb blitCommandEncoder];
            bc.label = @"shadow terrain copy";
            [bc copyFromTexture:S.shadowTerrainMap toTexture:S.shadowMap];
            [bc endEncoding];
            MTLRenderPassDescriptor* ep = [MTLRenderPassDescriptor renderPassDescriptor];
            ep.depthAttachment.texture = S.shadowMap;
            ep.depthAttachment.loadAction = MTLLoadActionLoad;
            ep.depthAttachment.storeAction = MTLStoreActionStore;
            e = [cb renderCommandEncoderWithDescriptor:ep];
            e.label = @"shadow";
            [e setDepthStencilState:S.depthWrite];
            [e setCullMode:MTLCullModeNone];
            [e setDepthBias:1.0f slopeScale:1.5f clamp:0.01f];
            [e setVertexBytes:&fr length:sizeof fr atIndex:1];
            [e setVertexBuffer:g_materials offset:0 atIndex:5];
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

        // ---- water shadow map: how deep under water (along the light) everything is ----
        if ((features & ADV_WATER) && S.shadowWater) {
            ensureWaterShadow(std::max(512, shadowRes / 2));
            MTLRenderPassDescriptor* wp = [MTLRenderPassDescriptor renderPassDescriptor];
            wp.depthAttachment.texture = S.waterShadow;
            wp.depthAttachment.loadAction = MTLLoadActionClear;
            wp.depthAttachment.clearDepth = 1.0;
            wp.depthAttachment.storeAction = MTLStoreActionStore;
            profRender(wp, "water shadow");
            id<MTLRenderCommandEncoder> we = [cb renderCommandEncoderWithDescriptor:wp];
            we.label = @"water shadow";
            [we setRenderPipelineState:S.shadowWater];
            [we setDepthStencilState:S.depthWrite];
            [we setCullMode:MTLCullModeNone];
            [we setVertexBytes:&fr length:sizeof fr atIndex:1];
            [we setVertexBuffer:g_materials offset:0 atIndex:5];
            for (const auto& kv : allSections()) {
                const Section* s = &kv.second;
                if (!s->layers[3]) continue;
                float tx = (float)(s->ox - camX), ty = (float)(s->oy - camY), tz = (float)(s->oz - camZ);
                if (fabsf(tx + 8) > cullReach || fabsf(tz + 8) > cullReach) continue;
                if (outsideShadowBox(tx, ty, tz)) continue;
                simd_float4 off = simd_make_float4(tx, ty, tz, 0);
                [we setVertexBytes:&off length:sizeof off atIndex:4];
                [we setVertexBuffer:s->layers[3] offset:0 atIndex:0];
                uint32_t quads = s->vertices[3] / 4;
                [we drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                              indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
            [we endEncoding];
            features |= ADV_WATER_SHADOW;
            fr.flags.x = features;
        }

        // ---- glass shadow map: stained glass and other tinted translucents colour the light
        // (only sections that have any: chunk builds report them) ----
        TexEntry* atlasG = texture(w.atlasTex);
        bool anyTinted = false;
        if (g_tuning[63] > 0.5f && S.shadowGlass && atlasG && atlasG->tex) {
            for (const auto& kv : allSections()) {
                const Section* s = &kv.second;
                if (!s->tinted || !s->layers[3]) continue;
                float tx = (float)(s->ox - camX), ty = (float)(s->oy - camY), tz = (float)(s->oz - camZ);
                if (fabsf(tx + 8) > cullReach || fabsf(tz + 8) > cullReach || outsideShadowBox(tx, ty, tz)) continue;
                anyTinted = true;
                break;
            }
        }
        if (anyTinted) {
            ensureGlassShadow(std::max(512, shadowRes / 2));
            MTLRenderPassDescriptor* gp = [MTLRenderPassDescriptor renderPassDescriptor];
            gp.colorAttachments[0].texture = S.glassDepth;
            gp.colorAttachments[0].loadAction = MTLLoadActionClear;
            gp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
            gp.colorAttachments[0].storeAction = MTLStoreActionStore;
            gp.colorAttachments[1].texture = S.glassColor;
            gp.colorAttachments[1].loadAction = MTLLoadActionClear;
            gp.colorAttachments[1].clearColor = MTLClearColorMake(1, 1, 1, 1);
            gp.colorAttachments[1].storeAction = MTLStoreActionStore;
            profRender(gp, "glass shadow");
            id<MTLRenderCommandEncoder> ge = [cb renderCommandEncoderWithDescriptor:gp];
            ge.label = @"glass shadow";
            [ge setRenderPipelineState:S.shadowGlass];
            [ge setCullMode:MTLCullModeNone];
            [ge setVertexBytes:&fr length:sizeof fr atIndex:1];
            [ge setVertexBuffer:g_materials offset:0 atIndex:5];
            [ge setFragmentTexture:atlasG->tex atIndex:0];
            [ge setFragmentSamplerState:S.pointClamp atIndex:0];
            for (const auto& kv : allSections()) {
                const Section* s = &kv.second;
                if (!s->tinted || !s->layers[3]) continue;
                float tx = (float)(s->ox - camX), ty = (float)(s->oy - camY), tz = (float)(s->oz - camZ);
                if (fabsf(tx + 8) > cullReach || fabsf(tz + 8) > cullReach) continue;
                if (outsideShadowBox(tx, ty, tz)) continue;
                simd_float4 off = simd_make_float4(tx, ty, tz, 0);
                [ge setVertexBytes:&off length:sizeof off atIndex:4];
                [ge setVertexBuffer:s->layers[3] offset:0 atIndex:0];
                uint32_t quads = s->vertices[3] / 4;
                [ge drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                              indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
            [ge endEncoding];
            features |= ADV_GLASS_SHADOW;
            fr.flags.x = features;
        }
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
        // the eye in the space the section offsets are in
        simd_float4 eyeH = simd_mul(simd_inverse(w.view), simd_make_float4(0, 0, 0, 1));
        simd_float3 eyeOff = simd_make_float3(eyeH.x / eyeH.w, eyeH.y / eyeH.w, eyeH.z / eyeH.w);
        uint32_t qiQuads = 0;
        for (int layer = 0; layer < 3; layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.gTerrain[(alpha ? 1 : 0) | (g_waving ? 2 : 0)]];
            const uint32_t* sp = w.layerSampler[layer];
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            // back faces are culled: only the runs of face groups that can face the camera are
            // drawn (sections store solid quads by facing, resources.h). Waving leaves tilt a
            // little, so their layers keep a wider margin
            const float eps = (alpha && g_waving) ? 0.25f : 1e-3f;
            id<MTLBuffer> qi = nil;
            for (const AdvTerrainEntry& t : w.terrain[layer]) {
                Section* s = section((int)t.section);
                if (!s || !s->layers[layer]) continue;
                uint32_t quads = s->vertices[layer] / 4;
                if (!qi || quads > qiQuads) { qi = quadIndices(std::max(quads, qiQuads)); qiQuads = std::max(quads, qiQuads); }
                float mv[16];
                sectionMatrix(w.view, t.x, t.y, t.z, mv);
                [e setVertexBytes:mv length:sizeof mv atIndex:3];
                simd_float4 off = simd_make_float4(t.x, t.y, t.z, 0);
                [e setVertexBytes:&off length:sizeof off atIndex:4];
                [e setVertexBuffer:s->layers[layer] offset:0 atIndex:0];
                const uint32_t* gs = s->groupStart[layer];
                const float* pl = s->plane[layer];
                float cx = eyeOff.x - t.x, cy = eyeOff.y - t.y, cz = eyeOff.z - t.z;
                bool vis[FG_COUNT] = {
                    cy < pl[FG_NY] + eps, cx < pl[FG_NX] + eps, cz < pl[FG_NZ] + eps, cy > pl[FG_PY] - eps,
                    true, cz > pl[FG_PZ] - eps, cx > pl[FG_PX] - eps,
                };
                uint32_t runStart = 0, runEnd = 0;
                bool open = false;
                auto draw = [&](uint32_t a, uint32_t b) {
                    if (b > a)
                        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(b - a) * 6 indexType:MTLIndexTypeUInt32
                                     indexBuffer:qi indexBufferOffset:(NSUInteger)a * 24];
                };
                for (int gi = 0; gi < FG_COUNT; gi++) {
                    uint32_t a = gs[gi], b = gs[gi + 1];
                    if (a == b) continue;
                    if (vis[gi]) {
                        if (!open) { runStart = a; open = true; }
                        runEnd = b;
                    } else if (open) {
                        draw(runStart, runEnd);
                        open = false;
                    }
                }
                if (open) draw(runStart, runEnd);
            }
        }
        // captured opaque geometry (entities, block entities)
        for (const AdvGeometry& g : w.geometry) {
            const VertexLayout* L = layout(g.format);
            TexEntry* tex = texture(g.tex);
            if (!L || !tex || !tex->tex || g.prim != 7 || g.shadowOnly) continue;
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

    // ---- ambient occlusion: ray-traced, else screen-space (half resolution) + bilateral blur ----
    if (features & ADV_RT_AO) features &= ~ADV_SSAO;
    if (!S.ssaoPso || !S.aoBlurPso) features &= ~ADV_SSAO;
    fr.flags.x = features;
    if ((features & (ADV_RT_AO | ADV_SSAO)) && S.aoBlurPso) {
        TexEntry* atlasE = texture(w.atlasTex);
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.ao[0];
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        bool rtAo = (features & ADV_RT_AO) != 0;
        profRender(rp, rtAo ? "rtao" : "ssao", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = rtAo ? @"rtao" : @"ssao";
        [e setRenderPipelineState:rtAo ? S.rtaoPso : S.ssaoPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:depth atIndex:0];
        [e setFragmentTexture:S.t.linZ atIndex:1];
        [e setFragmentTexture:S.t.normal atIndex:2];
        if (rtAo) {
            [e setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [e setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [e setFragmentTexture:atlasE && atlasE->tex ? atlasE->tex : S.t.albedo atIndex:7];
            [e setFragmentSamplerState:S.pointClamp atIndex:2];
            if (rts.resources)
                [e useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            bindEntities(e);
        }
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        for (int pass = 0; pass < 2; pass++) {
            MTLRenderPassDescriptor* bp = [MTLRenderPassDescriptor renderPassDescriptor];
            bp.colorAttachments[0].texture = S.t.ao[pass ^ 1];
            bp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            bp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(bp, "ao blur", true);
            id<MTLRenderCommandEncoder> b = [cb renderCommandEncoderWithDescriptor:bp];
            b.label = @"ao blur";
            [b setRenderPipelineState:S.aoBlurPso];
            [b setFragmentBytes:&fr length:sizeof fr atIndex:1];
            simd_float4 step = pass == 0 ? simd_make_float4(1, 0, 0, 0) : simd_make_float4(0, 1, 0, 0);
            [b setFragmentBytes:&step length:sizeof step atIndex:0];
            [b setFragmentTexture:S.t.ao[pass] atIndex:0];
            [b setFragmentTexture:S.t.linZ atIndex:1];
            [b setFragmentTexture:S.t.normal atIndex:2];
            [b drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [b endEncoding];
        }
    }

    // ---- global illumination (one bounce, half resolution, denoised): ray traced, or
    // world-space through the voxel volume ----
    bool rtGi = (features & ADV_RT_GI) && S.giTracePso && S.giTemporalPso && S.giBlurPso;
    if (rtGi || (features & ADV_WSGI)) {
        TexEntry* atlasE = texture(w.atlasTex);
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.giSample;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        profRender(rp, "gi trace", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"gi trace";
        [e setRenderPipelineState:rtGi ? S.giTracePso : S.giVoxPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:depth atIndex:0];
        [e setFragmentTexture:S.t.linZ atIndex:1];
        [e setFragmentTexture:S.t.normal atIndex:2];
        [e setFragmentTexture:S.skyLut atIndex:5];
        [e setFragmentTexture:atlasE && atlasE->tex ? atlasE->tex : S.t.albedo atIndex:7];
        [e setFragmentSamplerState:S.linearClamp atIndex:1];
        if (rtGi) {
            [e setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [e setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [e setFragmentBuffer:g_emissions offset:0 atIndex:6];
            [e setFragmentSamplerState:S.pointClamp atIndex:2];
            if (rts.resources)
                [e useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            bindEntities(e);
        } else {
            [e setFragmentTexture:S.t.light atIndex:3];
            [e setFragmentTexture:(features & ADV_SHADOWS) ? S.shadowMap : depth atIndex:4];
            [e setFragmentSamplerState:S.shadowCmp atIndex:0];
            [e setFragmentTexture:vox.tex atIndex:16];
            [e setFragmentTexture:vox.occ atIndex:18];
            [e setFragmentTexture:vox.shape atIndex:19];
            [e setFragmentTexture:vox.occSlot atIndex:20];
            [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassDepth : S.t.linZ atIndex:21];
            [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassColor : S.t.linZ atIndex:22];
            if (vox.light) [e setFragmentTexture:vox.light atIndex:23];
        }
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        // temporal accumulation into the history ring
        int cur = S.giIndex, prev = S.giIndex ^ 1;
        S.giIndex ^= 1;
        MTLRenderPassDescriptor* tp = [MTLRenderPassDescriptor renderPassDescriptor];
        tp.colorAttachments[0].texture = S.t.giHist[cur];
        tp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        tp.colorAttachments[0].storeAction = MTLStoreActionStore;
        tp.colorAttachments[1].texture = S.t.giZ[cur];
        tp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
        tp.colorAttachments[1].storeAction = MTLStoreActionStore;
        profRender(tp, "gi temporal", true);
        e = [cb renderCommandEncoderWithDescriptor:tp];
        e.label = @"gi temporal";
        [e setRenderPipelineState:S.giTemporalPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.t.giSample atIndex:0];
        [e setFragmentTexture:S.t.giHist[prev] atIndex:1];
        [e setFragmentTexture:S.t.giZ[prev] atIndex:2];
        [e setFragmentTexture:S.t.linZ atIndex:3];
        [e setFragmentTexture:depth atIndex:4];
        [e setFragmentSamplerState:S.linearClamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        // spatial: horizontal then vertical edge-aware blur
        for (int pass = 0; pass < 2; pass++) {
            MTLRenderPassDescriptor* bp = [MTLRenderPassDescriptor renderPassDescriptor];
            bp.colorAttachments[0].texture = S.t.giBlur[pass];
            bp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            bp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(bp, "gi blur", true);
            id<MTLRenderCommandEncoder> b = [cb renderCommandEncoderWithDescriptor:bp];
            b.label = @"gi blur";
            [b setRenderPipelineState:S.giBlurPso];
            [b setFragmentBytes:&fr length:sizeof fr atIndex:1];
            simd_float4 step = pass == 0 ? simd_make_float4(1, 0, 0, 0) : simd_make_float4(0, 1, 0, 0);
            [b setFragmentBytes:&step length:sizeof step atIndex:0];
            [b setFragmentTexture:pass == 0 ? S.t.giHist[cur] : S.t.giBlur[0] atIndex:0];
            [b setFragmentTexture:S.t.linZ atIndex:1];
            [b setFragmentTexture:S.t.normal atIndex:2];
            [b drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [b endEncoding];
        }
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
        // ray-traced reflections first, in their own pass (see refl_trace_fragment)
        bool rtRefl = (features & ADV_RT_REFL) && S.reflTracePso;
        if (!rtRefl) features &= ~ADV_RT_REFL;
        fr.flags.x = features;
        if (rtRefl) {
            MTLRenderPassDescriptor* tp = [MTLRenderPassDescriptor renderPassDescriptor];
            tp.colorAttachments[0].texture = S.t.reflTrace;
            tp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            tp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(tp, "reflections", true);
            id<MTLRenderCommandEncoder> te = [cb renderCommandEncoderWithDescriptor:tp];
            te.label = @"reflections";
            [te setRenderPipelineState:S.reflTracePso];
            [te setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [te setFragmentTexture:S.t.albedo atIndex:0];
            [te setFragmentTexture:S.t.normal atIndex:1];
            [te setFragmentTexture:S.t.light atIndex:2];
            [te setFragmentTexture:depth atIndex:3];
            [te setFragmentTexture:S.skyLut atIndex:5];
            [te setFragmentTexture:S.t.linZ atIndex:6];
            [te setFragmentTexture:S.cloudNoise atIndex:9];
            [te setFragmentTexture:S.t.spec atIndex:10];
            [te setFragmentSamplerState:S.linearClamp atIndex:1];
            [te setFragmentSamplerState:S.repeatLinear atIndex:3];
            TexEntry* atlasR = texture(w.atlasTex);
            [te setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [te setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [te setFragmentTexture:atlasR && atlasR->tex ? atlasR->tex : S.t.albedo atIndex:7];
            [te setFragmentSamplerState:S.pointClamp atIndex:2];
            if (rts.resources)
                [te useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            bindEntities(te);
            [te drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [te endEncoding];
        }
        // the lighting pass's rays (sun shadows, the held light), in their own pass too
        if (features & ADV_RT_SHADOW) {
            MTLRenderPassDescriptor* tp = [MTLRenderPassDescriptor renderPassDescriptor];
            tp.colorAttachments[0].texture = S.t.sunRt;
            tp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            tp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(tp, "sun shadow rays", true);
            id<MTLRenderCommandEncoder> te = [cb renderCommandEncoderWithDescriptor:tp];
            te.label = @"sun shadow rays";
            [te setRenderPipelineState:S.sunTracePso];
            [te setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [te setFragmentTexture:depth atIndex:0];
            [te setFragmentTexture:S.t.linZ atIndex:1];
            [te setFragmentTexture:S.t.normal atIndex:2];
            [te setFragmentTexture:S.t.light atIndex:3];
            TexEntry* atlasS = texture(w.atlasTex);
            [te setFragmentTexture:atlasS && atlasS->tex ? atlasS->tex : S.t.albedo atIndex:7];
            [te setFragmentSamplerState:S.pointClamp atIndex:2];
            [te setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [te setFragmentBuffer:rts.instances offset:0 atIndex:11];
            if (rts.resources)
                [te useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            [te drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [te endEncoding];
        }
        // ray-traced block light, also in its own pass
        bool rtBlock = (features & ADV_RT_BLOCK) && vox.lights && vox.lightGrid && vox.props && S.blockTemporalPso && S.blockBlurPso;
        if (rtBlock) {
            MTLRenderPassDescriptor* tp = [MTLRenderPassDescriptor renderPassDescriptor];
            tp.colorAttachments[0].texture = S.t.blockRt;
            tp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            tp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(tp, "block light", true);
            id<MTLRenderCommandEncoder> te = [cb renderCommandEncoderWithDescriptor:tp];
            te.label = @"block light";
            [te setRenderPipelineState:S.blockTracePso];
            [te setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [te setFragmentTexture:depth atIndex:0];
            [te setFragmentTexture:S.t.linZ atIndex:1];
            [te setFragmentTexture:S.t.normal atIndex:2];
            TexEntry* atlasB = texture(w.atlasTex);
            [te setFragmentTexture:atlasB && atlasB->tex ? atlasB->tex : S.t.albedo atIndex:7];
            [te setFragmentSamplerState:S.pointClamp atIndex:2];
            [te setFragmentAccelerationStructure:rts.tlas atBufferIndex:10];
            [te setFragmentBuffer:rts.instances offset:0 atIndex:11];
            [te setFragmentBuffer:vox.lights offset:0 atIndex:16];
            [te setFragmentBuffer:vox.lightGrid offset:0 atIndex:17];
            [te setFragmentTexture:vox.props atIndex:3];
            if (rts.resources)
                [te useResources:rts.resources->data() count:rts.resources->size() usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            bindEntities(te);
            [te drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [te endEncoding];
            // accumulated over frames, then an edge-aware blur
            int cur = S.blockIndex, prev = S.blockIndex ^ 1;
            S.blockIndex ^= 1;
            // frames of history: fewer while the held light (it moves with the player) is lit
            float valid = S.blockHistory && !cameraCut ? (fr.post.z > 0.5f ? 6.0f : 24.0f) : 0.0f;
            S.blockHistory = true;
            MTLRenderPassDescriptor* hp = [MTLRenderPassDescriptor renderPassDescriptor];
            hp.colorAttachments[0].texture = S.t.blockHist[cur];
            hp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            hp.colorAttachments[0].storeAction = MTLStoreActionStore;
            hp.colorAttachments[1].texture = S.t.blockZ[cur];
            hp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
            hp.colorAttachments[1].storeAction = MTLStoreActionStore;
            profRender(hp, "block light temporal", true);
            te = [cb renderCommandEncoderWithDescriptor:hp];
            te.label = @"block light temporal";
            [te setRenderPipelineState:S.blockTemporalPso];
            [te setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [te setFragmentBytes:&valid length:sizeof valid atIndex:0];
            [te setFragmentTexture:S.t.blockRt atIndex:0];
            [te setFragmentTexture:S.t.blockHist[prev] atIndex:1];
            [te setFragmentTexture:S.t.blockZ[prev] atIndex:2];
            [te setFragmentTexture:S.t.linZ atIndex:3];
            [te setFragmentTexture:depth atIndex:4];
            [te setFragmentSamplerState:S.linearClamp atIndex:0];
            [te drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [te endEncoding];
            for (int pass = 0; pass < 2; pass++) {
                MTLRenderPassDescriptor* bp = [MTLRenderPassDescriptor renderPassDescriptor];
                bp.colorAttachments[0].texture = S.t.blockBlur[pass];
                bp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                bp.colorAttachments[0].storeAction = MTLStoreActionStore;
                profRender(bp, "block light blur", true);
                id<MTLRenderCommandEncoder> b = [cb renderCommandEncoderWithDescriptor:bp];
                b.label = @"block light blur";
                [b setRenderPipelineState:S.blockBlurPso];
                [b setFragmentBytes:&fr length:sizeof fr atIndex:1];
                simd_float4 step = pass == 0 ? simd_make_float4(1, 0, 1.5f, 0) : simd_make_float4(0, 1, 1.5f, 0);
                [b setFragmentBytes:&step length:sizeof step atIndex:0];
                [b setFragmentTexture:pass == 0 ? S.t.blockHist[cur] : S.t.blockBlur[0] atIndex:0];
                [b setFragmentTexture:S.t.linZ atIndex:1];
                [b setFragmentTexture:S.t.normal atIndex:2];
                [b drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [b endEncoding];
            }
        } else {
            S.blockHistory = false;
            features &= ~ADV_RT_BLOCK;
            fr.flags.x = features;
        }
        profRender(rp, "lighting", true);
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"lighting";
        [e setFragmentTexture:rtBlock ? S.t.blockBlur[1] : S.t.light atIndex:25];
        [e setFragmentTexture:(features & ADV_RT_SHADOW) ? S.t.sunRt : S.t.light atIndex:26];
        [e setFragmentTexture:rtRefl ? S.t.reflTrace : S.t.light atIndex:24];
        [e setRenderPipelineState:S.lightPso[0]];   // its rays are traced in the passes before
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
        [e setFragmentTexture:fxTemporal ? S.t.up[S.upIndex ^ 1] : taaOn ? S.t.taa[S.taaIndex ^ 1] : S.t.hdr atIndex:11];
        [e setFragmentTexture:(features & (ADV_RT_AO | ADV_SSAO)) ? S.t.ao[0] : S.t.light atIndex:12];
        [e setFragmentTexture:(features & (ADV_RT_GI | ADV_WSGI)) ? S.t.giBlur[1] : S.t.light atIndex:13];
        [e setFragmentTexture:(features & ADV_WATER_SHADOW) ? S.waterShadow : depth atIndex:14];
        [e setFragmentTexture:S.waveTex atIndex:15];
        if (vox.valid) {
            [e setFragmentTexture:vox.tex atIndex:16];
            [e setFragmentTexture:vox.occ atIndex:18];
            [e setFragmentTexture:vox.shape atIndex:19];
            [e setFragmentTexture:vox.occSlot atIndex:20];
        }
        {
            // debug view 10: world-space reflection steps per ray, logged every 120 frames
            static id<MTLBuffer> stats = [device() newBufferWithLength:16 options:MTLResourceStorageModeShared];
            if (g_optAdvDebug == 10 && S.frame % 120 == 0) {
                uint32_t* st = (uint32_t*)stats.contents;
                if (st[1]) log("world-space reflections: %.1f steps per ray, %u rays per frame", (double)st[0] / st[1], st[1] / 120);
                st[0] = st[1] = 0;
            }
            [e setFragmentBuffer:stats offset:0 atIndex:21];
        }
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassDepth : S.t.linZ atIndex:21];
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassColor : S.t.linZ atIndex:22];
        if (vox.light) [e setFragmentTexture:vox.light atIndex:23];
        {
            TexEntry* atlasL = texture(w.atlasTex);
            [e setFragmentTexture:atlasL && atlasL->tex ? atlasL->tex : S.t.albedo atIndex:17];
        }
        [e setFragmentSamplerState:S.repeatLinear atIndex:3];
        [e setFragmentSamplerState:S.waveSampler atIndex:4];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }

    // ---- translucent terrain (water, glass, ice) ----
    if (!w.terrain[3].empty() && !S.waveReady && S.waveKernel) {
        id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
        c.label = @"water waves";
        [c setComputePipelineState:S.waveKernel];
        [c setTexture:S.waveTex atIndex:0];
        [c dispatchThreads:MTLSizeMake(256, 256, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [c endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b generateMipmapsForTexture:S.waveTex];
        [b endEncoding];
        S.waveReady = true;
    }
    if (!w.terrain[3].empty()) {
        // refraction and screen-space reflections read the opaque scene from copies
        MTLBlitPassDescriptor* bp = [MTLBlitPassDescriptor blitPassDescriptor];
        profBlit(bp, "scene copy");
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoderWithDescriptor:bp];
        b.label = @"scene copy";
        [b copyFromTexture:S.t.hdr toTexture:S.t.sceneColor];
        // the copy matches the world's depth format (depth + stencil when a mod enabled
        // Minecraft's framebuffer stencil), so it is never silently skipped
        if (S.t.sceneDepth.pixelFormat != depth.pixelFormat || S.t.sceneDepth.width != depth.width ||
            S.t.sceneDepth.height != depth.height)
            S.t.sceneDepth = rt(depth.pixelFormat, (int)depth.width, (int)depth.height, @"sceneDepth");
        [b copyFromTexture:depth toTexture:S.t.sceneDepth];
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
            bindEntities(e);
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
        [e setFragmentTexture:S.waveTex atIndex:9];
        [e setFragmentSamplerState:S.waveSampler atIndex:4];
        [e setFragmentTexture:S.t.light atIndex:10];
        if (vox.valid) {
            [e setFragmentTexture:vox.tex atIndex:11];
            [e setFragmentTexture:vox.occ atIndex:12];
            [e setFragmentTexture:vox.shape atIndex:13];
            [e setFragmentTexture:vox.occSlot atIndex:14];
        }
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassDepth : S.t.linZ atIndex:15];
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassColor : S.t.linZ atIndex:16];
        if (vox.light) [e setFragmentTexture:vox.light atIndex:17];
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
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassDepth : S.t.linZ atIndex:4];
        [e setFragmentTexture:(features & ADV_GLASS_SHADOW) ? S.glassColor : S.t.linZ atIndex:5];
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

    // ---- MetalFX upscaling to the output resolution: spatial (after TAA), or temporal (in
    // TAA's place: it anti-aliases the jittered scene as it upscales) ----
    if (upscaling) {
        UpscaleFrame uf;
        uf.mode = upMode;
        uf.inW = W; uf.inH = H; uf.outW = OW; uf.outH = OH;
        uf.output = S.t.up[S.upIndex];
        uf.color = post;
        if (fxTemporal && S.motionPso) {
            MTLRenderPassDescriptor* mp = [MTLRenderPassDescriptor renderPassDescriptor];
            mp.colorAttachments[0].texture = S.t.motion;
            mp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            mp.colorAttachments[0].storeAction = MTLStoreActionStore;
            profRender(mp, "motion vectors", true);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:mp];
            e.label = @"motion vectors";
            [e setRenderPipelineState:S.motionPso];
            [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [e setFragmentTexture:depth atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            uf.depth = depth;
            uf.motion = S.t.motion;
            uf.jitterX = -jitterPx[0];
            uf.jitterY = -jitterPx[1];
            uf.reset = !S.upHistory || fr.taa.w < 0.5f;
        }
        if (fxDenoised && S.guidesPso) {
            // what the denoiser needs to know about each pixel's surface
            const MTLPixelFormat gf[5] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float,
                                          MTLPixelFormatR8Unorm, MTLPixelFormatR8Unorm};
            NSString* const names[5] = {@"guide diffuse", @"guide specular", @"guide normal", @"guide roughness", @"guide mask"};
            MTLRenderPassDescriptor* gp = [MTLRenderPassDescriptor renderPassDescriptor];
            for (int i = 0; i < 5; i++) {
                if (!S.t.guide[i]) S.t.guide[i] = rt(gf[i], W, H, names[i]);
                gp.colorAttachments[i].texture = S.t.guide[i];
                gp.colorAttachments[i].loadAction = MTLLoadActionDontCare;
                gp.colorAttachments[i].storeAction = MTLStoreActionStore;
            }
            profRender(gp, "denoiser guides", true);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:gp];
            e.label = @"denoiser guides";
            [e setRenderPipelineState:S.guidesPso];
            [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
            [e setFragmentTexture:S.t.albedo atIndex:0];
            [e setFragmentTexture:S.t.normal atIndex:1];
            [e setFragmentTexture:S.t.light atIndex:2];
            [e setFragmentTexture:depth atIndex:3];
            [e setFragmentTexture:S.t.linZ atIndex:6];
            // the opaque scene's depth: copied before translucent terrain drew (when there was any)
            [e setFragmentTexture:w.terrain[3].empty() ? depth : S.t.sceneDepth atIndex:7];
            [e setFragmentTexture:S.cloudNoise atIndex:9];
            [e setFragmentTexture:S.t.spec atIndex:10];
            [e setFragmentSamplerState:S.repeatLinear atIndex:3];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            uf.diffuse = S.t.guide[0];
            uf.specular = S.t.guide[1];
            uf.normal = S.t.guide[2];
            uf.roughness = S.t.guide[3];
            uf.mask = S.t.guide[4];
            uf.worldToView = fr.view;
            uf.viewToClip = fr.proj;
        }
        if (upscaleEncode(cb, uf)) {
            post = S.t.up[S.upIndex];
            S.upIndex ^= 1;
            S.upHistory = true;
        }
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
            e.label = @"bloom down";
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
            e.label = @"bloom up";
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
        // remember this frame's lighting for the replayed hand/particle/weather draws (drawn
        // at the output resolution, unjittered)
        S.lit.valid = true;
        S.lit.frame = fr;
        S.lit.frame.screen = simd_make_float4(OW, OH, 1.0f / OW, 1.0f / OH);
        S.lit.frame.jitter = simd_make_float4(0, 0, 0, 0);
        if (!S.dummyDepth) {
            MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:1 height:1 mipmapped:NO];
            dd.storageMode = MTLStorageModePrivate;
            dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            S.dummyDepth = [device() newTextureWithDescriptor:dd];
        }
        S.lit.shadowMap = (features & ADV_SHADOWS) && S.shadowMap ? S.shadowMap : S.dummyDepth;
        S.lit.skyLut = S.skyLut;
        S.lit.exposure = S.exposureState;
        S.lit.shadowCmp = S.shadowCmp;
        S.lit.linear = S.linearClamp;
    }

    // ---- Minecraft's depth at output resolution, from the scene's (upscaling) ----
    if (upscaling) {
        bool stencil = outDepth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
        id<MTLRenderPipelineState> p = S.depthUpPso[stencil ? 1 : 0];
        if (p && (stencil || outDepth.pixelFormat == MTLPixelFormatDepth32Float)) {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = outDepth;
            rp.depthAttachment.loadAction = MTLLoadActionDontCare;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            if (stencil) {
                rp.stencilAttachment.texture = outDepth;
                rp.stencilAttachment.loadAction = MTLLoadActionClear;
                rp.stencilAttachment.clearStencil = 0;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
            }
            profRender(rp, "depth refill", true);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            e.label = @"depth refill";
            [e setRenderPipelineState:p];
            [e setDepthStencilState:S.depthAlwaysWrite];
            [e setFragmentTexture:depth atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
        }
    }

    // ---- frame interpolation: the world as finished (image, depth and camera motion at output
    // resolution), for MetalFX to generate the frame shown before this one (interp.mm) ----
    InterpCapture cap;
    if (S.motionPso && S.depthUpPso[0] && interpBeginCapture(OW, OH, color.pixelFormat, cap)) {
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        b.label = @"interp world";
        [b copyFromTexture:color toTexture:cap.world];
        [b endEncoding];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = cap.depth;
        rp.depthAttachment.loadAction = MTLLoadActionDontCare;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"interp depth";
        [e setRenderPipelineState:S.depthUpPso[0]];
        [e setDepthStencilState:S.depthAlwaysWrite];
        [e setFragmentTexture:depth atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        MTLRenderPassDescriptor* mp = [MTLRenderPassDescriptor renderPassDescriptor];
        mp.colorAttachments[0].texture = cap.motion;
        mp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        mp.colorAttachments[0].storeAction = MTLStoreActionStore;
        e = [cb renderCommandEncoderWithDescriptor:mp];
        e.label = @"interp motion";
        [e setRenderPipelineState:S.motionPso];
        AdvFrame mf = S.lit.frame;   // unjittered, at the screen's size
        mf.screen = simd_make_float4(cap.screenW, cap.screenH, 1.0f / cap.screenW, 1.0f / cap.screenH);
        [e setFragmentBytes:&mf length:sizeof mf atIndex:1];
        [e setFragmentTexture:cap.depth atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        interpCaptured(fr.proj, fr.view, cameraCut);
    }
}

} // namespace m189
