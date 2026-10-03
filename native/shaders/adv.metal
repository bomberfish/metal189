// metal189 advanced pipeline: G-buffer, shadows, deferred PBR lighting, sky,
// water and post-processing.
#include "common.h"
#include "adv.h"
#include <metal_raytracing>
using namespace metal::raytracing;

constant bool ac_alphaTest [[function_constant(10)]];
constant bool ac_waving    [[function_constant(11)]];
constant bool ac_rt        [[function_constant(12)]];

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

static inline float4 metalClip(float4 glClip, float2 jitter) {
    // sub-pixel jitter (TAA), then: offscreen targets keep GL row order: flip Y, map z to [0,1]
    float4 c = glClip;
    c.xy += jitter * c.w;
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

static inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Material ids (see Materials.java): 0 default, 1 leaves/vines, 2 water, 3 emissive, 4 metal, 5 glass, 6 lava,
// 7 entity, 8 plant, 9 double plant (lower half), 10 double plant (upper half)
static inline bool isFoliage(uint m) { return m == 1 || m >= 8; }
struct GBufferOut {
    float4 albedo [[color(0)]];   // rgb: albedo (gamma), a: baked AO
    float4 normal [[color(1)]];   // xyz: eye-space normal, w: emission
    float4 light  [[color(2)]];   // x: block light, y: sky light, z: material/255, w: roughness
    float linZ    [[color(3)]];   // eye-space depth (-z), exact position reconstruction
    float4 spec   [[color(4)]];   // LabPBR: x F0 / metal id, y porosity/SSS, z 1 if the surface has material data
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
    float eyeZ;
    float3 tangentView [[flat]];    // d(position)/du of the quad, eye space
    float3 bitangentView [[flat]];  // d(position)/dv
};

static float3 quadNormal(device const BlockVertex* verts, uint vid) {
    uint b = vid & ~3u;
    float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos);
    float3 n = cross(p1 - p0, p2 - p0);
    float l = length(n);
    return l > 1e-12 ? n / l : float3(0, 1, 0);
}

// Waving foliage, applied identically in G-buffer and shadow passes. The phase comes
// from the absolute world position (camera position mod 1024 + camera-relative offset)
// so it does not drift as the camera moves. Plants bend from the base: only the top
// vertices of a quad move (top = smallest v in the quad's sprite); double plants move
// half as much at the seam so both halves stay joined. Leaves sway as a whole.
static float3 wave(device const BlockVertex* verts, uint vid, float3 local, float3 sectionOffset,
                   constant AdvFrame& fr, uint material) {
    if (!ac_waving || !isFoliage(material)) return local;
    float3 w = local + sectionOffset + fr.camera.xyz;
    float t = fr.params.x * (1.0 + fr.params.y * 0.8);
    float s1 = sin(t * 1.7 + w.x * 0.55 + w.z * 0.35);
    float s2 = sin(t * 2.3 + w.x * 0.27 - w.z * 0.61 + w.y * 0.4);
    float3 d = float3(s1 * 0.6 + s2 * 0.4, 0.0, s2 * 0.5 - s1 * 0.3) * (1.0 + fr.params.y);
    if (material == 1) return local + d * 0.03;
    uint b = vid & ~3u;
    float minV = min(min(float(verts[b].uv[1]), float(verts[b + 1].uv[1])), min(float(verts[b + 2].uv[1]), float(verts[b + 3].uv[1])));
    bool top = float(verts[vid].uv[1]) <= minV + 1e-6;
    float amp = material == 8 ? (top ? 0.1 : 0.0) : material == 9 ? (top ? 0.05 : 0.0) : (top ? 0.1 : 0.05);
    return local + d * amp;
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
    float3 local = wave(verts, vid, float3(v.pos), sectionWorld.xyz, fr, mat);
    float4 eye = sectionMV * float4(local, 1.0);
    GTerrainOut o;
    o.position = metalClip(fr.proj * eye, fr.jitter.xy);
    o.uv = float2(v.uv);
    o.color = float4(v.color) * (1.0 / 255.0);
    o.lm = float2(lmRaw & ushort2(0xFF)) * (1.0 / 240.0);
    float3 nLocal = quadNormal(verts, vid);
    o.normalView = normalize((sectionMV * float4(nLocal, 0)).xyz);
    o.shade = faceShade(nLocal);
    o.material = mat;
    o.emission = float(emissions[state]) * (1.0 / 255.0);
    o.eyeZ = -eye.z;
    // tangent frame from the quad's positions and atlas coordinates (normal mapping)
    {
        uint b = vid & ~3u;
        float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos);
        float2 t0 = float2(verts[b].uv), t1 = float2(verts[b + 1].uv), t2 = float2(verts[b + 2].uv);
        float3 e1 = p1 - p0, e2 = p2 - p0;
        float2 d1 = t1 - t0, d2 = t2 - t0;
        float det = d1.x * d2.y - d1.y * d2.x;
        float r = fabs(det) > 1e-12 ? 1.0 / det : 0.0;
        float3 T = (e1 * d2.y - e2 * d1.y) * r, B = (e2 * d1.x - e1 * d2.x) * r;
        o.tangentView = (sectionMV * float4(T, 0)).xyz;
        o.bitangentView = (sectionMV * float4(B, 0)).xyz;
    }
    return o;
}

fragment GBufferOut gbuf_terrain_fragment(GTerrainOut in [[stage_in]], bool front [[front_facing]],
                                          constant AdvFrame& fr [[buffer(1)]],
                                          texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]],
                                          texture2d<float> nAtlas [[texture(1)]], texture2d<float> sAtlas [[texture(2)]]) {
    float4 t = atlas.sample(s, in.uv);
    if (ac_alphaTest && t.a * in.color.a < 0.1) discard_fragment();
    GBufferOut o;
    float3 c = t.rgb * in.color.rgb / in.shade;
    // vanilla AO is baked into the vertex colour; keep its luminance as an AO term
    float ao = saturate(dot(in.color.rgb / in.shade, float3(0.333)) / max(dot(c / max(t.rgb, 1e-3), float3(0.333)), 1e-3));
    o.albedo = float4(saturate(c), ao);
    float3 n = front ? in.normalView : -in.normalView;
    float emission = in.emission * smoothstep(0.35, 0.9, dot(t.rgb, float3(0.299, 0.587, 0.114)));
    float rough = in.material == 4 ? 0.3 : in.material == 2 ? 0.05 : 0.85;
    o.spec = float4(0);
    if (fr.flags.x & ADV_PBR) {
        // LabPBR: _n = normal xy (OpenGL convention, +y up the texture), AO, height;
        //         _s = smoothness, F0 (>= 230: metal), porosity/SSS, emission (255 = none)
        float4 nm = nAtlas.sample(s, in.uv);
        float2 xy = nm.rg * 2.0 - 1.0;
        float3 ts = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
        float lt = length(in.tangentView), lb = length(in.bitangentView);
        if (lt > 1e-8 && lb > 1e-8) {
            float3 T = in.tangentView / lt, B = in.bitangentView / lb;
            if (!front) { T = -T; B = -B; }
            n = normalize(T * ts.x - B * ts.y + n * ts.z);
        }
        o.albedo.a *= nm.b;
        float4 sp = sAtlas.sample(s, in.uv);
        if (any(sp > 0.0)) {
            rough = (1.0 - sp.r) * (1.0 - sp.r);
            o.spec = float4(sp.g, sp.b, 1.0, 0.0);
            if (sp.a < 254.5 / 255.0) emission = max(emission, sp.a);
        }
    }
    o.normal = float4(n, emission);
    o.light = float4(in.lm.x, in.lm.y, float(in.material) / 255.0, rough);
    o.linZ = in.eyeZ;
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
    float eyeZ;
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
    o.position = metalClip(fr.proj * eye, fr.jitter.xy);
    float4 t0 = fetch(v, layout.tex0, float4(0, 0, 0, 1));
    o.uv = (texMat * t0).xy;
    o.color = fetch(v, layout.color, item.color);
    float4 lm = fetch(v, layout.tex1, float4(item.lightmap.xy, 0, 1));
    o.lm = float2(ushort2(int2(lm.xy)) & ushort2(0xFF)) * (1.0 / 240.0);
    float3 n = fetch(v, layout.normal, float4(item.normal.xyz, 0)).xyz;
    float3 nv = float3x3(xf.normal0.xyz, xf.normal1.xyz, xf.normal2.xyz) * n;
    float l = length(nv);
    o.normalView = l > 1e-6 ? nv / l : float3(0, 0, 1);
    o.eyeZ = -eye.z;
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
    o.linZ = in.eyeZ;
    o.spec = float4(0);
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
    float3 local = wave(verts, vid, float3(v.pos), sectionWorld.xyz, fr, mat);
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
    float2 ndc = float2(fragCoord.x * fr.screen.z * 2.0 - 1.0, fragCoord.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
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

// ---------------------------------------------------------------------------
// volumetric clouds: a layer between kCloudBottom and kCloudTop, raymarched into a
// direction-space cloud map (rgb: in-scattered light, a: transmittance) shared by the
// sky, reflections and terrain cloud shadows

constant float kCloudBottom = 190.0, kCloudTop = 290.0;
constant float kCloudPeriod = 1024.0;   // horizontal noise repeat (blocks); matches the camera wrap

static inline float remap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo);
}

