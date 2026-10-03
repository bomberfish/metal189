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

// ---- physically based atmosphere (single scattering, Rayleigh + Mie) ----
constant float kRe = 6360e3, kRa = 6460e3;
constant float3 kBetaR = float3(5.8e-6, 13.5e-6, 33.1e-6);
constant float kBetaM = 21e-6;

static float2 raySphere(float3 o, float3 d, float r) {
    float b = dot(o, d), c = dot(o, o) - r * r;
    float h = b * b - c;
    if (h < 0.0) return float2(-1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// Optical depth (Rayleigh, Mie) from p towards the light; quadratic sample spacing.
static float2 opticalDepth(float3 p, float3 light) {
    float2 tg = raySphere(p, light, kRe);
    if (tg.x > 0.0) return float2(1e9); // planet shadow
    float tMax = raySphere(p, light, kRa).y;
    const int L = 8;
    float2 od = 0;
    float tPrev = 0;
    for (int j = 0; j < L; j++) {
        float x = (j + 1.0) / L;
        float tNext = tMax * x * x;
        float3 q = p + light * (0.5 * (tPrev + tNext));
        float hq = max(length(q) - kRe, 0.0);
        od += float2(exp(-hq / 8000.0), exp(-hq / 1200.0)) * (tNext - tPrev);
        tPrev = tNext;
    }
    return od;
}

// In-scattered radiance along `dir` for a light of unit irradiance from `light`
// (single scattering, energy-conserving per-segment integration).
static float3 atmosphere(float3 dir, float3 light, float altitude) {
    float3 o = float3(0, kRe + altitude, 0);
    float tMax = raySphere(o, dir, kRa).y;
    float2 tg = raySphere(o, dir, kRe);
    if (tg.x > 0.0) tMax = min(tMax, tg.x);
    if (tMax <= 0.0) return float3(0);
    float mu = dot(dir, light);
    float pR = 3.0 / (16.0 * 3.14159) * (1.0 + mu * mu);
    const float g = 0.76;
    float pM = 3.0 / (8.0 * 3.14159) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    const int N = 24;
    float3 T = 1.0, sum = 0.0;
    float tPrev = 0;
    for (int i = 0; i < N; i++) {
        float x = (i + 1.0) / N;
        float tNext = tMax * x * x;
        float ds = tNext - tPrev;
        float3 p = o + dir * (0.5 * (tPrev + tNext));
        tPrev = tNext;
        float h = max(length(p) - kRe, 0.0);
        float dR = exp(-h / 8000.0), dM = exp(-h / 1200.0);
        float3 sigT = kBetaR * dR + kBetaM * 1.1 * dM;
        float2 od = opticalDepth(p, light);
        float3 Tl = exp(-(kBetaR * od.x + kBetaM * 1.1 * od.y));
        float3 S = (kBetaR * dR * pR + kBetaM * dM * pM) * Tl;
        float3 Ts = exp(-sigT * ds);
        sum += T * (S - S * Ts) / max(sigT, float3(1e-12));
        T *= Ts;
    }
    return sum;
}

// Sky-view LUT: x = azimuth, y = elevation (denser near the horizon).
static float3 lutDir(float2 uv) {
    float az = uv.x * 2.0 * 3.14159265;
    float v = uv.y * 2.0 - 1.0;
    float el = sign(v) * v * v * 1.5707963;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}

static float2 lutUv(float3 d) {
    float el = asin(clamp(d.y, -1.0, 1.0));
    float v = sign(el) * sqrt(abs(el) / 1.5707963);
    float az = atan2(d.z, d.x);
    if (az < 0.0) az += 2.0 * 3.14159265;
    return float2(az / (2.0 * 3.14159265), v * 0.5 + 0.5);
}

fragment float4 skylut_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]]) {
    float3 d = lutDir(in.uv);
    float3 c = atmosphere(d, fr.sunDirWorld.xyz, 120.0) * 22.0 * fr.sunDirWorld.w;
    // moon lights the night sky with a cold, dim scattering term
    c += atmosphere(d, -fr.sunDirWorld.xyz, 120.0) * 0.06 * float3(0.75, 0.85, 1.25) * (1.0 - fr.sunDirWorld.w);
    // rain: overcast, greyer and darker sky
    float rain = fr.params.y;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(c, float3(lum) * 0.55, rain * 0.85);
    return float4(c, 1.0);
}

