// metal189 advanced pipeline: G-buffer, shadows, deferred PBR lighting, sky,
// water and post-processing.
#include "common.h"
#include "adv.h"

constant bool ac_alphaTest [[function_constant(10)]];
constant bool ac_waving    [[function_constant(11)]];

// ---------------------------------------------------------------------------
// shared helpers

struct BlockVertex {
    packed_float3 pos;
    uchar4 color;
    packed_float2 uv;
    packed_short2 lm;
};

static inline float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
static inline float3 toGamma(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

static inline float4 metalClip(float4 glClip) {
    // offscreen targets keep GL row order: flip Y, map z to [0,1]
    float4 c = glClip;
    c.y = -c.y;
    c.z = 0.5 * (c.z + c.w);
    return c;
}

// Directional shading baked into vanilla quad colours (FaceBakery): undo it for
// axis-aligned faces so lighting is not applied twice.
static inline float faceShade(float3 nWorld) {
    float3 a = abs(nWorld);
    if (a.y > 0.999) return nWorld.y > 0 ? 1.0 : 0.5;
    if (a.z > 0.999) return 0.8;
    if (a.x > 0.999) return 0.6;
    return 1.0;
}

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Material ids (see Materials.java): 0 default, 1 foliage, 2 water, 3 emissive, 4 metal, 5 glass, 6 lava, 7 entity
struct GBufferOut {
    float4 albedo [[color(0)]];   // rgb: albedo (gamma), a: baked AO
    float4 normal [[color(1)]];   // xyz: eye-space normal, w: emission
    float4 light  [[color(2)]];   // x: block light, y: sky light, z: material/255, w: roughness
};

// ---------------------------------------------------------------------------
// terrain G-buffer

struct GTerrainOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 lm;
    float3 normalView [[flat]];
    float shade [[flat]];
    uint material [[flat]];
    float emission [[flat]];
};

static float3 quadNormal(device const BlockVertex* verts, uint vid) {
    uint b = vid & ~3u;
    float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos);
    float3 n = cross(p1 - p0, p2 - p0);
    float l = length(n);
    return l > 1e-12 ? n / l : float3(0, 1, 0);
}

// Waving foliage, applied identically in G-buffer and shadow passes.
static float3 wave(float3 local, float3 sectionWorld, float time, uint material, bool top) {
    if (!ac_waving || material != 1) return local;
    float3 w = local + sectionWorld;
    float s = sin(time * 1.6 + w.x * 0.7 + w.z * 0.9) * 0.04 + sin(time * 2.7 + w.x * 1.3 - w.z * 0.6) * 0.025;
    return local + float3(s, 0, s * 0.7) * (top ? 1.0 : 0.35);
}