static float3 hash33(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

static inline float3 wrapCell(float3 c, float period) { return c - floor(c / period) * period; }

static float worleyTiled(float3 p, float period) {
    float3 id = floor(p), f = fract(p);
    float d = 1e9;
    for (int z = -1; z <= 1; z++)
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float3 o = float3(x, y, z);
                float3 pt = o + hash33(wrapCell(id + o, period)) - f;
                d = min(d, dot(pt, pt));
            }
    return sqrt(d);
}

static inline float gradDot(float3 cell, float3 d, float period) {
    float3 g = hash33(wrapCell(cell, period)) * 2.0 - 1.0;
    return dot(normalize(g + 1e-4), d);
}

static float perlinTiled(float3 p, float period) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = gradDot(i, f, period), n100 = gradDot(i + float3(1, 0, 0), f - float3(1, 0, 0), period);
    float n010 = gradDot(i + float3(0, 1, 0), f - float3(0, 1, 0), period), n110 = gradDot(i + float3(1, 1, 0), f - float3(1, 1, 0), period);
    float n001 = gradDot(i + float3(0, 0, 1), f - float3(0, 0, 1), period), n101 = gradDot(i + float3(1, 0, 1), f - float3(1, 0, 1), period);
    float n011 = gradDot(i + float3(0, 1, 1), f - float3(0, 1, 1), period), n111 = gradDot(i + float3(1, 1, 1), f - float3(1, 1, 1), period);
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// Tileable cloud noise volume: r = Perlin-Worley (shape), g = Worley fbm, b = high-frequency Worley (erosion).
kernel void cloud_noise_kernel(texture3d<float, access::write> out [[texture(0)]], uint3 gid [[thread_position_in_grid]]) {
    float n = float(out.get_width());
    float3 p = (float3(gid) + 0.5) / n;
    float pf = 0, amp = 1, tot = 0;
    for (int o = 0; o < 4; o++) {
        float per = 4.0 * exp2(float(o));
        pf += perlinTiled(p * per, per) * amp;
        tot += amp;
        amp *= 0.5;
    }
    pf = pf / tot * 0.7 + 0.5;
    float w = 0;
    amp = 1;
    tot = 0;
    for (int o = 0; o < 3; o++) {
        float per = 6.0 * exp2(float(o));
        w += (1.0 - saturate(worleyTiled(p * per, per))) * amp;
        tot += amp;
        amp *= 0.5;
    }
    w /= tot;
    float wd = 0;
    amp = 1;
    tot = 0;
    for (int o = 0; o < 3; o++) {
        float per = 16.0 * exp2(float(o));
        wd += (1.0 - saturate(worleyTiled(p * per, per))) * amp;
        tot += amp;
        amp *= 0.5;
    }
    wd /= tot;
    float pw = saturate(remap(pf, w - 1.0, 1.0, 0.0, 1.0));
    out.write(float4(pw, w, wd, 1.0), gid);
}

// Cloud density at absolute world position p (horizontal coordinates mod 1024).
static float cloudDensity(texture3d<float> noise, sampler rep, float3 p, constant AdvFrame& fr, bool detail) {
    float h = (p.y - kCloudBottom) / (kCloudTop - kCloudBottom);
    if (h <= 0.0 || h >= 1.0) return 0.0;
    float wind = fr.params.x * 4.0;
    float3 q = float3(p.x + wind, p.y * 1.5, p.z + wind * 0.35) / kCloudPeriod;
    float4 n = noise.sample(rep, q);
    float coverage = mix(0.44, 0.9, fr.params.y);
    float profile = smoothstep(0.0, 0.12, h) * smoothstep(1.0, 0.55, h);
    float base = (n.r * 0.55 + n.g * 0.45) * profile;
    float d = saturate(remap(base, 1.0 - coverage, 1.0, 0.0, 1.0) * 1.6);
    if (detail && d > 0.0) {
        float e = noise.sample(rep, q * 7.0 + float3(0.0, fr.params.x * 0.003, 0.0)).b;
        d = saturate(remap(d, e * 0.4 * (1.0 - h * 0.5), 1.0, 0.0, 1.0));
    }
    return d;
}

// Cloud map parameterisation: x = azimuth, y = sqrt(elevation) over the upper hemisphere.
static float3 cloudMapDir(float2 uv) {
    float az = uv.x * 2.0 * 3.14159265;
    float el = uv.y * uv.y * 1.5707963;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}

static float2 cloudMapUv(float3 d) {
    float el = asin(saturate(d.y));
    float az = atan2(d.z, d.x);
    if (az < 0.0) az += 2.0 * 3.14159265;
    return float2(az / (2.0 * 3.14159265), sqrt(el / 1.5707963));
}

static float3 skyBase(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 d);
static float hg(float mu, float g);

