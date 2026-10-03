// metal189: advanced (deferred PBR) world renderer.
//
// Pass order: shadow map -> G-buffer (terrain + captured opaque geometry, into
// Minecraft's own depth buffer) -> deferred lighting + sky (HDR) -> forward
// water/translucent terrain -> bloom -> tonemap into Minecraft's framebuffer.
// Everything not consumed here (particles, weather, hand, outlines...) is then
// replayed by the baseline executor on top.

#import "advanced.h"
#import "resources.h"
#include <cmath>

namespace m189 {

extern int g_optQuadDiagonal;

static bool g_enabled = false;
static uint32_t g_features = ADV_SHADOWS | ADV_BLOOM | ADV_SKY | ADV_WATER;
static id<MTLBuffer> g_materials, g_emissions;

bool advancedEnabled() { return g_enabled; }
void advancedSetEnabled(bool on) { g_enabled = on; }
void advancedSetFeatures(uint32_t f) { g_features = f; }

void advancedSetTables(const uint8_t* materials, const uint8_t* emissions) {
    g_materials = [device() newBufferWithBytes:materials length:65536 options:MTLResourceStorageModeShared];
    g_emissions = [device() newBufferWithBytes:emissions length:65536 options:MTLResourceStorageModeShared];
}

namespace {

struct Targets {
    int w = 0, h = 0;
    id<MTLTexture> albedo, normal, light, hdr;
    std::vector<id<MTLTexture>> bloom;
};

struct State {
    bool init = false;
    id<MTLRenderPipelineState> gTerrain[4], gGeneric[2], shadowTerrain[2], shadowGeneric[2];
    id<MTLRenderPipelineState> lightPso, waterPso, tonemapPso, bloomDown, bloomUp;
    id<MTLDepthStencilState> depthWrite, depthTestNoWrite, depthAlways;
    id<MTLSamplerState> shadowCmp, linearClamp;
    id<MTLTexture> shadowMap;
    int shadowRes = 0;
    Targets t;
    id<MTLBuffer> quadIdx;
    uint32_t quadIdxQuads = 0;
    uint64_t frame = 0;
};
State S;

id<MTLFunction> fn(NSString* name, bool alpha = false, bool waving = false) {
    MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
    [cv setConstantValue:&alpha type:MTLDataTypeBool atIndex:10];
    [cv setConstantValue:&waving type:MTLDataTypeBool atIndex:11];
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
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    return d;
}

bool initState() {
    if (S.init) return true;
    for (int i = 0; i < 4; i++) {
        bool alpha = i & 1, waving = (i >> 1) & 1;
        S.gTerrain[i] = pso(gbufDesc(fn(@"gbuf_terrain_vertex", alpha, waving), fn(@"gbuf_terrain_fragment", alpha, waving)));
    }
    for (int i = 0; i < 2; i++) {
        S.gGeneric[i] = pso(gbufDesc(fn(@"gbuf_generic_vertex", i), fn(@"gbuf_generic_fragment", i)));
        MTLRenderPipelineDescriptor* sd = [MTLRenderPipelineDescriptor new];
        sd.vertexFunction = fn(@"shadow_terrain_vertex", i, true);
        sd.fragmentFunction = fn(@"shadow_fragment", i);
        sd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        S.shadowTerrain[i] = pso(sd);
        sd.vertexFunction = fn(@"shadow_generic_vertex", i);
        S.shadowGeneric[i] = pso(sd);
    }
    MTLRenderPipelineDescriptor* ld = [MTLRenderPipelineDescriptor new];
    ld.vertexFunction = fn(@"fullscreen_vertex");
    ld.fragmentFunction = fn(@"light_fragment");
    ld.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    S.lightPso = pso(ld);

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
    S.waterPso = pso(wd);

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
    S.init = S.lightPso && S.tonemapPso && S.gTerrain[0];
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
    S.t.hdr = rt(MTLPixelFormatRGBA16Float, w, h, @"hdr");
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
    float warm = std::clamp(sunH / 0.35f, 0.0f, 1.0f);
    simd_float3 sunCol = simd_mix(simd_make_float3(1.0f, 0.42f, 0.18f), simd_make_float3(1.0f, 0.95f, 0.88f), simd_make_float3(warm, warm, warm));
    fr.sunColor = simd_make_float4(sunCol * 3.2f * day * (1.0f - rain * 0.85f), 1);
    fr.moonColor = simd_make_float4(simd_make_float3(0.10f, 0.13f, 0.20f) * night * (1.0f - rain * 0.7f), 1);
    auto lin = [](float c) { return powf(std::max(c, 0.0f), 2.2f); };
    simd_float3 skyV = simd_make_float3(lin(env.skyR), lin(env.skyG), lin(env.skyB));
    simd_float3 fogV = simd_make_float3(lin(w.fogColor[0]), lin(w.fogColor[1]), lin(w.fogColor[2]));
    fr.skyZenith = simd_make_float4(skyV * 1.1f, 1);
    fr.skyHorizon = simd_make_float4(simd_mix(skyV, fogV, simd_make_float3(0.7f, 0.7f, 0.7f)) * 1.2f, 1);
    simd_float3 amb = skyV * 0.9f + fogV * 0.3f + simd_make_float3(0.01f, 0.012f, 0.02f) * night;
    fr.ambient = simd_make_float4(amb, 1);
    fr.blockLight = simd_make_float4(1.0f * 2.0f, 0.62f * 2.0f, 0.32f * 2.0f, 2.6f);
    fr.fog = simd_make_float4(w.fogStart, w.fogEnd, rain, (float)env.inFluid);
    fr.fogColor = simd_make_float4(w.fogColor[0], w.fogColor[1], w.fogColor[2], 1);
    float shadowRadius = 112.0f;
    fr.params = simd_make_float4(env.timeSeconds, rain, 1.15f, shadowRadius);
    fr.screen = simd_make_float4(W, H, 1.0f / W, 1.0f / H);
    fr.camera = simd_make_float4(env.camFracX + (float)(env.camBlockX & 1023), env.camFracY, env.camFracZ + (float)(env.camBlockZ & 1023), 0);
    uint32_t features = g_features;
    if (env.dimension != 0) features &= ~ADV_SHADOWS; // no sun in the Nether / End
    fr.flags = simd_make_uint4(features, (uint32_t)env.dimension, (uint32_t)S.frame, 0);
    int shadowRes = 4096;
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
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"shadow";
        [e setDepthStencilState:S.depthWrite];
        [e setCullMode:MTLCullModeNone];
        [e setDepthBias:1.0f slopeScale:1.5f clamp:0.01f];
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        for (int layer = 0; layer < 3; layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.shadowTerrain[alpha ? 1 : 0]];
            const uint32_t* sp = w.layerSampler[layer];
            [e setFragmentSamplerState:samplerFor((int)sp[0], (int)sp[1], (int)sp[2], (int)sp[3], (int)sp[4],
                                                  *(const float*)&sp[5], *(const float*)&sp[6], *(const float*)&sp[7]) atIndex:0];
            for (const AdvTerrainEntry& t : w.terrain[layer]) {
                Section* s = section((int)t.section);
                if (!s || !s->layers[layer]) continue;
                simd_float4 off = simd_make_float4(t.x, t.y, t.z, 0);
                [e setVertexBytes:&off length:sizeof off atIndex:4];
                [e setVertexBuffer:s->layers[layer] offset:0 atIndex:0];
                uint32_t quads = s->vertices[layer] / 4;
                [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:quads * 6 indexType:MTLIndexTypeUInt32
                             indexBuffer:quadIndices(quads) indexBufferOffset:0];
            }
        }
        [e endEncoding];
    }