static float3 starField(float3 d, float brightness) {
    if (brightness <= 0.001 || d.y < 0.0) return float3(0);
    float3 p = d * 300.0;
    float3 cell = floor(p);
    float h = hash12(cell.xz + cell.y * 17.13);
    float star = step(0.9965, h) * smoothstep(0.75, 0.0, length(fract(p) - 0.5));
    return float3(star * brightness * 2.0);
}

// Atmosphere only (no sun/moon discs or stars), used for fog and aerial perspective.
static float3 skyBase(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 d) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb); // Nether / End: no atmosphere
    // below the horizon: the horizon colour, darkening towards the ground
    float3 c = skyLut.sample(s, lutUv(normalize(float3(d.x, max(d.y, 0.004), d.z))), level(0)).rgb;
    return c * mix(1.0, 0.55, saturate(-d.y * 3.0));
}

// Radiance of the near-field haze for an infinitely long path: the sky's average light
// (azimuth quadrant of the upper hemisphere) plus bounded sun/moon forward-scattering lobes.
// The full-path sky radiance near the sun is far too bright for a few hundred metres of air.
static float hg(float mu, float g) { return (1.0 - g * g) / (4.0 * 3.14159 * pow(1.0 + g * g - 2.0 * g * mu, 1.5)); }

static float3 hazeColor(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 d) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb);
    float3 amb = skyLut.sample(s, float2(lutUv(float3(d.x, 0.0, d.z) + 1e-4).x, 0.75), level(6)).rgb;
    float mu = dot(d, fr.sunDirWorld.xyz);
    float sunVis = smoothstep(-0.05, 0.1, fr.sunDirWorld.y);
    return amb + (fr.sunColor.rgb * hg(mu, 0.6) * sunVis + fr.moonColor.rgb * hg(-mu, 0.6)) * 0.35;
}

static float3 skyRadiance(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 dirWorld) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb);
    float3 d = dirWorld;
    float3 base = skyBase(fr, skyLut, s, d);
    float mu = dot(d, fr.sunDirWorld.xyz);
    float disc = smoothstep(0.99955, 0.9998, mu) * fr.sunDirWorld.w;
    float moon = smoothstep(0.99935, 0.9996, -mu) * (1.0 - fr.sunDirWorld.w);
    float3 c = base + fr.sunColor.rgb * disc * 60.0 + float3(0.8, 0.85, 1.0) * moon * 1.5;
    c += starField(d, fr.camera.w * (1.0 - fr.params.y));
    return c;
}

// Irradiance-ish ambient from the blurred sky LUT (top mips), for normal n.
static float3 skyAmbient(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 nWorld) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb) * 0.3;
    float lod = 5.0;
    float3 up = skyLut.sample(s, lutUv(float3(0, 1, 0)), level(lod)).rgb;
    float3 hor = skyLut.sample(s, lutUv(normalize(float3(nWorld.x, 0.15, nWorld.z) + 1e-4)), level(lod)).rgb;
    float t = saturate(nWorld.y * 0.5 + 0.5);
    return mix(hor * 0.6, mix(hor, up, 0.6), t) * 1.6;
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
                               texture2d<float> skyLut [[texture(5)]],
                               sampler cmp [[sampler(0)]], sampler lin [[sampler(1)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    float3 eye = eyeFromDepth(fr, in.position.xy, d);
    float3 dirWorld = normalize((fr.invView * float4(eye, 0)).xyz);
    if (d >= 1.0) {
        float3 sky = skyRadiance(fr, skyLut, lin, dirWorld);
        if (fr.fog.w > 0.5) sky = toLinear(fr.fogColor.rgb) * 0.4;
        return float4(sky, 1.0);
    }

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
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    float wrap = material == 1 ? 0.35 : 0.0; // foliage transmits some light
    float diffuse = saturate((ndl + wrap) / (1.0 + wrap));
    if (diffuse > 0.0 && fr.flags.y == 0) {
        float shadow = 1.0;
        if (fr.flags.x & ADV_SHADOWS) shadow = sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl));
        float skyGate = smoothstep(0.35, 0.9, skyLight); // no direct light deep inside caves
        float3 h = normalize(lightDir + v);
        float a2 = max(rough * rough, 0.002);
        a2 *= a2;
        float nh = saturate(dot(n, h));
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float spec = a2 / (3.14159 * dd * dd) * 0.04 * (1.0 - rough);
        color += lightCol * (albedo * diffuse + spec * saturate(ndl)) * shadow * skyGate;
    }
    color += albedo * skyAmbient(fr, skyLut, lin, nWorld) * (skyLight * skyLight) * ao * fr.ambient.a;
    color += albedo * fr.blockLight.rgb * pow(blockL, fr.blockLight.a) * ao;
    color += albedo * nrm.w * 6.0;
    color += albedo * 0.004 * ao;
    if (int(fr.flags.y) == -1) color += albedo * 0.03; // Nether ambient

    // debug views: 1 no fog, 2 albedo, 3 normals, 4 white albedo lighting, 5 shadow term
    uint dbg = fr.flags.w;
    if (dbg == 1) return float4(color, 1.0);
    if (dbg == 2) return float4(albedo, 1.0);
    if (dbg == 3) return float4(nWorld * 0.5 + 0.5, 1.0);
    if (dbg == 4) return float4(color / max(albedo, 0.02), 1.0);
    if (dbg == 5) return float4(float3((fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl)) : 1.0), 1.0);

    float dist = length(eye);
    if (fr.fog.w > 0.5) {
        // underwater / lava: exponential absorption towards the fluid colour
        float3 fc = toLinear(fr.fogColor.rgb) * 0.4;
        float3 absorb = exp(-dist * (fr.fog.w > 1.5 ? float3(1.2) : float3(0.12, 0.06, 0.035)));
        color = mix(fc, color, absorb);
    } else {
        float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
        fogF *= fogF;
        float haze = (1.0 - exp(-dist * (0.0012 + fr.params.y * 0.01))) * 0.6;
        color = mix(color, hazeColor(fr, skyLut, lin, dirWorld), haze);
        color = mix(color, skyBase(fr, skyLut, lin, dirWorld), fogF);
    }
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