fragment float4 clouds_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                texture3d<float> noise [[texture(0)]], texture2d<float> skyLut [[texture(1)]],
                                texture2d<float> prevMap [[texture(2)]], sampler rep [[sampler(0)]], sampler lin [[sampler(1)]]) {
    // checkerboard: half the texels are marched each frame, the rest keep their history
    uint2 cpx = uint2(in.position.xy);
    if (fr.post.y > 0.5 && ((cpx.x + cpx.y + fr.flags.z) & 1u) != 0u) return prevMap.read(cpx);
    float3 d = cloudMapDir(in.uv);
    float3 cam = fr.camera.xyz;
    float4 result = float4(0, 0, 0, 1);
    float t0 = 0, t1 = 0;
    bool march = true;
    if (cam.y < kCloudBottom) {
        if (d.y < 0.005) march = false;
        t0 = (kCloudBottom - cam.y) / max(d.y, 1e-4);
        t1 = (kCloudTop - cam.y) / max(d.y, 1e-4);
    } else if (cam.y > kCloudTop) {
        march = false;   // above the layer: the map only covers the upper hemisphere
    } else {
        t0 = 0.0;
        t1 = (kCloudTop - cam.y) / max(d.y, 0.05);
    }
    if (march && t0 < 24000.0) {
        t1 = min(t1, t0 + 3000.0);
        const int N = 24;
        float dt = (t1 - t0) / N;
        float jit = fract(hash12(in.position.xy) + float(fr.flags.z % 64u) * 0.618034);
        bool sunUp = fr.sunDirWorld.w > 0.0;
        float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
        float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb * 1.5;
        float mu = dot(d, L);
        float phase = mix(hg(mu, 0.65), hg(mu, -0.25), 0.35);
        float3 amb = skyLut.sample(lin, float2(0.5, 1.0), level(5)).rgb;
        const float sigma = 0.06;
        float T = 1.0;
        float3 S = 0;
        for (int i = 0; i < N && T > 0.02; i++) {
            float3 p = cam + d * (t0 + (i + jit) * dt);
            float dens = cloudDensity(noise, rep, p, fr, true);
            if (dens <= 0.002) continue;
            float od = 0, ls = 12.0;
            for (int j = 0; j < 5; j++) {
                od += cloudDensity(noise, rep, p + L * (ls * (j + 0.5)), fr, false) * ls;
                ls *= 1.7;
            }
            float tl = exp(-od * sigma);
            float powder = 1.0 - exp(-od * sigma * 2.0);
            float h = saturate((p.y - kCloudBottom) / (kCloudTop - kCloudBottom));
            float3 lum = lightCol * tl * phase * mix(1.0, powder, 0.5) * 9.0 + amb * (0.4 + 0.6 * h) * 1.2;
            float st = exp(-dens * sigma * dt);
            S += T * lum * (1.0 - st);
            T *= st;
        }
        // distant clouds fade into the sky
        float fade = exp(-t0 / 9000.0);
        result = float4(S * fade, mix(1.0, T, fade));
    }
    // temporal accumulation (the map is direction space, so only translation and wind change it)
    if (fr.post.y > 0.5) result = mix(prevMap.read(cpx), result, 0.3);
    return result;
}

// Transmittance of the cloud layer towards the light at an absolute world position.
static float cloudShadow(constant AdvFrame& fr, texture3d<float> noise, sampler rep, float3 worldAbs, float3 L) {
    if (L.y < 0.05) return 1.0;
    float t = ((kCloudBottom + kCloudTop) * 0.5 - worldAbs.y) / L.y;
    if (t < 0.0) return 1.0;
    float d = cloudDensity(noise, rep, worldAbs + L * t, fr, false);
    float od = d * 0.06 * (kCloudTop - kCloudBottom) * 0.5 / L.y;
    return mix(1.0, exp(-od), 0.9);
}

static float3 skyRadiance(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 dirWorld,
                          texture2d<float> cloudMap) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb);
    float3 d = dirWorld;
    float3 base = skyBase(fr, skyLut, s, d);
    float mu = dot(d, fr.sunDirWorld.xyz);
    float disc = smoothstep(0.99955, 0.9998, mu) * fr.sunDirWorld.w;
    float moon = smoothstep(0.99935, 0.9996, -mu) * (1.0 - fr.sunDirWorld.w);
    float3 c = base + fr.sunColor.rgb * disc * 60.0 + float3(0.8, 0.85, 1.0) * moon * 1.5;
    c += starField(d, fr.camera.w * (1.0 - fr.params.y));
    if ((fr.flags.x & ADV_CLOUDS) && d.y > 0.0) {
        float4 cl = cloudMap.sample(s, cloudMapUv(d));
        c = c * cl.a + cl.rgb;
    }
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

// ---------------------------------------------------------------------------
// hardware ray tracing (terrain acceleration structures, see raytrace.mm)

struct RtInstance {
    device const BlockVertex* verts[3];   // by geometry index
    uint layers;                          // render layer of geometry g in bits [2g, 2g+2)
    uint pad;
};

// Vertex indices of BLAS triangle `prim` (quads split (0,1,2) (0,2,3)).
static inline uint3 rtTri(uint prim) {
    uint b = (prim >> 1) * 4;
    return (prim & 1) ? uint3(b, b + 2, b + 3) : uint3(b, b + 1, b + 2);
}

static inline float3 rtBary(float2 b) { return float3(1.0 - b.x - b.y, b.x, b.y); }

// Alpha test of a cutout candidate (vanilla's 0.1 cutout threshold on texture * vertex alpha).
static bool rtOpaqueAt(device const RtInstance* insts, texture2d<float> atlas, sampler s,
                       uint inst, uint geom, uint prim, float2 bary) {
    device const BlockVertex* v = insts[inst].verts[geom];
    uint3 t = rtTri(prim);
    float3 w = rtBary(bary);
    float2 uv = float2(v[t.x].uv) * w.x + float2(v[t.y].uv) * w.y + float2(v[t.z].uv) * w.z;
    return atlas.sample(s, uv, level(0)).a >= 0.1;
}

static bool rtOccluded(instance_acceleration_structure tlas, device const RtInstance* insts,
                       texture2d<float> atlas, sampler s, float3 o, float3 d, float tmax) {
    intersection_query<instancing, triangle_data> q;
    intersection_params p;
    p.accept_any_intersection(true);
    q.reset(ray(o, d, 0.0, tmax), tlas, 0xFF, p);
    while (q.next()) {
        if (rtOpaqueAt(insts, atlas, s, q.get_candidate_user_instance_id(), q.get_candidate_geometry_id(),
                       q.get_candidate_primitive_id(), q.get_candidate_triangle_barycentric_coord()))
            q.commit_triangle_intersection();
    }
    return q.get_committed_intersection_type() != intersection_type::none;
}

struct RtHit {
    bool hit;
    float t;
    uint inst, geom, prim;
    float2 bary;
};

static RtHit rtClosest(instance_acceleration_structure tlas, device const RtInstance* insts,
                       texture2d<float> atlas, sampler s, float3 o, float3 d, float tmax) {
    intersection_query<instancing, triangle_data> q;
    intersection_params p;
    q.reset(ray(o, d, 0.0, tmax), tlas, 0xFF, p);
    while (q.next()) {
        if (rtOpaqueAt(insts, atlas, s, q.get_candidate_user_instance_id(), q.get_candidate_geometry_id(),
                       q.get_candidate_primitive_id(), q.get_candidate_triangle_barycentric_coord()))
            q.commit_triangle_intersection();
    }
    RtHit h;
    h.hit = q.get_committed_intersection_type() == intersection_type::triangle;
    h.t = h.hit ? q.get_committed_distance() : tmax;
    h.inst = q.get_committed_user_instance_id();
    h.geom = q.get_committed_geometry_id();
    h.prim = q.get_committed_primitive_id();
    h.bary = q.get_committed_triangle_barycentric_coord();
    return h;
}

static float3 skyAmbient(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 nWorld);

// Shades a ray-traced terrain hit like the deferred pass does (sun with a shadow ray,
// sky ambient, block light), used for reflections.
static float3 rtShade(constant AdvFrame& fr, instance_acceleration_structure tlas, device const RtInstance* insts,
                      texture2d<float> atlas, sampler s, texture2d<float> skyLut, sampler lin,
                      RtHit h, float3 o, float3 d, bool traceShadow) {
    device const BlockVertex* v = insts[h.inst].verts[h.geom];
    uint3 t = rtTri(h.prim);
    float3 w = rtBary(h.bary);
    float2 uv = float2(v[t.x].uv) * w.x + float2(v[t.y].uv) * w.y + float2(v[t.z].uv) * w.z;
    float4 col = (float4(v[t.x].color) * w.x + float4(v[t.y].color) * w.y + float4(v[t.z].color) * w.z) * (1.0 / 255.0);
    float2 lm = (float2(ushort2(v[t.x].lm) & ushort2(0xFF)) * w.x + float2(ushort2(v[t.y].lm) & ushort2(0xFF)) * w.y +
                 float2(ushort2(v[t.z].lm) & ushort2(0xFF)) * w.z) * (1.0 / 240.0);
    float3 p0 = float3(v[t.x].pos), p1 = float3(v[t.y].pos), p2 = float3(v[t.z].pos);
    float3 n = normalize(cross(p1 - p0, p2 - p0));
    if (dot(n, d) > 0.0) n = -n;
    float4 tex = atlas.sample(s, uv, level(0));
    float3 albedo = toLinear(tex.rgb * col.rgb / faceShade(n));
    float3 p = o + d * h.t;
    bool sunUp = fr.sunDirWorld.w > 0.0;
    float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = saturate(dot(n, L));
    float3 c = float3(0);
    if (ndl > 0.0 && fr.flags.y == 0) {
        // without a shadow ray, sky light approximates sun visibility
        float vis = traceShadow ? (rtOccluded(tlas, insts, atlas, s, p + n * 0.01, L, 320.0) ? 0.0 : 1.0)
                                : smoothstep(0.85, 1.0, lm.y);
        c += lightCol * albedo * ndl * smoothstep(0.35, 0.9, lm.y) * vis;
    }
    float daySky = lm.y * lm.y * fr.sunDirWorld.w;
    c += albedo * skyAmbient(fr, skyLut, lin, n) * lm.y * lm.y;
    c += albedo * fr.blockLight.rgb * pow(lm.x, fr.blockLight.a) * (1.0 - 0.75 * daySky);
    c += albedo * 0.004;
    return c;
}