    // ---- G-buffer ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLTexture> att[3] = {S.t.albedo, S.t.normal, S.t.light};
        for (int i = 0; i < 3; i++) {
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
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"gbuffer";
        [e setDepthStencilState:S.depthWrite];
        [e setCullMode:MTLCullModeBack];
        [e setFrontFacingWinding:MTLWindingClockwise]; // GL CCW, flipped target
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        [e setVertexBuffer:g_emissions offset:0 atIndex:6];
        TexEntry* atlas = texture(w.atlasTex);
        if (atlas && atlas->tex) [e setFragmentTexture:atlas->tex atIndex:0];
        for (int layer = 0; layer < 3; layer++) {
            bool alpha = layer > 0;
            [e setRenderPipelineState:S.gTerrain[(alpha ? 1 : 0) | 2]];
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

    // ---- lighting + sky -> HDR ----
    {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = S.t.hdr;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"lighting";
        [e setRenderPipelineState:S.lightPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.t.albedo atIndex:0];
        [e setFragmentTexture:S.t.normal atIndex:1];
        [e setFragmentTexture:S.t.light atIndex:2];
        [e setFragmentTexture:depth atIndex:3];
        [e setFragmentTexture:(features & ADV_SHADOWS) ? S.shadowMap : depth atIndex:4];
        [e setFragmentSamplerState:S.shadowCmp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }

    // ---- translucent terrain (water, glass, ice) ----
    if (!w.terrain[3].empty()) {
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
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"translucent";
        [e setRenderPipelineState:S.waterPso];
        [e setDepthStencilState:S.depthTestNoWrite];
        [e setCullMode:MTLCullModeBack];
        [e setFrontFacingWinding:MTLWindingClockwise];
        [e setVertexBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setVertexBuffer:g_materials offset:0 atIndex:5];
        [e setFragmentTexture:(features & ADV_SHADOWS) ? S.shadowMap : depth atIndex:4];
        [e setFragmentSamplerState:S.shadowCmp atIndex:1];
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

    // ---- bloom ----
    if ((features & ADV_BLOOM) && !S.t.bloom.empty()) {
        id<MTLTexture> src = S.t.hdr;
        for (size_t i = 0; i < S.t.bloom.size(); i++) {
            id<MTLTexture> dst = S.t.bloom[i];
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = dst;
            rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
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
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:S.bloomUp];
            simd_float4 p = simd_make_float4(0, 0, 1.0f / s.width, 1.0f / s.height);
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
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        e.label = @"tonemap";
        [e setRenderPipelineState:S.tonemapPso];
        [e setFragmentBytes:&fr length:sizeof fr atIndex:1];
        [e setFragmentTexture:S.t.hdr atIndex:0];
        [e setFragmentTexture:S.t.bloom.empty() ? S.t.hdr : S.t.bloom[0] atIndex:1];
        [e setFragmentSamplerState:S.linearClamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }
}

} // namespace m189