static float waveHeight(float2 p, float t) {
    return sin(p.x * 0.9 + t * 1.3) * 0.12 + sin(p.y * 1.1 - t * 1.1) * 0.1 +
           sin((p.x + p.y) * 2.3 + t * 2.1) * 0.05 + sin((p.x - p.y) * 3.1 - t * 2.6) * 0.035;
}

// Screen-space ray march against the opaque depth; returns uv (xy) and a hit weight (z).
static float3 ssr(constant AdvFrame& fr, depth2d<float> depthTex, float3 eyePos, float3 rdView) {
    float3 p = eyePos;
    float stepLen = 0.6;
    for (int i = 0; i < 40; i++) {
        p += rdView * stepLen;
        stepLen *= 1.09;
        float4 c = fr.proj * float4(p, 1.0);
        if (c.w <= 0.0) break;
        float2 ndc = c.xy / c.w;
        if (any(abs(ndc) > 1.0)) break;
        float2 fc = float2((ndc.x * 0.5 + 0.5) * fr.screen.x, (ndc.y * 0.5 + 0.5) * fr.screen.y);
        float sd = depthTex.read(uint2(fc));
        if (sd >= 1.0) continue;
        float3 sp = eyeFromDepth(fr, fc, sd);
        if (sp.z > p.z && sp.z - p.z < stepLen * 2.5 + 0.2) {
            float edge = saturate(1.0 - max(abs(ndc.x), abs(ndc.y)));
            return float3(fc * fr.screen.zw, saturate(edge * 4.0));
        }
    }
    return float3(0);
}