// Ray-traced ambient occlusion at half resolution: 4 short cosine-weighted rays per
// texel (rotated each frame), denoised by aoblur_fragment and accumulated by TAA.
fragment float4 rtao_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                              depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                              texture2d<float> gNormal [[texture(2)]],
                              instance_acceleration_structure tlas [[buffer(10)]],
                              device const RtInstance* rtInst [[buffer(11)]],
                              texture2d<float> atlas [[texture(7)]], sampler pointS [[sampler(2)]]) {
    uint2 fp = min(uint2(in.position.xy) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float d = depth.read(fp);
    if (d >= 1.0) return float4(1.0);
    float2 ndc = float2((float(fp.x) + 0.5) * fr.screen.z * 2.0 - 1.0, (float(fp.y) + 0.5) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(fp).r / -rd.z);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 nWorld = normalize((fr.invView * float4(normalize(gNormal.read(fp).xyz), 0)).xyz);
    float3 up = abs(nWorld.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tx = normalize(cross(up, nWorld)), ty = cross(nWorld, tx);
    float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
    // TAA integrates over frames, so 2 rotating rays suffice with it; 4 without
    int rays = fr.taa.w > 0.5 ? 2 : 4;
    float open = 0.0;
    float rot = hash12(in.position.xy) * 6.2831853 + float(fr.flags.z % 64u) * 2.399963;
    for (int i = 0; i < rays; i++) {
        float u = (float(i) + fract(hash12(in.position.yx + float(i)) + float(fr.flags.z % 16u) * 0.618034)) / float(rays);
        float r = sqrt(u), phi = rot + float(i) * 6.2831853 / float(rays);
        float3 dir = normalize(tx * (r * cos(phi)) + ty * (r * sin(phi)) + nWorld * sqrt(max(0.0, 1.0 - u)));
        open += rtOccluded(tlas, rtInst, atlas, pointS, o, dir, 2.5) ? 0.0 : 1.0;
    }
    return float4(open / float(rays), 1.0, 1.0, 1.0);
}

// ---------------------------------------------------------------------------
// ray-traced global illumination (one diffuse bounce, half resolution)

// One cosine-weighted ray per texel; hits are shaded with sun (shadow ray), sky light and
// emission, misses see the sky. Output: incoming indirect radiance (Lambert-normalised).
fragment float4 gi_trace_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                  depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                  texture2d<float> gNormal [[texture(2)]], texture2d<float> skyLut [[texture(5)]],
                                  instance_acceleration_structure tlas [[buffer(10)]],
                                  device const RtInstance* rtInst [[buffer(11)]],
                                  device const uchar* emissions [[buffer(6)]],
                                  texture2d<float> atlas [[texture(7)]], sampler pointS [[sampler(2)]],
                                  sampler lin [[sampler(1)]]) {
    uint2 fp = min(uint2(in.position.xy) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float d = depth.read(fp);
    if (d >= 1.0) return float4(0.0);
    float2 ndc = float2((float(fp.x) + 0.5) * fr.screen.z * 2.0 - 1.0, (float(fp.y) + 0.5) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(fp).r / -rd.z);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 nWorld = normalize((fr.invView * float4(normalize(gNormal.read(fp).xyz), 0)).xyz);
    float3 up = abs(nWorld.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tx = normalize(cross(up, nWorld)), ty = cross(nWorld, tx);
    float2 xi = hash22(in.position.xy * 0.73 + float(fr.flags.z % 1024u) * float2(5.17, 11.3));
    float r = sqrt(xi.x), phi = 6.2831853 * xi.y;
    float3 dir = normalize(tx * (r * cos(phi)) + ty * (r * sin(phi)) + nWorld * sqrt(max(0.0, 1.0 - xi.x)));
    float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
    RtHit h = rtClosest(tlas, rtInst, atlas, pointS, o, dir, 48.0);
    if (!h.hit) {
        // sky (no sun disc: direct sun is handled by the deferred pass)
        return float4(fr.flags.y != 0 ? toLinear(fr.fogColor.rgb) * 0.3 : skyBase(fr, skyLut, lin, dir), 1.0);
    }
    device const BlockVertex* v = rtInst[h.inst].verts[h.geom];
    uint3 t = rtTri(h.prim);
    float3 w = rtBary(h.bary);
    float2 uv = float2(v[t.x].uv) * w.x + float2(v[t.y].uv) * w.y + float2(v[t.z].uv) * w.z;
    float4 col = (float4(v[t.x].color) * w.x + float4(v[t.y].color) * w.y + float4(v[t.z].color) * w.z) * (1.0 / 255.0);
    float2 lm = (float2(ushort2(v[t.x].lm) & ushort2(0xFF)) * w.x + float2(ushort2(v[t.y].lm) & ushort2(0xFF)) * w.y +
                 float2(ushort2(v[t.z].lm) & ushort2(0xFF)) * w.z) * (1.0 / 240.0);
    ushort2 lmRaw = ushort2(v[t.x].lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    float3 p0 = float3(v[t.x].pos), p1 = float3(v[t.y].pos), p2 = float3(v[t.z].pos);
    float3 n = normalize(cross(p1 - p0, p2 - p0));
    if (dot(n, dir) > 0.0) n = -n;
    float3 albedo = toLinear(atlas.sample(pointS, uv, level(0)).rgb * col.rgb / faceShade(n));
    float3 p = o + dir * h.t;
    bool sunUp = fr.sunDirWorld.w > 0.0;
    float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float3 c = float3(0);
    float ndl = saturate(dot(n, L));
    if (ndl > 0.0 && fr.flags.y == 0 && !rtOccluded(tlas, rtInst, atlas, pointS, p + n * 0.01, L, 256.0))
        c += lightCol * albedo * ndl;
    c += albedo * skyAmbient(fr, skyLut, lin, n) * lm.y * lm.y;
    c += albedo * fr.blockLight.rgb * pow(lm.x, fr.blockLight.a) * 0.5;
    c += albedo * float(emissions[state]) * (6.0 / 255.0);
    return float4(c, 1.0);
}

// Temporal accumulation of the GI samples: reprojects last frame's history with the camera
// motion, rejects disocclusions by depth, and keeps up to 32 frames (count in alpha).
struct GiTemporalOut {
    float4 gi [[color(0)]];
    float z [[color(1)]];
};

fragment GiTemporalOut gi_temporal_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                            texture2d<float> sample [[texture(0)]], texture2d<float> hist [[texture(1)]],
                                            texture2d<float> histZ [[texture(2)]], texture2d<float> gLinZ [[texture(3)]],
                                            depth2d<float> depth [[texture(4)]], sampler lin [[sampler(0)]]) {
    GiTemporalOut o;
    uint2 c = uint2(in.position.xy);
    uint2 fp = min(c * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float3 cur = sample.read(c).rgb;
    float z = gLinZ.read(fp).r;
    o.z = z;
    o.gi = float4(cur, 1.0);
    if (fr.post.w < 0.5 || depth.read(fp) >= 1.0) return o;
    float2 ndc = float2((float(fp.x) + 0.5) * fr.screen.z * 2.0 - 1.0, (float(fp.y) + 0.5) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (z / -rd.z);
    float3 rel = (fr.invView * float4(eye, 1.0)).xyz;
    float4 pc = fr.prevViewProj * float4(rel + fr.taa.xyz, 1.0);
    if (pc.w <= 0.0) return o;
    float2 puv = (pc.xy / pc.w) * 0.5 + 0.5;
    if (any(puv < 0.0) || any(puv > 1.0)) return o;
    uint2 ph = min(uint2(puv * float2(hist.get_width(), hist.get_height())), uint2(hist.get_width() - 1, hist.get_height() - 1));
    float pz = histZ.read(ph).r;
    if (abs(pz - pc.w) > max(pc.w * 0.04, 0.08)) return o;   // disocclusion
    float4 h = hist.sample(lin, puv);
    float n = min(h.a + 1.0, 32.0);
    o.gi = float4(mix(h.rgb, cur, 1.0 / n), n);
    return o;
}

// Separable depth/normal-aware blur of the half-resolution GI (rgb), radius 6.
fragment float4 giblur_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                texture2d<float> src [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                texture2d<float> gNormal [[texture(2)]], constant float4& p [[buffer(0)]]) {
    int2 c = int2(in.position.xy);
    int2 mx = int2(src.get_width(), src.get_height()) - 1;
    uint2 fpc = min(uint2(c) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float z0 = gLinZ.read(fpc).r;
    float3 n0 = gNormal.read(fpc).xyz;
    float4 center = src.read(uint2(c));
    float3 sum = 0.0;
    float wsum = 0.0;
    for (int i = -6; i <= 6; i++) {
        int2 q = clamp(c + int2(p.xy) * i, int2(0), mx);
        uint2 fq = min(uint2(q) * 2u + 1u, uint2(fr.screen.xy) - 1u);
        float z = gLinZ.read(fq).r;
        float3 nq = gNormal.read(fq).xyz;
        float w = exp(-float(i * i) / 18.0) * exp(-abs(z - z0) / max(z0 * 0.03, 0.05)) * pow(saturate(dot(nq, n0)), 16.0);
        sum += src.read(uint2(q)).rgb * w;
        wsum += w;
    }
    return float4(sum / max(wsum, 1e-4), center.a);
}

// Separable depth/normal-aware blur of the half-resolution AO (p.xy: texel step).
fragment float4 aoblur_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                texture2d<float> ao [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                texture2d<float> gNormal [[texture(2)]], constant float4& p [[buffer(0)]]) {
    int2 c = int2(in.position.xy);
    int2 mx = int2(ao.get_width(), ao.get_height()) - 1;
    uint2 fpc = min(uint2(c) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float z0 = gLinZ.read(fpc).r;
    float3 n0 = gNormal.read(fpc).xyz;
    float sum = 0.0, wsum = 0.0;
    for (int i = -4; i <= 4; i++) {
        int2 q = clamp(c + int2(p.xy) * i, int2(0), mx);
        uint2 fq = min(uint2(q) * 2u + 1u, uint2(fr.screen.xy) - 1u);
        float z = gLinZ.read(fq).r;
        float3 nq = gNormal.read(fq).xyz;
        float w = exp(-float(i * i) / 8.0) * exp(-abs(z - z0) / max(z0 * 0.03, 0.05)) * pow(saturate(dot(nq, n0)), 8.0);
        sum += ao.read(uint2(q)).r * w;
        wsum += w;
    }
    return float4(sum / max(wsum, 1e-4), 1.0, 1.0, 1.0);
}

// Water as a participating medium (per block): absorption takes red first, turbidity
// scatters the light that reaches the water back towards the eye.
constant float3 kWaterAbsorb = float3(0.30, 0.075, 0.05);
constant float kWaterScatter = 0.07;

static float3 underwaterInscatter(constant AdvFrame& fr, texture2d<float> skyLut, sampler lin) {
    float3 sun = fr.sunDirWorld.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float3 light = skyLut.sample(lin, float2(0.5, 1.0), level(5)).rgb * 1.2 + sun * 0.35;
    float3 sigT = kWaterAbsorb + kWaterScatter;
    return light * float3(0.12, 0.5, 0.6) * (kWaterScatter / sigT);
}

// Animated caustics on underwater surfaces (warped interference pattern).
static float caustics(float2 p, float t) {
    float2 q = p * 0.55;
    float c = 0.0;
    for (int i = 0; i < 3; i++) {
        q += float2(sin(q.y * 1.7 + t * 0.9), cos(q.x * 1.3 - t * 0.7)) * 0.4;
        c += abs(sin(q.x * 2.1) * sin(q.y * 2.3));
    }
    c /= 3.0;
    return c * c * c * 4.0;
}

static float3 ssr(constant AdvFrame& fr, depth2d<float> depthTex, float3 eyePos, float3 rdView);

fragment float4 light_fragment(FullscreenOut in [[stage_in]],
                               constant AdvFrame& fr [[buffer(1)]],
                               texture2d<float> gAlbedo [[texture(0)]],
                               texture2d<float> gNormal [[texture(1)]],
                               texture2d<float> gLight [[texture(2)]],
                               depth2d<float> depth [[texture(3)]],
                               depth2d<float> shadowMap [[texture(4)]],
                               texture2d<float> skyLut [[texture(5)]],
                               texture2d<float> gLinZ [[texture(6)]],
                               texture2d<float> cloudMap [[texture(8)]],
                               texture3d<float> cloudNoise [[texture(9)]],
                               texture2d<float> gSpec [[texture(10)]],
                               texture2d<float> history [[texture(11)]],
                               texture2d<float> rtaoTex [[texture(12)]],
                               texture2d<float> giTex [[texture(13)]],
                               sampler cmp [[sampler(0)]], sampler lin [[sampler(1)]],
                               sampler rep [[sampler(3)]],
                               instance_acceleration_structure tlas [[buffer(10), function_constant(ac_rt)]],
                               device const RtInstance* rtInst [[buffer(11), function_constant(ac_rt)]],
                               texture2d<float> atlas [[texture(7), function_constant(ac_rt)]],
                               sampler pointS [[sampler(2), function_constant(ac_rt)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    // eye-space position from the exact linear depth (the depth buffer loses precision far away)
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = d >= 1.0 ? rd : rd * (gLinZ.read(px).r / -rd.z);
    float3 dirWorld = normalize((fr.invView * float4(eye, 0)).xyz);
    if (d >= 1.0) {
        float3 sky = skyRadiance(fr, skyLut, lin, dirWorld, cloudMap);
        if (fr.fog.w > 1.5) sky = toLinear(fr.fogColor.rgb) * 2.0;
        else if (fr.fog.w > 0.5) sky = underwaterInscatter(fr, skyLut, lin);
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

    // material response: LabPBR data when present, otherwise per-material defaults
    float4 spm = gSpec.read(px);
    float metal = 0.0;
    float3 F0 = float3(0.04);
    if (spm.z > 0.5) {
        if (spm.x >= 229.5 / 255.0) { metal = 1.0; F0 = albedo; }
        else F0 = float3(spm.x);
    } else if (material == 4) {
        metal = 0.85;
        F0 = mix(float3(0.04), albedo, metal);
    }
    // rain: exposed surfaces get wet (porous ones darken), puddles form on open ground
    if (fr.params.y > 0.01 && fr.flags.y == 0 && !isFoliage(material) && material != 2 && material != 7) {
        float exposed = smoothstep(0.8, 0.97, skyLight);
        float up = smoothstep(0.6, 0.95, nWorld.y);
        float3 wa = world + fr.camera.xyz;
        float puddle = up * smoothstep(0.45, 0.62, cloudNoise.sample(rep, float3(wa.xz / 80.0, 0.37)).g);
        float wet = fr.params.y * exposed;
        float porous = spm.z > 0.5 && spm.y < 0.26 ? spm.y * 4.0 : 0.6;
        albedo *= mix(1.0, 0.55, wet * porous * (1.0 - puddle * 0.5));
        rough = mix(rough, rough * 0.55, wet);
        rough = mix(rough, 0.03, wet * puddle);
        F0 = max(F0, float3(0.02 * wet));
    }
    // ray-traced ambient occlusion (half resolution, denoised; see rtao_fragment)
    if (fr.flags.x & ADV_RT_AO) ao *= mix(1.0, rtaoTex.sample(lin, in.uv).r, 0.85);
    float3 color = float3(0);
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    float wrap = isFoliage(material) ? 0.35 : 0.0; // foliage transmits some light
    float diffuse = saturate((ndl + wrap) / (1.0 + wrap));
    float rtShadow = 1.0;
    if (diffuse > 0.0 && fr.flags.y == 0) {
        float shadow = 1.0;
        if (ac_rt && (fr.flags.x & ADV_RT_SHADOW)) {
            // terrain: exact ray-traced shadows over the whole loaded world;
            // the shadow map then only holds dynamic geometry (entities)
            float3 Lw = fr.sunDirView.w > 0.0 ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
            float3 nOff = dot(nWorld, Lw) >= 0.0 ? nWorld : -nWorld;
            float3 o = world + fr.rtCam.xyz + nOff * (0.004 + length(eye) * 0.0002);
            rtShadow = rtOccluded(tlas, rtInst, atlas, pointS, o, Lw, 320.0) ? 0.0 : 1.0;
            shadow = rtShadow;
            if (fr.flags.x & ADV_SHADOWS) shadow *= sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl));
        } else if (fr.flags.x & ADV_SHADOWS) shadow = sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl));
        float skyGate = smoothstep(0.35, 0.9, skyLight); // no direct light deep inside caves
        if (fr.flags.x & ADV_CLOUDS) {
            float3 Lw = fr.sunDirView.w > 0.0 ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
            shadow *= cloudShadow(fr, cloudNoise, rep, world + fr.camera.xyz, Lw);
        }
        // Cook-Torrance: GGX distribution, Smith-Schlick visibility, Schlick Fresnel
        float nl = saturate(ndl), nv = saturate(dot(n, v)) + 1e-4;
        float3 h = normalize(lightDir + v);
        float nh = saturate(dot(n, h)), vh = saturate(dot(v, h));
        float a = max(rough * rough, 0.002), a2 = a * a;
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float D = a2 / (3.14159 * dd * dd);
        float k = (rough + 1.0) * (rough + 1.0) * 0.125;
        float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
        float3 F = F0 + (1.0 - F0) * pow(1.0 - vh, 5.0);
        // lightCol is scaled so that Lambert is albedo * N.L; the specular lobe gets the matching pi
        float3 specular = 3.14159 * D * G * F / (4.0 * nv);
        if (fr.fog.w > 0.5 && fr.fog.w < 1.5) shadow *= 0.3 + caustics((world + fr.camera.xyz).xz, fr.params.x);
        color += lightCol * (albedo * diffuse * (1.0 - F) * (1.0 - metal) + specular * nl) * shadow * skyGate;
    }
    // sky light: diffuse irradiance + split-sum specular reflection (Lazarov's environment BRDF fit)
    {
        float nv = saturate(dot(n, v));
        float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022), c1 = float4(1.0, 0.0425, 1.04, -0.04);
        float4 r4 = rough * c0 + c1;
        float a004 = min(r4.x * r4.x, exp2(-9.28 * nv)) * r4.x + r4.y;
        float2 env = float2(-1.04, 1.04) * a004 + r4.zw;
        float3 R = reflect(-v, n);
        float3 Rw = normalize((fr.invView * float4(R, 0)).xyz);
        // reflected sky; below the horizon, a darkened horizon stands in for the ground
        float3 envCol = fr.flags.y != 0 ? toLinear(fr.fogColor.rgb) * 0.3
                                       : skyLut.sample(lin, lutUv(normalize(float3(Rw.x, max(Rw.y, 0.02), Rw.z))), level(rough * 6.0)).rgb;
        envCol *= mix(1.0, 0.3, saturate(-Rw.y * 2.5));
        float3 skyVis = float3(skyLight * skyLight * ao * fr.ambient.a);
        if (fr.flags.x & ADV_RT_GI)
            color += albedo * (1.0 - metal) * giTex.sample(lin, in.uv).rgb * ao;   // ray-traced sky light + bounce
        else
            color += albedo * (1.0 - metal) * skyAmbient(fr, skyLut, lin, nWorld) * skyVis;
        float3 refl = envCol * skyVis;
        // smooth surfaces: traced reflections (RT closest hit, or screen space into last frame's resolve)
        float smoothW = 1.0 - smoothstep(0.12, 0.4, rough);
        if (smoothW > 0.0) {
            float3 Rr = R;
            if (fr.taa.w > 0.5 && rough > 0.05) {
                // one GGX sample per pixel and frame; TAA integrates the lobe
                float2 xi = hash22(in.position.xy + float(fr.flags.z % 256u) * float2(17.13, 7.31));
                float ag = rough * rough;
                float phi = 6.2831853 * xi.x;
                float ct = sqrt((1.0 - xi.y) / (1.0 + (ag * ag - 1.0) * xi.y)), st = sqrt(1.0 - ct * ct);
                float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
                float3 tx = normalize(cross(up, n)), ty = cross(n, tx);
                float3 hv = normalize(tx * (st * cos(phi)) + ty * (st * sin(phi)) + n * ct);
                Rr = reflect(-v, hv);
                if (dot(Rr, n) <= 0.0) Rr = R;
            }
            float3 Rrw = normalize((fr.invView * float4(Rr, 0)).xyz);
            float3 traced = refl;
            bool hitAny = false;
            if (ac_rt && (fr.flags.x & ADV_RT_REFL)) {
                float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
                RtHit rh = rtClosest(tlas, rtInst, atlas, pointS, o, Rrw, 256.0);
                if (rh.hit) {
                    traced = rtShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, rh, o, Rrw, smoothW > 0.5);
                    float hd = length(Rrw * rh.t + world);
                    float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
                    traced = mix(traced, skyBase(fr, skyLut, lin, Rrw), hf * hf);
                    hitAny = true;
                }
            } else if (fr.taa.w > 0.5) {
                float3 hit = ssr(fr, depth, eye, Rr);
                if (hit.z > 0.0) {
                    traced = mix(refl, history.sample(lin, hit.xy).rgb, hit.z);
                    hitAny = true;
                }
            }
            if (hitAny) refl = mix(refl, traced, smoothW);
        }
        color += refl * (F0 * env.x + env.y);
    }
    // dynamic light from the player's held item: vanilla falloff (one level per block);
    // ray-traced visibility when RT shadows are on, otherwise it passes walls like OptiFine's
    if (fr.post.z > 0.5) {
        float dcam = length(eye);
        float lvl = saturate((fr.post.z - dcam) / 15.0);
        if (lvl > 0.0) {
            float vis = 1.0;
            if (ac_rt && (fr.flags.x & ADV_RT_SHADOW) && dcam > 1.0) {
                float3 o = world + fr.rtCam.xyz + nWorld * 0.02;
                vis = rtOccluded(tlas, rtInst, atlas, pointS, o, normalize(-world), dcam - 0.8) ? 0.0 : 1.0;
            }
            blockL = max(blockL, lvl * vis * (0.6 + 0.4 * saturate(dot(n, v))));
        }
    }
    // block light fades in daylight (vanilla's lightmap is closer to max(sky, block) than a sum)
    float daySky = skyLight * skyLight * fr.sunDirWorld.w;
    color += albedo * fr.blockLight.rgb * pow(blockL, fr.blockLight.a) * ao * (1.0 - 0.75 * daySky);
    color += albedo * nrm.w * 6.0;
    color += albedo * 0.004 * ao;
    if (int(fr.flags.y) == -1) color += albedo * 0.03; // Nether ambient
    if (int(fr.flags.y) == 1) color += albedo * float3(0.045, 0.038, 0.06); // the End's dim violet ambient

    // debug views: 1 no fog, 2 albedo, 3 normals, 4 white albedo lighting, 5 shadow term
    uint dbg = fr.flags.w;
    if (dbg == 1) return float4(color, 1.0);
    if (dbg == 2) return float4(albedo, 1.0);
    if (dbg == 3) return float4(nWorld * 0.5 + 0.5, 1.0);
    if (dbg == 4) return float4(color / max(albedo, 0.02), 1.0);
    if (dbg == 5) return float4(float3((fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl)) : 1.0), 1.0);
    if (dbg == 6) return float4(float3(rtShadow), 1.0);

    float dist = length(eye);
    if (fr.fog.w > 1.5) {
        // inside lava
        color = mix(toLinear(fr.fogColor.rgb) * 2.0, color, exp(-dist * 1.2));
    } else if (fr.fog.w > 0.5) {
        // underwater: absorption and in-scattering along the view ray
        float3 tv = exp(-dist * (kWaterAbsorb + kWaterScatter));
        color = color * tv + underwaterInscatter(fr, skyLut, lin) * (1.0 - tv);
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
    o.position = metalClip(fr.proj * eye, fr.jitter.xy);
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
                               texture2d<float> sceneColor [[texture(6)]], depth2d<float> sceneDepth [[texture(7)]],
                               instance_acceleration_structure tlas [[buffer(10), function_constant(ac_rt)]],
                               device const RtInstance* rtInst [[buffer(11), function_constant(ac_rt)]],
                               sampler pointS [[sampler(3), function_constant(ac_rt)]],
                               texture2d<float> cloudMap [[texture(8)]]) {
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
                             fr.blockLight.rgb * pow(in.lm.x, fr.blockLight.a) * (1.0 - 0.75 * in.lm.y * in.lm.y * fr.sunDirWorld.w) + 0.004);
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

    // seen from below (vanilla draws the top face a second time, reversed): Snell's window
    // shows the refracted sky, outside it total internal reflection of the lit water
    if (nWorld.y < -0.5) {
        float3 nDown = normalize(float3(bump.x * 0.25, -1.0, bump.z * 0.25));
        float3 inScat = underwaterInscatter(fr, skyLut, lin);
        float3 tr = refract(dirWorld, nDown, 1.33);
        float3 c;
        if (dot(tr, tr) < 1e-6) {
            c = inScat * 1.2;
        } else {
            float cosI = saturate(dot(-dirWorld, nDown));
            float fr0 = 0.02 + 0.98 * pow(1.0 - cosI, 5.0);
            c = mix(skyRadiance(fr, skyLut, lin, normalize(tr), cloudMap) * skyGate, inScat * 1.2, fr0);
        }
        float3 tv = exp(-length(in.eye) * (kWaterAbsorb + kWaterScatter));
        return float4(c * tv + inScat * (1.0 - tv), 1.0);
    }

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
    float3 sky = skyRadiance(fr, skyLut, lin, normalize(float3(rdWorld.x, abs(rdWorld.y), rdWorld.z)), cloudMap) *
                 smoothstep(0.2, 0.9, in.lm.y);
    float3 refl = sky;
    float cosT = saturate(dot(-dirWorld, nw));
    float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
    if (ac_rt && (fr.flags.x & ADV_RT_REFL)) {
        // ray-traced reflection of the terrain (off-screen geometry included); skipped
        // where the Fresnel weight makes it invisible
        float3 o = in.world + fr.rtCam.xyz + nw * 0.02;
        RtHit rh;
        rh.hit = false;
        if (fres > 0.03) rh = rtClosest(tlas, rtInst, atlas, pointS, o, rdWorld, 320.0);
        if (rh.hit) {
            float3 hc = rtShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, rh, o, rdWorld, fres > 0.15);
            float hd = length(rh.t * rdWorld + in.world);  // distance from the camera
            float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
            refl = mix(hc, skyBase(fr, skyLut, lin, rdWorld), hf * hf);
        }
    } else {
        float3 hit = ssr(fr, sceneDepth, in.eye, rdView);
        if (hit.z > 0.0) refl = mix(sky, sceneColor.sample(lin, hit.xy).rgb, hit.z);
    }
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
// volumetric light: sun in-scattering through the shadow map (half resolution)

fragment float4 volumetric_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                    depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                    depth2d<float> shadowMap [[texture(2)]], texture3d<float> cloudNoise [[texture(3)]],
                                    sampler cmp [[sampler(0)]], sampler rep [[sampler(1)]]) {
    uint2 fp = min(uint2(in.position.xy * 2.0), uint2(fr.screen.xy) - 1);
    float d = depth.read(fp);
    float2 ndc = float2((float(fp.x) + 1.0) * fr.screen.z * 2.0 - 1.0, (float(fp.y) + 1.0) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 dirEye = normalize(rd);
    const float maxDist = 128.0;
    float dist = d >= 1.0 ? maxDist : min(length(rd * (gLinZ.read(fp).r / -rd.z)), maxDist);
    bool sunUp = fr.sunDirWorld.w > 0.0;
    float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float3 dirWorld = normalize((fr.invView * float4(dirEye, 0.0)).xyz);
    float mu = dot(dirWorld, L);
    float phase = mix(hg(mu, 0.85), hg(mu, 0.3), 0.35);
    // haze density: thin in clear weather, thicker in rain and towards dawn/dusk
    float sigma = mix(0.0016, 0.006, fr.params.y) * (1.0 + 0.8 * (1.0 - smoothstep(0.05, 0.4, L.y)));
    const int N = 16;
    float dt = dist / N;
    float jit = fract(hash12(in.position.xy) + float(fr.flags.z % 64u) * 0.618034);
    float vis = 0.0, T = 1.0;
    for (int i = 0; i < N; i++) {
        float3 pEye = dirEye * ((i + jit) * dt);
        float3 world = (fr.invView * float4(pEye, 1.0)).xyz;
        float4 sc = fr.shadowViewProj * float4(world, 1.0);
        float3 sn = sc.xyz / sc.w;
        float2 uv = float2(sn.x * 0.5 + 0.5, 0.5 - sn.y * 0.5);
        float v = (any(uv < 0.0) || any(uv > 1.0)) ? 1.0 : shadowMap.sample_compare(cmp, uv, sn.z - 0.0005);
        vis += v * T * dt;
        T *= exp(-sigma * dt);
    }
    float clouds = (fr.flags.x & ADV_CLOUDS) ? cloudShadow(fr, cloudNoise, rep, fr.camera.xyz + dirWorld * dist * 0.5, L) : 1.0;
    float3 scatter = lightCol * phase * sigma * vis * clouds * 2.4;
    return float4(scatter, 1.0);
}

fragment float4 volcomp_fragment(FullscreenOut in [[stage_in]], texture2d<float> vol [[texture(0)]], sampler lin [[sampler(0)]]) {
    return float4(vol.sample(lin, in.uv).rgb, 0.0);
}

// ---------------------------------------------------------------------------
// temporal anti-aliasing

static inline float3 rgbToYCoCg(float3 c) {
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}
static inline float3 yCoCgToRgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }
// Resolve in a compressed range so bright pixels do not dominate the history (Karis).
static inline float3 compress(float3 c) { return c / (1.0 + max(c.r, max(c.g, c.b))); }
static inline float3 uncompress(float3 c) { return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4); }

// 5-tap Catmull-Rom history fetch (bilinear taps at weighted positions).
static float3 sampleCatmullRom(texture2d<float> t, sampler s, float2 uv, float2 size) {
    float2 pos = uv * size;
    float2 c = floor(pos - 0.5) + 0.5;
    float2 f = pos - c;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tc0 = (c - 1.0) / size, tc3 = (c + 2.0) / size, tc12 = (c + w2 / w12) / size;
    float3 r = t.sample(s, float2(tc12.x, tc0.y)).rgb * (w12.x * w0.y) +
               t.sample(s, float2(tc0.x, tc12.y)).rgb * (w0.x * w12.y) +
               t.sample(s, tc12).rgb * (w12.x * w12.y) +
               t.sample(s, float2(tc3.x, tc12.y)).rgb * (w3.x * w12.y) +
               t.sample(s, float2(tc12.x, tc3.y)).rgb * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(r / wsum, 0.0);
}

fragment float4 taa_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                             texture2d<float> cur [[texture(0)]], texture2d<float> hist [[texture(1)]],
                             depth2d<float> depth [[texture(2)]], sampler lin [[sampler(0)]]) {
    int2 px = int2(in.position.xy);
    int2 maxPx = int2(fr.screen.xy) - 1;
    float3 c = cur.read(uint2(px)).rgb;
    if (fr.taa.w < 0.5) return float4(c, 1.0);
    // neighbourhood statistics (YCoCg, compressed) and the closest depth for reprojection
    float3 m1 = 0, m2 = 0;
    float dMin = 1.0;
    int2 dPx = px;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            int2 q = clamp(px + int2(x, y), int2(0), maxPx);
            float3 v = rgbToYCoCg(compress(cur.read(uint2(q)).rgb));
            m1 += v;
            m2 += v * v;
            float d = depth.read(uint2(q));
            if (d < dMin) { dMin = d; dPx = q; }
        }
    float3 mean = m1 / 9.0, sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
    float3 boxMin = mean - 1.25 * sigma, boxMax = mean + 1.25 * sigma;

    // reproject the closest surface with the camera motion (sky: direction only)
    float3 eye = eyeFromDepth(fr, float2(dPx) + 0.5, dMin >= 1.0 ? 0.9999999 : dMin);
    float3 rel = (fr.invView * float4(eye, 1.0)).xyz;
    float3 prevRel = dMin >= 1.0 ? normalize(rel) * 1e5 : rel + fr.taa.xyz;
    float4 pc = fr.prevViewProj * float4(prevRel, 1.0);
    if (pc.w <= 0.0) return float4(c, 1.0);
    // motion excludes this frame's jitter: the surface seen at dPx sits at (ndc - jitter) unjittered
    float2 prevNdc = pc.xy / pc.w + fr.jitter.xy;
    float2 prevUv = prevNdc * 0.5 + 0.5 + (float2(px) + 0.5 - (float2(dPx) + 0.5)) * fr.screen.zw;
    if (any(prevUv < 0.0) || any(prevUv > 1.0)) return float4(c, 1.0);

    float3 h = rgbToYCoCg(compress(sampleCatmullRom(hist, lin, prevUv, fr.screen.xy)));
    // clip the history towards the neighbourhood mean (AABB clipping)
    float3 center = 0.5 * (boxMax + boxMin), ext = 0.5 * (boxMax - boxMin) + 1e-5;
    float3 off = h - center;
    float3 ts = abs(off / ext);
    float tmax = max(ts.x, max(ts.y, ts.z));
    if (tmax > 1.0) h = center + off / tmax;
    // more weight on the current frame when the history moved a lot (disocclusion-prone)
    float motion = length((prevUv - (float2(px) + 0.5) * fr.screen.zw) * fr.screen.xy);
    float alpha = mix(0.08, 0.25, saturate(motion / 8.0));
    float3 outC = mix(h, rgbToYCoCg(compress(c)), alpha);
    return float4(uncompress(yCoCgToRgb(outC)), 1.0);
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