vertex GTerrainOut gbuf_terrain_vertex(uint vid [[vertex_id]],
                                       device const BlockVertex* verts [[buffer(0)]],
                                       constant AdvFrame& fr [[buffer(1)]],
                                       constant float4x4& sectionMV [[buffer(3)]],
                                       constant float4& sectionWorld [[buffer(4)]],
                                       device const uchar* materials [[buffer(5)]],
                                       device const uchar* emissions [[buffer(6)]]) {
    BlockVertex v = verts[vid];
    ushort2 lmRaw = ushort2(v.lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    uint mat = materials[state];
    float3 local = wave(float3(v.pos), sectionWorld.xyz, fr.params.x, mat, fract(float3(v.pos).y) < 0.01 && v.uv.y < 0.5);
    float4 eye = sectionMV * float4(local, 1.0);
    GTerrainOut o;
    o.position = metalClip(fr.proj * eye);
    o.uv = float2(v.uv);
    o.color = float4(v.color) * (1.0 / 255.0);
    o.lm = float2(lmRaw & ushort2(0xFF)) * (1.0 / 240.0);
    float3 nLocal = quadNormal(verts, vid);
    o.normalView = normalize((sectionMV * float4(nLocal, 0)).xyz);
    o.shade = faceShade(nLocal);
    o.material = mat;
    o.emission = float(emissions[state]) * (1.0 / 255.0);
    return o;
}

fragment GBufferOut gbuf_terrain_fragment(GTerrainOut in [[stage_in]], bool front [[front_facing]],
                                          texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = atlas.sample(s, in.uv);
    if (ac_alphaTest && t.a * in.color.a < 0.1) discard_fragment();
    GBufferOut o;
    float3 c = t.rgb * in.color.rgb / in.shade;
    // vanilla AO is baked into the vertex colour; keep its luminance as an AO term
    float ao = saturate(dot(in.color.rgb / in.shade, float3(0.333)) / max(dot(c / max(t.rgb, 1e-3), float3(0.333)), 1e-3));
    o.albedo = float4(saturate(c), ao);
    float3 n = front ? in.normalView : -in.normalView;
    float emission = in.emission * smoothstep(0.35, 0.9, dot(t.rgb, float3(0.299, 0.587, 0.114)));
    o.normal = float4(n, emission);
    float rough = in.material == 4 ? 0.3 : in.material == 2 ? 0.05 : 0.85;
    o.light = float4(in.lm.x, in.lm.y, float(in.material) / 255.0, rough);
    return o;
}

// ---------------------------------------------------------------------------
// generic captured geometry (entities, block entities, hand) G-buffer

static float readComponent(device const uchar* p, int type, int i) {
    switch (type) {
        case 0x1406: return ((device const float*)p)[i];
        case 0x1401: return float(p[i]);
        case 0x1400: return float(((device const char*)p)[i]);
        case 0x1402: return float(((device const short*)p)[i]);
        case 0x1403: return float(((device const ushort*)p)[i]);
        default: return 0.0;
    }
}

static float4 fetch(device const uchar* v, int4 a, float4 def) {
    if (a.x < 0) return def;
    device const uchar* p = v + a.x;
    float s = a.w != 0 ? (a.y == 0x1401 ? 1.0 / 255.0 : a.y == 0x1400 ? 1.0 / 127.0 : 1.0) : 1.0;
    float4 r = def;
    r.x = readComponent(p, a.y, 0) * s;
    if (a.z > 1) r.y = readComponent(p, a.y, 1) * s;
    if (a.z > 2) r.z = readComponent(p, a.y, 2) * s;
    if (a.z > 3) r.w = readComponent(p, a.y, 3) * s;
    return r;
}

struct GGenericOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 lm;
    float3 normalView;
};

vertex GGenericOut gbuf_generic_vertex(uint vid [[vertex_id]],
                                       device const uchar* vbuf [[buffer(0)]],
                                       constant AdvFrame& fr [[buffer(1)]],
                                       constant VertexLayout& layout [[buffer(2)]],
                                       constant DrawTransform& xf [[buffer(3)]],
                                       constant AdvItem& item [[buffer(4)]],
                                       constant float4x4& texMat [[buffer(5)]]) {
    device const uchar* v = vbuf + vid * layout.stride.x;
    float4 pos = fetch(v, layout.pos, float4(0, 0, 0, 1));
    float4 eye = xf.modelview * pos;
    GGenericOut o;
    o.position = metalClip(fr.proj * eye);
    float4 t0 = fetch(v, layout.tex0, float4(0, 0, 0, 1));
    o.uv = (texMat * t0).xy;
    o.color = fetch(v, layout.color, item.color);
    float4 lm = fetch(v, layout.tex1, float4(item.lightmap.xy, 0, 1));
    o.lm = float2(ushort2(int2(lm.xy)) & ushort2(0xFF)) * (1.0 / 240.0);
    float3 n = fetch(v, layout.normal, float4(item.normal.xyz, 0)).xyz;
    float3 nv = float3x3(xf.normal0.xyz, xf.normal1.xyz, xf.normal2.xyz) * n;
    float l = length(nv);
    o.normalView = l > 1e-6 ? nv / l : float3(0, 0, 1);
    return o;
}

fragment GBufferOut gbuf_generic_fragment(GGenericOut in [[stage_in]], bool front [[front_facing]],
                                          constant AdvItem& item [[buffer(4)]],
                                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = tex.sample(s, in.uv);
    float a = t.a * in.color.a;
    if (ac_alphaTest && a <= item.alpha.x) discard_fragment();
    GBufferOut o;
    o.albedo = float4(saturate(t.rgb * in.color.rgb), 1.0);
    float3 n = front ? in.normalView : -in.normalView;
    o.normal = float4(n, item.alpha.z);
    o.light = float4(in.lm.x, in.lm.y, item.alpha.w / 255.0, 0.7);
    return o;
}

// ---------------------------------------------------------------------------
// shadow map

struct ShadowOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
};