fragment float4 water_fragment(WaterOut in [[stage_in]], bool front [[front_facing]],
                               constant AdvFrame& fr [[buffer(1)]],
                               texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]],
                               depth2d<float> shadowMap [[texture(4)]], sampler cmp [[sampler(1)]],
                               texture2d<float> skyLut [[texture(5)]], sampler lin [[sampler(2)]],
                               texture2d<float> sceneColor [[texture(6)]], depth2d<float> sceneDepth [[texture(7)]]) {
    float4 t = atlas.sample(s, in.uv);
    float3 n = front ? in.normalView : -in.normalView;
    float3 v = normalize(-in.eye);
    float3 dirWorld = normalize((fr.invView * float4(-v, 0)).xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = saturate(dot(n, lightDir));
    float shadow = (fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, in.world, nWorld, ndl) : 1.0;
    float skyGate = smoothstep(0.35, 0.9, in.lm.y);
    float2 px = in.position.xy;
    uint2 ipx = uint2(px);

    if (in.material != 2) {
        // stained glass, ice, slime...: lit translucent surface
        float3 albedo = toLinear(t.rgb * in.color.rgb);
        float3 c = albedo * (lightCol * ndl * shadow * skyGate + skyAmbient(fr, skyLut, lin, nWorld) * in.lm.y * in.lm.y +
                             fr.blockLight.rgb * pow(in.lm.x, fr.blockLight.a) + 0.004);
        return float4(c, t.a * in.color.a);
    }

    // water: wave normal, refraction with absorption, SSR + sky reflection, sun glint
    float time = fr.params.x;
    float2 wp = in.world.xz + fr.camera.xz;
    float e = 0.05;
    float h0 = waveHeight(wp, time);
    float3 bump = float3(waveHeight(wp + float2(e, 0), time) - h0, 0, waveHeight(wp + float2(0, e), time) - h0) / e;
    float3 nw = abs(nWorld.y) > 0.5 ? normalize(float3(-bump.x * 0.25, nWorld.y, -bump.z * 0.25)) : nWorld;
    float3 nv = normalize((fr.view * float4(nw, 0)).xyz);

    // refraction: offset the opaque scene lookup along the wave normal (fading out at the
    // screen edges), then absorption + turbid in-scattering through the water column
    float2 edge = saturate(min(px, fr.screen.xy - px) / 48.0);
    float2 refrPx = px + nv.xy * float2(1, -1) * (fr.screen.y / 45.0) * edge.x * edge.y;
    refrPx = clamp(refrPx, float2(0.5), fr.screen.xy - 0.5);
    float sceneD = sceneDepth.read(uint2(refrPx));
    float3 sceneEye = eyeFromDepth(fr, refrPx, sceneD);
    if (sceneEye.z > in.eye.z || sceneD >= 1.0) { refrPx = px; sceneD = sceneDepth.read(ipx); sceneEye = eyeFromDepth(fr, px, sceneD); }
    float3 refr = sceneColor.read(uint2(refrPx)).rgb;
    float thickness = sceneD >= 1.0 ? 64.0 : max(length(sceneEye) - length(in.eye), 0.0);
    float3 waterTint = toLinear(t.rgb * in.color.rgb);
    const float3 sigA = float3(0.32, 0.075, 0.05);  // per block: red absorbed first
    const float sigS = 0.09;                         // turbidity
    float3 sigT = sigA + sigS;
    float3 Tw = exp(-thickness * sigT);
    float3 inLight = skyAmbient(fr, skyLut, lin, float3(0, 1, 0)) * in.lm.y * in.lm.y + lightCol * shadow * skyGate * 0.6;
    float3 scatterCol = normalize(waterTint + 0.02) * 0.6 + float3(0.05, 0.25, 0.3);
    float3 below = refr * Tw + inLight * scatterCol * (sigS / sigT) * (1.0 - Tw) * 0.5;

    // reflection
    float3 rdWorld = reflect(dirWorld, nw);
    float3 rdView = normalize((fr.view * float4(rdWorld, 0)).xyz);
    float3 sky = skyRadiance(fr, skyLut, lin, normalize(float3(rdWorld.x, abs(rdWorld.y), rdWorld.z))) * smoothstep(0.2, 0.9, in.lm.y);
    float3 hit = ssr(fr, sceneDepth, in.eye, rdView);
    float3 refl = sky;
    if (hit.z > 0.0) refl = mix(sky, sceneColor.sample(lin, hit.xy).rgb, hit.z);
    float cosT = saturate(dot(-dirWorld, nw));
    float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
    float3 h = normalize(-dirWorld + fr.sunDirWorld.xyz);
    float glint = pow(saturate(dot(nw, h)), 600.0) * 60.0 * shadow * fr.sunDirWorld.w * skyGate;
    float3 c = mix(below, refl, fres) + fr.sunColor.rgb * glint;

    float dist = length(in.eye);
    float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
    float haze = (1.0 - exp(-dist * (0.0012 + fr.params.y * 0.01))) * 0.6;
    c = mix(c, hazeColor(fr, skyLut, lin, dirWorld), haze);
    c = mix(c, skyBase(fr, skyLut, lin, dirWorld), fogF * fogF);
    return float4(c, 1.0);
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
        // soft threshold, then compress very bright sources (sun, sky glow) so they bloom
        // like bright surfaces instead of washing out the frame
        float lum = dot(o, float3(0.2126, 0.7152, 0.0722));
        o *= saturate((lum - p.y) / max(lum, 1e-4));
        float l2 = dot(o, float3(0.2126, 0.7152, 0.0722));
        o *= 1.0 / (1.0 + l2 / 4.0);
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
    return float4(o * (p.x / 16.0), 1.0);
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