// Auto exposure: log-average luminance over a 64x36 grid, adapted over time
// (darkening faster than brightening). state: x exposure, y last time, z valid, w average.
kernel void exposure_kernel(texture2d<float> hdr [[texture(0)]], device float4* state [[buffer(0)]],
                            constant AdvFrame& fr [[buffer(1)]], uint tid [[thread_index_in_threadgroup]],
                            uint tcount [[threads_per_threadgroup]]) {
    threadgroup float partial[256];
    float w = float(hdr.get_width()), h = float(hdr.get_height());
    float sum = 0.0;
    for (uint i = tid; i < 64u * 36u; i += tcount) {
        float2 g = float2(float(i % 64u) + 0.5, float(i / 64u) + 0.5);
        uint2 p = uint2(g.x * w / 64.0, g.y * h / 36.0);
        float l = dot(hdr.read(p).rgb, float3(0.2126, 0.7152, 0.0722));
        sum += log(max(l, 1e-4));
    }
    partial[tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tcount / 2; s > 0; s >>= 1) {
        if (tid < s) partial[tid] += partial[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        float avg = exp(partial[0] / (64.0 * 36.0));
        float target = clamp(pow(0.2 / avg, 0.6), 0.7, 2.5);   // partial adaptation, like the eye
        float4 st = state[0];
        float dt = clamp(fr.params.x - st.y, 0.0, 0.25);
        if (st.z < 0.5) st.x = target;
        else st.x = mix(st.x, target, 1.0 - exp(-dt * (target < st.x ? 2.5 : 0.9)));
        state[0] = float4(st.x, fr.params.x, 1.0, avg);
    }
}

static float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

fragment float4 tonemap_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                 texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                 sampler s [[sampler(0)]], device const float4* expState [[buffer(2)]]) {
    int2 px = int2(in.position.xy);
    float3 b = (fr.flags.x & ADV_BLOOM) ? bloom.sample(s, in.uv).rgb * (0.06 * fr.post.x) : float3(0);
    float exposure = fr.params.z * ((fr.flags.x & ADV_AUTOEXP) ? expState[0].x : 1.0);
    float3 c = aces((hdr.read(uint2(px)).rgb + b) * exposure);
    if (fr.flags.x & ADV_TAA) {
        // contrast-adaptive sharpening (after AMD CAS) to restore texture detail TAA softens
        int2 mx = int2(fr.screen.xy) - 1;
        float3 n = aces((hdr.read(uint2(clamp(px + int2(0, -1), int2(0), mx))).rgb + b) * exposure);
        float3 w_ = aces((hdr.read(uint2(clamp(px + int2(-1, 0), int2(0), mx))).rgb + b) * exposure);
        float3 e = aces((hdr.read(uint2(clamp(px + int2(1, 0), int2(0), mx))).rgb + b) * exposure);
        float3 so = aces((hdr.read(uint2(clamp(px + int2(0, 1), int2(0), mx))).rgb + b) * exposure);
        float3 mn = min(min(min(n, w_), min(e, so)), c), mxv = max(max(max(n, w_), max(e, so)), c);
        float3 amp = sqrt(saturate(min(mn, 1.0 - mxv) / max(mxv, 1e-4)));
        float3 wgt = -amp / mix(8.0, 5.0, 0.55);
        c = saturate((c + (n + w_ + e + so) * wgt) / (1.0 + 4.0 * wgt));
    }
    // subtle vignette
    float2 q = in.uv - 0.5;
    c *= 1.0 - dot(q, q) * 0.35;
    return float4(toGamma(c), 1.0);
}