vertex ShadowOut shadow_terrain_vertex(uint vid [[vertex_id]],
                                       device const BlockVertex* verts [[buffer(0)]],
                                       constant AdvFrame& fr [[buffer(1)]],
                                       constant float4& sectionWorld [[buffer(4)]],
                                       device const uchar* materials [[buffer(5)]]) {
    BlockVertex v = verts[vid];
    ushort2 lmRaw = ushort2(v.lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    uint mat = materials[state];
    float3 local = wave(float3(v.pos), sectionWorld.xyz, fr.params.x, mat, fract(float3(v.pos).y) < 0.01 && v.uv.y < 0.5);
    // sectionWorld.xyz: section origin relative to the camera; w unused
    float3 world = local + sectionWorld.xyz;
    ShadowOut o;
    o.position = fr.shadowViewProj * float4(world, 1.0);
    o.uv = float2(v.uv);
    o.alpha = float(v.color.a) / 255.0;
    return o;
}

vertex ShadowOut shadow_generic_vertex(uint vid [[vertex_id]],
                                       device const uchar* vbuf [[buffer(0)]],
                                       constant AdvFrame& fr [[buffer(1)]],
                                       constant VertexLayout& layout [[buffer(2)]],
                                       constant DrawTransform& xf [[buffer(3)]],
                                       constant AdvItem& item [[buffer(4)]],
                                       constant float4x4& texMat [[buffer(5)]]) {
    device const uchar* v = vbuf + vid * layout.stride.x;
    float4 pos = fetch(v, layout.pos, float4(0, 0, 0, 1));
    float4 eye = xf.modelview * pos;
    float4 world = fr.invView * eye;
    ShadowOut o;
    o.position = fr.shadowViewProj * float4(world.xyz, 1.0);
    o.uv = (texMat * fetch(v, layout.tex0, float4(0, 0, 0, 1))).xy;
    o.alpha = fetch(v, layout.color, item.color).a;
    return o;
}

fragment void shadow_fragment(ShadowOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    if (ac_alphaTest && tex.sample(s, in.uv).a * in.alpha < 0.1) discard_fragment();
}

// ---------------------------------------------------------------------------
// deferred lighting + sky

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Eye-space position from a depth sample of a GL-ordered target.
static float3 eyeFromDepth(constant AdvFrame& fr, float2 fragCoord, float depth) {
    float2 ndc = float2(fragCoord.x * fr.screen.z * 2.0 - 1.0, fragCoord.y * fr.screen.w * 2.0 - 1.0);
    float4 p = fr.invProj * float4(ndc, depth * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

static float3 skyRadiance(constant AdvFrame& fr, float3 dirWorld) {
    float up = dirWorld.y;
    float h = pow(saturate(1.0 - max(up, 0.0)), 3.0);
    float3 base = mix(fr.skyZenith.rgb, fr.skyHorizon.rgb, h);
    if (up < 0.0) base = mix(base, fr.skyHorizon.rgb * 0.6, saturate(-up * 4.0));
    float mu = dot(dirWorld, fr.sunDirWorld.xyz);
    // sun disc + Mie-style glow
    float disc = smoothstep(0.9993, 0.9997, mu) * fr.sunDirWorld.w;
    float glow = pow(saturate(mu), 12.0) * 0.6 + pow(saturate(mu), 200.0) * 2.0;
    float3 sun = fr.sunColor.rgb * (disc * 30.0 + glow * fr.sunDirWorld.w * 0.25);
    return base + sun;
}

static float sampleShadow(constant AdvFrame& fr, depth2d<float> shadowMap, sampler cmp, float3 world, float3 nWorld, float ndl) {
    float3 p = world + nWorld * (0.04 + 0.08 * (1.0 - ndl));
    float4 sc = fr.shadowViewProj * float4(p, 1.0);
    float3 ndc = sc.xyz / sc.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0) return 1.0;
    float bias = 0.0004;
    float texel = 1.0 / float(shadowMap.get_width());
    float sum = 0.0;
    // 4x4 PCF with hardware compare
    for (int y = -1; y <= 2; y++)
        for (int x = -1; x <= 2; x++)
            sum += shadowMap.sample_compare(cmp, uv + (float2(x, y) - 0.5) * texel, ndc.z - bias);
    return sum / 16.0;
}

fragment float4 light_fragment(FullscreenOut in [[stage_in]],
                               constant AdvFrame& fr [[buffer(1)]],
                               texture2d<float> gAlbedo [[texture(0)]],
                               texture2d<float> gNormal [[texture(1)]],
                               texture2d<float> gLight [[texture(2)]],
                               depth2d<float> depth [[texture(3)]],
                               depth2d<float> shadowMap [[texture(4)]],
                               sampler cmp [[sampler(0)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    float3 eye = eyeFromDepth(fr, in.position.xy, d);
    float3 dirWorld = normalize((fr.invView * float4(eye, 0)).xyz);
    if (d >= 1.0) return float4(skyRadiance(fr, dirWorld), 1.0);

    float4 alb = gAlbedo.read(px);
    float4 nrm = gNormal.read(px);
    float4 lgt = gLight.read(px);
    float3 albedo = toLinear(alb.rgb);
    float ao = alb.a;
    float3 n = normalize(nrm.xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 v = normalize(-eye);
    uint material = uint(lgt.z * 255.0 + 0.5);
    float skyLight = lgt.y, blockL = lgt.x, rough = lgt.w;

    float3 color = float3(0);
    // sun / moon
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    float wrap = material == 1 ? 0.35 : 0.0; // foliage transmits some light
    float diffuse = saturate((ndl + wrap) / (1.0 + wrap));
    if (diffuse > 0.0) {
        float shadow = 1.0;
        if (fr.flags.x & ADV_SHADOWS) shadow = sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl));
        // light leaking into caves: direct light needs open sky
        float skyGate = smoothstep(0.35, 0.9, skyLight);
        float3 h = normalize(lightDir + v);
        float a2 = max(rough * rough, 0.002);
        a2 *= a2;
        float nh = saturate(dot(n, h));
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float spec = a2 / (3.14159 * dd * dd) * 0.04 * (1.0 - rough);
        color += lightCol * (albedo * diffuse + spec * saturate(ndl)) * shadow * skyGate;
    }
    // sky ambient (hemisphere), vanilla AO, skylight falloff
    float hemi = 0.65 + 0.35 * nWorld.y;
    color += albedo * fr.ambient.rgb * (skyLight * skyLight) * hemi * ao;
    // block light (torches): warm, steep falloff like the vanilla lightmap
    float bl = pow(blockL, fr.blockLight.a);
    color += albedo * fr.blockLight.rgb * bl * ao;
    // emission
    color += albedo * nrm.w * 6.0;
    // minimum light so caves are not pitch black
    color += albedo * 0.004 * ao;

    // distance fog towards the sky
    float dist = length(eye);
    float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
    fogF = fogF * fogF;
    if (fr.fog.w > 0.5) fogF = saturate(dist / 12.0); // underwater/lava
    float3 fogCol = fr.fog.w > 0.5 ? toLinear(fr.fogColor.rgb) : skyRadiance(fr, dirWorld);
    color = mix(color, fogCol, fogF);
    return float4(color, 1.0);
}

// ---------------------------------------------------------------------------
// water and other translucent terrain (forward)

struct WaterOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 lm;
    float3 eye;
    float3 world;
    float3 normalView [[flat]];
    uint material [[flat]];
};

vertex WaterOut water_vertex(uint vid [[vertex_id]],
                             device const BlockVertex* verts [[buffer(0)]],
                             constant AdvFrame& fr [[buffer(1)]],
                             constant float4x4& sectionMV [[buffer(3)]],
                             constant float4& sectionWorld [[buffer(4)]],
                             device const uchar* materials [[buffer(5)]]) {
    BlockVertex v = verts[vid];
    ushort2 lmRaw = ushort2(v.lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    float4 eye = sectionMV * float4(float3(v.pos), 1.0);
    WaterOut o;
    o.position = metalClip(fr.proj * eye);
    o.uv = float2(v.uv);
    o.color = float4(v.color) * (1.0 / 255.0);
    o.lm = float2(lmRaw & ushort2(0xFF)) * (1.0 / 240.0);
    o.eye = eye.xyz;
    o.world = float3(v.pos) + sectionWorld.xyz;
    o.normalView = normalize((sectionMV * float4(quadNormal(verts, vid), 0)).xyz);
    o.material = materials[state];
    return o;
}

fragment float4 water_fragment(WaterOut in [[stage_in]], bool front [[front_facing]],
                               constant AdvFrame& fr [[buffer(1)]],
                               texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]],
                               depth2d<float> shadowMap [[texture(4)]], sampler cmp [[sampler(1)]]) {
    float4 t = atlas.sample(s, in.uv);
    float3 albedo = toLinear(t.rgb * in.color.rgb);
    float3 n = front ? in.normalView : -in.normalView;
    float3 v = normalize(-in.eye);
    float3 dirWorld = normalize((fr.invView * float4(-v, 0)).xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float alpha = t.a * in.color.a;
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = saturate(dot(n, lightDir));
    float shadow = (fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, in.world, nWorld, ndl) : 1.0;
    float skyGate = smoothstep(0.35, 0.9, in.lm.y);
    float3 color = albedo * (lightCol * ndl * shadow * skyGate + fr.ambient.rgb * in.lm.y * in.lm.y +
                             fr.blockLight.rgb * pow(in.lm.x, fr.blockLight.a) + 0.004);
    if (in.material == 2) {
        // water: Fresnel sky reflection + sun glint, waves via screen-space noise
        float time = fr.params.x;
        float2 wp = in.world.xz + fr.camera.xz;
        float3 bump = float3(sin(wp.x * 1.7 + time * 1.9) * 0.04 + sin(wp.y * 2.3 - time * 1.3) * 0.03, 0,
                             cos(wp.y * 1.9 + time * 1.6) * 0.04 + cos(wp.x * 2.1 + time * 1.1) * 0.03);
        float3 nw = normalize(nWorld + (abs(nWorld.y) > 0.5 ? bump : float3(0)));
        float3 rd = reflect(dirWorld, nw);
        float cosT = saturate(dot(-dirWorld, nw));
        float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
        float3 refl = skyRadiance(fr, normalize(float3(rd.x, abs(rd.y), rd.z))) * in.lm.y;
        float3 h = normalize(-dirWorld + fr.sunDirWorld.xyz);
        float glint = pow(saturate(dot(nw, h)), 400.0) * 40.0 * shadow * fr.sunDirWorld.w;
        color = mix(color, refl, fres) + fr.sunColor.rgb * glint;
        alpha = mix(max(alpha, 0.55), 1.0, fres);
    }
    float dist = length(in.eye);
    float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
    color = mix(color, skyRadiance(fr, dirWorld), fogF * fogF);
    return float4(color, alpha);
}

// ---------------------------------------------------------------------------
// post: bloom + tonemap

fragment float4 bloom_down_fragment(FullscreenOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                    sampler s [[sampler(0)]], constant float4& p [[buffer(0)]]) {
    // 13-tap downsample (Jimenez 2014); p.x = 1 for the first (thresholded) level
    float2 t = p.zw;
    float2 uv = in.uv;
    float3 a = src.sample(s, uv + t * float2(-2, -2)).rgb, b = src.sample(s, uv + t * float2(0, -2)).rgb,
           c = src.sample(s, uv + t * float2(2, -2)).rgb, d = src.sample(s, uv + t * float2(-2, 0)).rgb,
           e = src.sample(s, uv).rgb, f = src.sample(s, uv + t * float2(2, 0)).rgb,
           g = src.sample(s, uv + t * float2(-2, 2)).rgb, h = src.sample(s, uv + t * float2(0, 2)).rgb,
           i = src.sample(s, uv + t * float2(2, 2)).rgb, j = src.sample(s, uv + t * float2(-1, -1)).rgb,
           k = src.sample(s, uv + t * float2(1, -1)).rgb, l = src.sample(s, uv + t * float2(-1, 1)).rgb,
           m = src.sample(s, uv + t * float2(1, 1)).rgb;
    float3 o = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    if (p.x > 0.5) {
        float lum = dot(o, float3(0.2126, 0.7152, 0.0722));
        o *= saturate((lum - p.y) / max(lum, 1e-4));
    }
    return float4(o, 1.0);
}

fragment float4 bloom_up_fragment(FullscreenOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                  sampler s [[sampler(0)]], constant float4& p [[buffer(0)]]) {
    float2 t = p.zw;
    float2 uv = in.uv;
    float3 o = src.sample(s, uv + t * float2(-1, -1)).rgb + src.sample(s, uv + t * float2(0, -1)).rgb * 2.0 +
               src.sample(s, uv + t * float2(1, -1)).rgb + src.sample(s, uv + t * float2(-1, 0)).rgb * 2.0 +
               src.sample(s, uv).rgb * 4.0 + src.sample(s, uv + t * float2(1, 0)).rgb * 2.0 +
               src.sample(s, uv + t * float2(-1, 1)).rgb + src.sample(s, uv + t * float2(0, 1)).rgb * 2.0 +
               src.sample(s, uv + t * float2(1, 1)).rgb;
    return float4(o / 16.0, 1.0);
}

static float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

fragment float4 tonemap_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                 texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
    uint2 px = uint2(in.position.xy);
    float3 c = hdr.read(px).rgb;
    if (fr.flags.x & ADV_BLOOM) c += bloom.sample(s, in.uv).rgb * 0.06;
    c *= fr.params.z;
    c = aces(c);
    // subtle vignette
    float2 q = in.uv - 0.5;
    c *= 1.0 - dot(q, q) * 0.35;
    return float4(toGamma(c), 1.0);
}
