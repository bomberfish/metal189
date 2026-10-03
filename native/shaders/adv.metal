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
    float4 uvBounds [[flat]];       // the quad's atlas rectangle (min xy, max zw): parallax wraps inside it
    float3 eyePos;
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
        float2 t3 = float2(verts[b + 3].uv);
        o.uvBounds = float4(min(min(t0, t1), min(t2, t3)), max(max(t0, t1), max(t2, t3)));
    }
    o.eyePos = eye.xyz;
    return o;
}

// user settings (Pipeline.java TUNE_*)
#define PBR_TUNE fr.tune[6]   // x: normal strength, y: specular strength, z: emission strength, w: format (0 LabPBR, 1 SEUS)
#define POM_TUNE fr.tune[7]   // x: depth (blocks, 0 = off), y: steps, z: distance (blocks), w: PBR enabled

// Parallax occlusion mapping: march the view ray into the height field (the normal atlas'
// alpha: 1 = surface, 0 = deepest) until it passes below it, then interpolate between the
// last two steps. The march stays inside the quad's sprite (wrapping), and samples use the
// unshifted coordinates' derivatives so the mip level does not jump.
static float2 parallaxUv(texture2d<float> nAtlas, sampler s, float2 uv, float2 dx, float2 dy, float4 bounds,
                         float3 eyeDir, float3 T, float3 B, float3 N, float depth, int steps) {
    float dn = dot(eyeDir, N);   // < 0 when looking at the front
    if (dn > -0.08 || depth <= 0.0) return uv;
    float3 lat = eyeDir - dn * N;
    float2 shift = float2(dot(lat, T) / max(dot(T, T), 1e-12), dot(lat, B) / max(dot(B, B), 1e-12)) * (depth / -dn);
    float2 size = max(bounds.zw - bounds.xy, float2(1e-6));
    float stepH = 1.0 / float(steps);
    float h = 1.0, prevH = 1.0, surf = 1.0, prevSurf = 1.0;
    float2 cur = uv, prev = uv;
    for (int i = 0; i < steps; i++) {
        surf = nAtlas.sample(s, bounds.xy + fract((cur - bounds.xy) / size) * size, gradient2d(dx, dy)).a;
        if (surf >= h) break;
        prev = cur;
        prevH = h;
        prevSurf = surf;
        h -= stepH;
        cur += shift * stepH;
    }
    float after = surf - h, before = prevSurf - prevH;
    float w = after - before != 0.0 ? saturate(after / (after - before)) : 0.0;
    float2 hit = mix(cur, prev, w);
    return bounds.xy + fract((hit - bounds.xy) / size) * size;
}

fragment GBufferOut gbuf_terrain_fragment(GTerrainOut in [[stage_in]], bool front [[front_facing]],
                                          constant AdvFrame& fr [[buffer(1)]],
                                          texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]],
                                          texture2d<float> nAtlas [[texture(1)]], texture2d<float> sAtlas [[texture(2)]]) {
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float2 uv = in.uv;
    bool pbrOn = (fr.flags.x & ADV_PBR) != 0;
    float pomDepth = POM_TUNE.x * saturate((POM_TUNE.z - in.eyeZ) / max(POM_TUNE.z * 0.25, 1.0));
    if (!ac_alphaTest && pbrOn && pomDepth > 0.0) {
        float lt = length(in.tangentView), lb = length(in.bitangentView);
        if (lt > 1e-8 && lb > 1e-8) {
            float3 Nf = front ? in.normalView : -in.normalView;
            uv = parallaxUv(nAtlas, s, in.uv, dx, dy, in.uvBounds, normalize(in.eyePos), in.tangentView, in.bitangentView,
                            Nf, pomDepth, int(POM_TUNE.y));
        }
    }
    float4 t = atlas.sample(s, uv, gradient2d(dx, dy));
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
    if (pbrOn) {
        // LabPBR: _n = normal xy (OpenGL convention, +y up the texture), AO, height;
        //         _s = smoothness, F0 (>= 230: metal), porosity/SSS, emission (255 = none)
        // SEUS (older format): _n = normal xyz, height; _s = smoothness, metalness, emission
        bool seus = PBR_TUNE.w > 0.5;
        float4 nm = nAtlas.sample(s, uv, gradient2d(dx, dy));
        float3 ts;
        if (seus) {
            ts = nm.rgb * 2.0 - 1.0;
        } else {
            float2 xy = nm.rg * 2.0 - 1.0;
            ts = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
        }
        ts.xy *= PBR_TUNE.x;   // normal map strength
        ts = dot(ts, ts) > 1e-8 ? normalize(ts) : float3(0, 0, 1);
        float lt = length(in.tangentView), lb = length(in.bitangentView);
        if (lt > 1e-8 && lb > 1e-8) {
            float3 T = in.tangentView / lt, B = in.bitangentView / lb;
            if (!front) { T = -T; B = -B; }
            n = normalize(T * ts.x - B * ts.y + n * ts.z);
        }
        if (!seus) o.albedo.a *= mix(1.0, nm.b, saturate(PBR_TUNE.x));
        float4 sp = sAtlas.sample(s, uv, gradient2d(dx, dy));
        if (any(sp > 0.0)) {
            float specK = PBR_TUNE.y;
            float smooth = saturate(sp.r * specK);
            rough = mix(rough, (1.0 - smooth) * (1.0 - smooth), saturate(specK));
            if (seus) {
                bool metal = sp.g >= 0.5;
                o.spec = float4(metal ? 1.0 : 0.04 * saturate(specK), 0.0, 1.0, 0.0);
                emission = max(emission, saturate(sp.b * PBR_TUNE.z));
            } else {
                bool metal = sp.g >= 229.5 / 255.0;
                o.spec = float4(metal ? sp.g : min(sp.g * specK, 229.0 / 255.0), sp.b, 1.0, 0.0);
                if (sp.a < 254.5 / 255.0) emission = max(emission, saturate(sp.a * PBR_TUNE.z));
            }
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
    o.albedo = float4(mix(saturate(t.rgb * in.color.rgb), item.overlay.rgb, item.overlay.a), 1.0);
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

// Water surfaces in light space (the water shadow map): only water writes depth, so the
// lighting can tell how far sunlight travelled through water to reach a point.
struct WaterShadowOut {
    float4 position [[position]];
    uint material [[flat]];
};

vertex WaterShadowOut shadow_water_vertex(uint vid [[vertex_id]],
                                          device const BlockVertex* verts [[buffer(0)]],
                                          constant AdvFrame& fr [[buffer(1)]],
                                          constant float4& sectionWorld [[buffer(4)]],
                                          device const uchar* materials [[buffer(5)]]) {
    BlockVertex v = verts[vid];
    ushort2 lmRaw = ushort2(v.lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    WaterShadowOut o;
    o.position = fr.shadowViewProj * float4(float3(v.pos) + sectionWorld.xyz, 1.0);
    o.material = materials[state];
    return o;
}

fragment void shadow_water_fragment(WaterShadowOut in [[stage_in]]) {
    if (in.material != 2) discard_fragment();
}

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
    // grass, flowers and other plants stay out of the shadow map when plant shadows are off
    // (fr.tune[5].y bit 0); the whole quad goes outside the clip volume
    if (mat >= 8 && (uint(fr.tune[5].y + 0.5) & 1u) == 0u) o.position = float4(2.0, 2.0, 2.0, 1.0);
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
    float wind = fr.params.x * 4.0 * fr.tune[10].y;   // cloud speed setting
    float3 q = float3(p.x + wind, p.y * 1.5, p.z + wind * 0.35) / kCloudPeriod;
    float4 n = noise.sample(rep, q);
    float coverage = saturate(mix(0.44, 0.9, fr.params.y) * fr.tune[10].x);   // cloud coverage setting
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
                          texture2d<float> cloudMap, bool sunDisc = true) {
    if (fr.flags.y != 0) return toLinear(fr.fogColor.rgb);
    float3 d = dirWorld;
    float3 base = skyBase(fr, skyLut, s, d);
    float mu = dot(d, fr.sunDirWorld.xyz);
    float disc = sunDisc ? smoothstep(0.99955, 0.9998, mu) * fr.sunDirWorld.w : 0.0;
    float3 c = base + fr.sunColor.rgb * disc * 60.0;
    // moon (always opposite the sun in Minecraft) with vanilla's phases: a lit sphere whose
    // terminator is an ellipse, plus faint earthshine on the dark part
    float moonMask = smoothstep(0.99935, 0.9996, -mu) * (1.0 - fr.sunDirWorld.w);
    if (moonMask > 0.0) {
        float3 m = -fr.sunDirWorld.xyz;
        float3 ax = normalize(cross(m, float3(0, 0, 1)));
        float rad = sqrt(1.0 - 0.99948 * 0.99948);
        float lx = dot(d, ax) / rad, ly = d.z / rad;
        float rr = saturate(1.0 - ly * ly);
        float cosA = 2.0 * fr.moon.x - 1.0;              // phase angle: cos = 2k - 1
        float xt = -cosA * sqrt(rr);
        float lit = smoothstep(xt - 0.08, xt + 0.08, fr.moon.y * lx);
        float maria = 0.85 + 0.15 * hash12(floor(float2(lx, ly) * 6.0 + 10.0));
        c += float3(0.8, 0.85, 1.0) * moonMask * (lit * 1.5 * maria + 0.03);
    }
    c += starField(d, fr.camera.w * (1.0 - fr.params.y) * fr.tune[10].w);
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

// ---------------------------------------------------------------------------
// ray-traced entities: the frame's captured opaque geometry (mobs, players including the
// first-person one, block entities) converted to ray tracing space by rt_entity_vertices,
// in one primitive acceleration structure built every frame (see raytrace.mm)

struct RtEntSource {                 // one per draw (matches EntSource in raytrace.mm)
    float4x4 toRt;                   // object space -> ray tracing space
    float4x4 texMat;
    float4 color;                    // current colour when the layout has none
    VertexLayout layout;
    uint4 range;                     // x: first output vertex, y: vertex count, z: draw index
    device const uchar* vb;          // the draw's first vertex
    ulong pad;
};

struct RtEntVertex {
    packed_float3 pos;
    uint draw;
    packed_float2 uv;
    uchar4 color;
    uint pad;
};

struct RtEntDraw {
    uint tex;                        // index into the texture table
    uint flags;                      // bit 0: alpha tested
    float alphaRef;
    float emissive;
    float2 lm;                       // block, sky light (0..1)
    float2 pad;
};

struct RtEntTex {
    texture2d<float> tex;
};

kernel void rt_entity_vertices(device const RtEntSource* src [[buffer(0)]],
                               constant uint2& counts [[buffer(1)]],   // x: draws, y: vertices
                               device RtEntVertex* out [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
    if (id >= counts.y) return;
    uint lo = 0, hi = counts.x - 1;
    while (lo < hi) {
        uint mid = (lo + hi + 1) >> 1;
        if (src[mid].range.x <= id) lo = mid; else hi = mid - 1;
    }
    device const RtEntSource& s = src[lo];
    device const uchar* v = s.vb + (id - s.range.x) * s.layout.stride.x;
    float4 p = s.toRt * fetch(v, s.layout.pos, float4(0, 0, 0, 1));
    float4 t0 = fetch(v, s.layout.tex0, float4(0, 0, 0, 1));
    float4 c = fetch(v, s.layout.color, s.color);
    RtEntVertex o;
    o.pos = packed_float3(p.xyz / p.w);
    o.draw = s.range.z;
    o.uv = packed_float2((s.texMat * t0).xy);
    o.color = uchar4(saturate(c) * 255.0 + 0.5);
    o.pad = 0;
    out[id] = o;
}

constexpr sampler rtEntSampler(filter::nearest, address::repeat);

static bool rtEntOpaqueAt(device const RtEntVertex* ev, device const RtEntDraw* ed, device const RtEntTex* et,
                          uint prim, float2 bary) {
    uint3 t = rtTri(prim);
    RtEntDraw dr = ed[ev[t.x].draw];
    if ((dr.flags & 1u) == 0) return true;
    float3 w = rtBary(bary);
    float2 uv = float2(ev[t.x].uv) * w.x + float2(ev[t.y].uv) * w.y + float2(ev[t.z].uv) * w.z;
    float a = (float(ev[t.x].color.a) * w.x + float(ev[t.y].color.a) * w.y + float(ev[t.z].color.a) * w.z) * (1.0 / 255.0);
    return et[dr.tex].tex.sample(rtEntSampler, uv, level(0)).a * a > dr.alphaRef;
}

static RtHit rtEntClosest(primitive_acceleration_structure as, device const RtEntVertex* ev, device const RtEntDraw* ed,
                          device const RtEntTex* et, float3 o, float3 d, float tmax) {
    intersection_query<triangle_data> q;
    intersection_params p;
    q.reset(ray(o, d, 0.0, tmax), as, p);
    while (q.next()) {
        if (rtEntOpaqueAt(ev, ed, et, q.get_candidate_primitive_id(), q.get_candidate_triangle_barycentric_coord()))
            q.commit_triangle_intersection();
    }
    RtHit h;
    h.hit = q.get_committed_intersection_type() == intersection_type::triangle;
    h.t = h.hit ? q.get_committed_distance() : tmax;
    h.inst = 0;
    h.geom = 0;
    h.prim = q.get_committed_primitive_id();
    h.bary = q.get_committed_triangle_barycentric_coord();
    return h;
}

// Occlusion for short AO rays: entity cutouts are treated as solid (no alpha test, so the
// hardware resolves the query without returning to the shader).
static bool rtEntOccludedSolid(primitive_acceleration_structure as, float3 o, float3 d, float tmax) {
    intersection_query<triangle_data> q;
    intersection_params p;
    p.accept_any_intersection(true);
    p.force_opacity(forced_opacity::opaque);
    q.reset(ray(o, d, 0.0, tmax), as, p);
    q.next();
    return q.get_committed_intersection_type() != intersection_type::none;
}

// Closest hit without alpha testing (diffuse GI rays).
static RtHit rtEntClosestSolid(primitive_acceleration_structure as, float3 o, float3 d, float tmax) {
    intersection_query<triangle_data> q;
    intersection_params p;
    p.force_opacity(forced_opacity::opaque);
    q.reset(ray(o, d, 0.0, tmax), as, p);
    q.next();
    RtHit h;
    h.hit = q.get_committed_intersection_type() == intersection_type::triangle;
    h.t = h.hit ? q.get_committed_distance() : tmax;
    h.inst = 0;
    h.geom = 0;
    h.prim = q.get_committed_primitive_id();
    h.bary = q.get_committed_triangle_barycentric_coord();
    return h;
}

// Entity hit shading, as rtShade does for terrain (entity colours carry no baked face shading).
static float3 rtEntShade(constant AdvFrame& fr, instance_acceleration_structure tlas, device const RtInstance* insts,
                         texture2d<float> atlas, sampler s, texture2d<float> skyLut, sampler lin,
                         device const RtEntVertex* ev, device const RtEntDraw* ed, device const RtEntTex* et,
                         RtHit h, float3 o, float3 d, bool traceShadow) {
    uint3 t = rtTri(h.prim);
    float3 w = rtBary(h.bary);
    RtEntVertex a = ev[t.x], b = ev[t.y], c3 = ev[t.z];
    RtEntDraw dr = ed[a.draw];
    float2 uv = float2(a.uv) * w.x + float2(b.uv) * w.y + float2(c3.uv) * w.z;
    float4 col = (float4(a.color) * w.x + float4(b.color) * w.y + float4(c3.color) * w.z) * (1.0 / 255.0);
    float3 albedo = toLinear(et[dr.tex].tex.sample(rtEntSampler, uv, level(0)).rgb * col.rgb);
    float3 n = cross(float3(b.pos) - float3(a.pos), float3(c3.pos) - float3(a.pos));
    n = dot(n, n) > 1e-12 ? normalize(n) : -d;
    if (dot(n, d) > 0.0) n = -n;
    float3 p = o + d * h.t;
    bool sunUp = fr.sunDirWorld.w > 0.0;
    float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = saturate(dot(n, L));
    float2 lm = dr.lm;
    float3 c = float3(0);
    if (ndl > 0.0 && fr.flags.y == 0) {
        float vis = traceShadow ? (rtOccluded(tlas, insts, atlas, s, p + n * 0.01, L, 320.0) ? 0.0 : 1.0)
                                : smoothstep(0.85, 1.0, lm.y);
        c += lightCol * albedo * ndl * smoothstep(0.35, 0.9, lm.y) * vis;
    }
    float daySky = lm.y * lm.y * fr.sunDirWorld.w;
    c += albedo * skyAmbient(fr, skyLut, lin, n) * lm.y * lm.y;
    c += albedo * fr.blockLight.rgb * pow(lm.x, fr.blockLight.a) * (1.0 - 0.75 * daySky);
    c += albedo * (0.004 + dr.emissive * 6.0);
    return c;
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
    c += albedo * 0.004 * fr.tune[9].x;
    return c;
}

// Ray-traced ambient occlusion at half resolution: 4 short cosine-weighted rays per
// texel (rotated each frame), denoised by aoblur_fragment and accumulated by TAA.
fragment float4 rtao_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                              depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                              texture2d<float> gNormal [[texture(2)]],
                              instance_acceleration_structure tlas [[buffer(10)]],
                              device const RtInstance* rtInst [[buffer(11)]],
                              primitive_acceleration_structure entAs [[buffer(12)]],
                              device const RtEntVertex* entV [[buffer(13)]],
                              device const RtEntDraw* entD [[buffer(14)]],
                              device const RtEntTex* entT [[buffer(15)]],
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
        bool occ = rtOccluded(tlas, rtInst, atlas, pointS, o, dir, 2.5);
        if (!occ && (fr.flags.x & ADV_RT_ENTITIES)) occ = rtEntOccludedSolid(entAs, o, dir, 2.5);
        open += occ ? 0.0 : 1.0;
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
                                  primitive_acceleration_structure entAs [[buffer(12)]],
                                  device const RtEntVertex* entV [[buffer(13)]],
                                  device const RtEntDraw* entD [[buffer(14)]],
                                  device const RtEntTex* entT [[buffer(15)]],
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
    if (fr.flags.x & ADV_RT_ENTITIES) {
        RtHit eh = rtEntClosestSolid(entAs, o, dir, h.t);
        if (eh.hit) return float4(rtEntShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, entV, entD, entT, eh, o, dir, true), 1.0);
    }
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

// Screen-space ambient occlusion (HBAO+ style) at half resolution: 4 rotating directions
// x 6 steps within a 1-block radius, depth-aware falloff; TAA integrates the rotation.
static inline float3 eyeAtPixel(constant AdvFrame& fr, texture2d<float> gLinZ, uint2 p) {
    float2 ndc = float2((float(p.x) + 0.5) * fr.screen.z * 2.0 - 1.0, (float(p.y) + 0.5) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    return rd * (gLinZ.read(p).r / -rd.z);
}

fragment float4 ssao_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                              depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                              texture2d<float> gNormal [[texture(2)]]) {
    uint2 maxP = uint2(fr.screen.xy) - 1u;
    uint2 fp = min(uint2(in.position.xy) * 2u + 1u, maxP);
    if (depth.read(fp) >= 1.0) return float4(1.0);
    float3 P = eyeAtPixel(fr, gLinZ, fp);
    float3 N = normalize(gNormal.read(fp).xyz);
    const float R = 1.0;
    // the radius in full-resolution pixels at this depth
    float rPx = clamp(R * fr.proj[1][1] * 0.5 * fr.screen.y / max(-P.z, 0.05), 3.0, 96.0);
    const int DIRS = 4, STEPS = 6;
    float rot = hash12(in.position.xy) * 6.2831853 + float(fr.flags.z % 64u) * 2.399963;
    float jit = fract(hash12(in.position.yx * 1.7) + float(fr.flags.z % 16u) * 0.618034);
    float occ = 0.0;
    for (int d = 0; d < DIRS; d++) {
        float ang = rot + float(d) * (3.14159265 / float(DIRS));
        float2 dir = float2(cos(ang), sin(ang));
        for (int side = -1; side <= 1; side += 2) {
            for (int i = 0; i < STEPS; i++) {
                float t = (float(i) + jit) / float(STEPS);
                float2 off = dir * float(side) * (1.0 + t * rPx);
                int2 q = int2(float2(fp) + off);
                if (any(q < 0) || any(q > int2(maxP))) break;
                float3 V = eyeAtPixel(fr, gLinZ, uint2(q)) - P;
                float vv = dot(V, V);
                float ndv = dot(N, V) * rsqrt(max(vv, 1e-6));
                occ += saturate(ndv - 0.15) * saturate(1.0 - vv / (R * R));
            }
        }
    }
    float ao = saturate(1.0 - occ * 2.0 / float(DIRS * STEPS * 2));
    return float4(ao, 1.0, 1.0, 1.0);
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

// user settings (Pipeline.java TUNE_*)
#define WATER_WAVES   fr.tune[0]   // x: strength, y: size, z: speed, w: style (0 smooth, 1 pixel, 2 vanilla texture)
#define WATER_SURFACE fr.tune[1]   // x: reflectivity (F0), y: sun reflection, z: refraction, w: foam
#define WATER_ABSORB  fr.tune[2]   // xyz: absorption per block, w: scattering per block
#define WATER_COLOR   fr.tune[3]   // xyz: deep-water colour (linear), w: caustics
#define WATER_UNDER   fr.tune[4]   // x: underwater visibility (blocks to 50%), y: distortion, z: flags, w: foam width
#define WF_BIOME_TINT   1u
#define WF_CALM_INDOORS 2u
#define LIGHT_TUNE fr.tune[9]    // x: minimum light
#define SKY_TUNE   fr.tune[10]   // x: cloud coverage, y: cloud speed, z: haze density, w: star brightness
#define POST_TUNE  fr.tune[11]   // x: vignette, y: sharpening, z: saturation, w: contrast

// Water as a participating medium (user colour and clarity): absorption takes red first,
// and the light the water scatters back gives deep water its colour.
static float3 underwaterInscatter(constant AdvFrame& fr, texture2d<float> skyLut, sampler lin) {
    float3 sun = fr.sunDirWorld.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float3 light = skyLut.sample(lin, float2(0.5, 1.0), level(5)).rgb * 1.2 + sun * 0.35;
    return light * WATER_COLOR.rgb * 1.5;
}

// Share of the view hidden by underwater fog at distance d: Gaussian, so the near field
// stays clear, reaching half at the visibility setting.
static inline float underwaterFog(constant AdvFrame& fr, float d) {
    float r = d / max(WATER_UNDER.x, 1.0);
    return 1.0 - exp(-0.6931 * r * r);
}

static float3 ssr(constant AdvFrame& fr, depth2d<float> depthTex, float3 eyePos, float3 rdView, float jitter);
static float waterCaustics(constant AdvFrame& fr, texture2d<float> waveTex, sampler wrep, float2 p, float2 dX, float2 dY, float d);

// Distance sunlight travelled through water before reaching `world` (camera-relative), in
// blocks along the light direction; 0 when no water lies between it and the sun.
static float waterLightPath(constant AdvFrame& fr, depth2d<float> waterShadow, sampler s, float3 world, float3 nWorld) {
    float4 sc = fr.shadowViewProj * float4(world + nWorld * 0.05, 1.0);
    float2 uv = float2(sc.x * 0.5 + 0.5, 0.5 - sc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || sc.z > 1.0) return 0.0;
    // the nearest water surface among the 4 texels around (filtering would blend in the
    // "no water" texels next to walls and lose the water at its edges)
    float4 g = waterShadow.gather(s, uv);
    float wz = min(min(g.x, g.y), min(g.z, g.w));
    return max((sc.z - wz) * 512.0 - 0.02, 0.0);   // light-space depth spans 512 blocks
}

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
                               depth2d<float> waterShadow [[texture(14)]],
                               texture2d<float> waveTex [[texture(15)]],
                               sampler cmp [[sampler(0)]], sampler lin [[sampler(1)]],
                               sampler rep [[sampler(3)]], sampler wrep [[sampler(4)]],
                               instance_acceleration_structure tlas [[buffer(10), function_constant(ac_rt)]],
                               device const RtInstance* rtInst [[buffer(11), function_constant(ac_rt)]],
                               primitive_acceleration_structure entAs [[buffer(12), function_constant(ac_rt)]],
                               device const RtEntVertex* entV [[buffer(13), function_constant(ac_rt)]],
                               device const RtEntDraw* entD [[buffer(14), function_constant(ac_rt)]],
                               device const RtEntTex* entT [[buffer(15), function_constant(ac_rt)]],
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
    else if (fr.flags.x & ADV_SSAO) ao *= mix(1.0, rtaoTex.sample(lin, in.uv).r, 0.7);
    // sunlight that reached this point through water: absorbed over its path (red first)
    // and focused into caustics by the waves it came through (water shadow map)
    float2 wpX = dfdx(world.xz), wpY = dfdy(world.xz);   // outside the branch: derivatives need uniform flow
    float waterPath = 0.0;
    float3 waterSun = float3(1.0);
    if ((fr.flags.x & ADV_WATER_SHADOW) && fr.flags.y == 0) {
        waterPath = waterLightPath(fr, waterShadow, lin, world, nWorld);
        if (waterPath > 0.0) {
            float3 Lw = fr.sunDirView.w > 0.0 ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
            float3 entry = world + fr.camera.xyz + Lw * waterPath;
            waterSun = exp(-(WATER_ABSORB.xyz + WATER_ABSORB.w) * waterPath) *
                       waterCaustics(fr, waveTex, wrep, entry.xz, wpX, wpY, waterPath);
        }
    }
    float3 color = float3(0);
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    bool foliage = isFoliage(material);
    float wrap = foliage ? 0.35 : 0.0; // foliage transmits some light
    float diffuse = saturate((ndl + wrap) / (1.0 + wrap));
    float rtShadow = 1.0;
    if ((diffuse > 0.0 || (foliage && fr.tune[5].x > 0.0)) && fr.flags.y == 0) {
        float shadow = 1.0;
        // shadow lookups offset towards the light (a backlit leaf must not shadow itself)
        float3 nShadow = ndl < 0.0 ? -nWorld : nWorld;
        if (ac_rt && (fr.flags.x & ADV_RT_SHADOW)) {
            // terrain: exact ray-traced shadows over the whole loaded world;
            // the shadow map then only holds dynamic geometry (entities)
            float3 Lw = fr.sunDirView.w > 0.0 ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
            float3 nOff = dot(nWorld, Lw) >= 0.0 ? nWorld : -nWorld;
            float3 o = world + fr.rtCam.xyz + nOff * (0.004 + length(eye) * 0.0002);
            rtShadow = rtOccluded(tlas, rtInst, atlas, pointS, o, Lw, 320.0) ? 0.0 : 1.0;
            shadow = rtShadow;
            if (fr.flags.x & ADV_SHADOWS) shadow *= sampleShadow(fr, shadowMap, cmp, world, nShadow, abs(ndl));
        } else if (fr.flags.x & ADV_SHADOWS) shadow = sampleShadow(fr, shadowMap, cmp, world, nShadow, abs(ndl));
        // no direct light deep inside caves; under water the light path above decides instead
        float skyGate = waterPath > 0.0 ? 1.0 : smoothstep(0.35, 0.9, skyLight);
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
        color += lightCol * waterSun * (albedo * diffuse * (1.0 - F) * (1.0 - metal) + specular * nl) * shadow * skyGate;
        if (foliage) {
            // light passing through thin leaves and blades: some reaches the shaded side,
            // most of it towards a viewer looking at the sun through them
            float through = saturate(-ndl) * 0.35 + pow(saturate(dot(-v, lightDir)), 3.0) * 1.4;
            color += lightCol * waterSun * albedo * through * fr.tune[5].x * 0.8 * shadow * skyGate * ao;
        }
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
        if (waterPath > 0.0)
            color += albedo * (1.0 - metal) * underwaterInscatter(fr, skyLut, lin) * exp(-WATER_ABSORB.xyz * waterPath * 0.5) * 0.6 * ao;
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
                RtHit eh;
                eh.hit = false;
                if (fr.flags.x & ADV_RT_ENTITIES) eh = rtEntClosest(entAs, entV, entD, entT, o, Rrw, rh.t);
                if (eh.hit || rh.hit) {
                    traced = eh.hit ? rtEntShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, entV, entD, entT, eh, o, Rrw, smoothW > 0.5)
                                    : rtShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, rh, o, Rrw, smoothW > 0.5);
                    float hd = length(Rrw * (eh.hit ? eh.t : rh.t) + world);
                    float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
                    traced = mix(traced, skyBase(fr, skyLut, lin, Rrw), hf * hf);
                    hitAny = true;
                }
            } else if (fr.taa.w > 0.5) {
                float3 hit = ssr(fr, depth, eye, Rr, fract(hash12(in.position.xy) + float(fr.flags.z % 64u) * 0.618034));
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
    color += albedo * 0.004 * LIGHT_TUNE.x * ao;
    if (int(fr.flags.y) == -1) color += albedo * 0.03; // Nether ambient
    if (int(fr.flags.y) == 1) color += albedo * float3(0.045, 0.038, 0.06); // the End's dim violet ambient

    // debug views: 1 no fog, 2 albedo, 3 normals, 4 white albedo lighting, 5 shadow term, 6 RT shadow,
    // 7 sunlight's path through water (yellow shallow, red deep), 8 lightmap (red sky, green block)
    uint dbg = fr.flags.w;
    if (dbg == 1) return float4(color, 1.0);
    if (dbg == 2) return float4(albedo, 1.0);
    if (dbg == 3) return float4(nWorld * 0.5 + 0.5, 1.0);
    if (dbg == 4) return float4(color / max(albedo, 0.02), 1.0);
    if (dbg == 5) return float4(float3((fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl)) : 1.0), 1.0);
    if (dbg == 6) return float4(float3(rtShadow), 1.0);
    if (dbg == 7) return float4(waterPath > 0.0 ? float3(1.0, 1.0 - saturate(waterPath / 16.0), 0.2) : float3(0.0), 1.0);
    if (dbg == 8) return float4(skyLight, blockL, 0.0, 1.0);    // G-buffer lightmap: red sky, green block

    float dist = length(eye);
    if (fr.fog.w > 1.5) {
        // inside lava
        color = mix(toLinear(fr.fogColor.rgb) * 2.0, color, exp(-dist * 1.2));
    } else if (fr.fog.w > 0.5) {
        // underwater: absorption (red first) and fog along the view ray
        float f = underwaterFog(fr, dist);
        color = color * exp(-WATER_ABSORB.xyz * dist * 0.5) * (1.0 - f) + underwaterInscatter(fr, skyLut, lin) * f;
    } else {
        float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
        fogF *= fogF;
        float haze = (1.0 - exp(-dist * (0.0012 + fr.params.y * 0.01) * SKY_TUNE.z)) * 0.6;
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

// Wave texture, generated once by wave_texture_kernel: a tileable height field built from
// random integer-frequency waves (so it repeats seamlessly), stored as xy = slope (unit
// RMS), z = height (unit RMS; kWaveHeightRatio times that is the height on the slope's
// scale), w = squared slope. Filtering averages the slope away with distance; w's mips
// keep the variance that was averaged away, which widens the sun glint instead of
// letting distant water shimmer.
constant float kWaveHeightRatio = 0.05;   // RMS height / RMS slope of the generated spectrum (about 1 / (2 pi k))
kernel void wave_texture_kernel(texture2d<float, access::write> out [[texture(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width();
    if (gid.x >= W || gid.y >= W) return;
    float2 p = (float2(gid) + 0.5) / float(W);
    float h = 0.0, norm = 0.0, hnorm = 0.0;
    float2 g = float2(0.0);
    for (int i = 0; i < 48; i++) {
        float2 r = hash22(float2(float(i) * 7.31 + 1.7, float(i) * 3.17 + 9.2));
        float ang = r.x * 6.2831853;
        float2 k = round(float2(cos(ang), sin(ang)) * mix(2.0, 10.0, r.y * r.y));
        if (all(k == 0.0)) k = float2(2.0, 1.0);
        float km = length(k);
        float amp = 1.0 / (km * km);   // height spectrum ~ k^-2: long waves carry the height
        float a = 6.2831853 * dot(k, p) + hash12(float2(float(i), 17.0)) * 6.2831853;
        h += amp * sin(a);
        g += amp * 6.2831853 * k * cos(a);
        float sk = amp * 6.2831853 * km;
        norm += 0.5 * sk * sk;
        hnorm += 0.5 * amp * amp;
    }
    g *= rsqrt(norm);
    h *= rsqrt(hnorm);
    out.write(float4(g, h, dot(g, g)), gid);
}

struct WaterWaves {
    float2 slope;      // surface slope along world x and z
    float height;      // blocks
    float variance;    // slope variance below the filter footprint
};

// Four octaves of the wave texture, each rotated and drifting along its own axis at a
// deep-water dispersion speed (longer waves travel faster). xz: world position;
// dX/dY: its screen derivatives (explicit, so snapped pixel-style positions filter right).
static WaterWaves waterWaves(constant AdvFrame& fr, texture2d<float> waveTex, sampler wrep,
                             float2 xz, float2 dX, float2 dY, float t) {
    const float tiles[4] = {2.3, 7.6, 21.0, 63.0};
    const float angles[4] = {0.0, 0.65, -1.07, 2.13};
    const float weights[4] = {0.45, 0.8, 1.0, 0.7};
    float size = max(WATER_WAVES.y, 0.05);
    WaterWaves w;
    w.slope = float2(0.0);
    w.height = 0.0;
    w.variance = 0.0;
    for (int i = 0; i < 4; i++) {
        float L = tiles[i] * size;
        float c = cos(angles[i]), s = sin(angles[i]);
        float2x2 toLocal = float2x2(float2(c, -s), float2(s, c));   // rotation by -angle
        float2 q = toLocal * xz;
        q.y += t * WATER_WAVES.z * 0.25 * sqrt(L);
        float4 smp = waveTex.sample(wrep, q / L, gradient2d(toLocal * dX / L, toLocal * dY / L));
        w.slope += float2(c * smp.x - s * smp.y, s * smp.x + c * smp.y) * weights[i];
        w.height += smp.z * kWaveHeightRatio * weights[i] * L;
        w.variance += max(smp.w - dot(smp.xy, smp.xy), 0.0) * weights[i] * weights[i];
    }
    float k = 0.072 * WATER_WAVES.x;
    w.slope *= k;
    w.height *= k;
    w.variance *= k * k;
    return w;
}

// Caustics where sunlight entered the water at world xz `p` and travelled d blocks: the
// waves' curvature (the divergence of their slope, from the two finer octaves) focuses the
// refracted light into bright lines or spreads it. 1 + 0.25 d lap is the change in the
// light's footprint (the refracted ray bends by about a quarter of the slope); intensity
// is its inverse. Fades with depth as the pattern blurs out.
static float waterCaustics(constant AdvFrame& fr, texture2d<float> waveTex, sampler wrep, float2 p, float2 dX, float2 dY, float d) {
    const float tiles[2] = {2.3, 7.6};
    const float angles[2] = {0.0, 0.65};
    const float weights[2] = {0.45, 0.8};
    const float e = 0.06;   // blocks
    float size = max(WATER_WAVES.y, 0.05), t = fr.params.x;
    float lap = 0.0;
    for (int i = 0; i < 2; i++) {
        float L = tiles[i] * size;
        float c = cos(angles[i]), s = sin(angles[i]);
        float2x2 toLocal = float2x2(float2(c, -s), float2(s, c));
        float2 q = toLocal * p;
        q.y += t * WATER_WAVES.z * 0.25 * sqrt(L);
        gradient2d gr = gradient2d(toLocal * dX / L, toLocal * dY / L);
        float gx1 = waveTex.sample(wrep, (q + float2(e, 0)) / L, gr).x, gx0 = waveTex.sample(wrep, (q - float2(e, 0)) / L, gr).x;
        float gy1 = waveTex.sample(wrep, (q + float2(0, e)) / L, gr).y, gy0 = waveTex.sample(wrep, (q - float2(0, e)) / L, gr).y;
        lap += (gx1 - gx0 + gy1 - gy0) / (2.0 * e) * weights[i];
    }
    lap *= 0.072 * WATER_WAVES.x;
    float I = 1.0 / max(1.0 + 0.25 * min(d, 8.0) * lap, 0.3);
    return mix(1.0, min(I, 3.0), saturate(WATER_COLOR.w * exp(-d / 16.0)));
}

// Screen-space ray march against the opaque depth: exponentially growing steps, then a
// binary search on the first crossing. Returns the hit uv (xy) and a confidence (z).
static float3 ssr(constant AdvFrame& fr, depth2d<float> depthTex, float3 eyePos, float3 rdView, float jitter) {
    float stepLen = (0.15 + length(eyePos) * 0.008) * (0.75 + 0.5 * jitter);
    float3 prev = eyePos, p = eyePos + rdView * stepLen;
    for (int i = 0; i < 30; i++) {
        float4 c = fr.proj * float4(p, 1.0);
        if (c.w <= 0.0) break;
        float2 ndc = c.xy / c.w;
        if (any(abs(ndc) > 1.0)) break;
        float2 fc = (ndc * 0.5 + 0.5) * fr.screen.xy;
        float sd = depthTex.read(uint2(fc));
        if (sd < 1.0) {
            float behind = eyeFromDepth(fr, fc, sd).z - p.z;   // > 0: the ray passed behind the surface
            if (behind > 0.0 && behind < stepLen * 2.0 + 0.25) {
                float3 a = prev, b = p;
                for (int j = 0; j < 6; j++) {
                    float3 m = (a + b) * 0.5;
                    float4 mc = fr.proj * float4(m, 1.0);
                    float2 mf = clamp((mc.xy / mc.w * 0.5 + 0.5) * fr.screen.xy, float2(0.5), fr.screen.xy - 0.5);
                    float md = depthTex.read(uint2(mf));
                    if (md < 1.0 && eyeFromDepth(fr, mf, md).z > m.z) b = m;
                    else a = m;
                }
                float4 bc = fr.proj * float4(b, 1.0);
                float2 bn = bc.xy / bc.w;
                float edge = saturate((1.0 - max(abs(bn.x), abs(bn.y))) * 6.0);
                return float3(bn * 0.5 + 0.5, edge);
            }
        }
        prev = p;
        stepLen *= 1.4;
        p += rdView * stepLen;
    }
    return float3(0.0);
}

// Sun glint: GGX with the sun as a disk of ~1.4 degrees radius (representative-point
// sphere light), soft-clamped so TAA and bloom never see fireflies. Returns radiance per
// unit sun colour.
static float sunGlint(float3 n, float3 v, float3 L, float alpha, float F0) {
    const float sinR = 0.024;
    float3 R = reflect(-v, n);
    float3 toRay = dot(L, R) * R - L;
    float3 Lp = normalize(L + toRay * saturate(sinR / max(length(toRay), 1e-5)));
    float3 h = normalize(Lp + v);
    float nh = saturate(dot(n, h)), nl = saturate(dot(n, Lp)), nv = max(dot(n, v), 1e-3), vh = saturate(dot(v, h));
    float a2 = alpha * alpha;
    float spread = alpha / saturate(alpha + 0.5 * sinR);   // energy kept as the disk widens the lobe
    float dd = nh * nh * (a2 - 1.0) + 1.0;
    float D = a2 / (3.14159 * dd * dd) * spread * spread;
    float k = alpha * 0.5;
    float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
    float F = F0 + (1.0 - F0) * pow(1.0 - vh, 5.0);
    float x = 3.14159 * D * G * F / (4.0 * nv);
    return x / (1.0 + x / 12.0);
}

fragment float4 water_fragment(WaterOut in [[stage_in]], bool front [[front_facing]],
                               constant AdvFrame& fr [[buffer(1)]],
                               texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]],
                               depth2d<float> shadowMap [[texture(4)]], sampler cmp [[sampler(1)]],
                               texture2d<float> skyLut [[texture(5)]], sampler lin [[sampler(2)]],
                               texture2d<float> sceneColor [[texture(6)]], depth2d<float> sceneDepth [[texture(7)]],
                               texture2d<float> waveTex [[texture(9)]], sampler wrep [[sampler(4)]],
                               texture2d<float> gLight [[texture(10)]],
                               instance_acceleration_structure tlas [[buffer(10), function_constant(ac_rt)]],
                               device const RtInstance* rtInst [[buffer(11), function_constant(ac_rt)]],
                               primitive_acceleration_structure entAs [[buffer(12), function_constant(ac_rt)]],
                               device const RtEntVertex* entV [[buffer(13), function_constant(ac_rt)]],
                               device const RtEntDraw* entD [[buffer(14), function_constant(ac_rt)]],
                               device const RtEntTex* entT [[buffer(15), function_constant(ac_rt)]],
                               sampler pointS [[sampler(3), function_constant(ac_rt)]],
                               texture2d<float> cloudMap [[texture(8)]]) {
    float4 t = atlas.sample(s, in.uv);
    float3 n = front ? in.normalView : -in.normalView;
    float3 v = normalize(-in.eye);
    float3 dirWorld = normalize((fr.invView * float4(-v, 0)).xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    bool sunUp = fr.sunDirView.w > 0.0;
    float3 lightDir = sunUp ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float3 Lw = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float ndl = saturate(dot(n, lightDir));
    float shadow = (fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, in.world, nWorld, ndl) : 1.0;
    float skyGate = smoothstep(0.35, 0.9, in.lm.y);
    float2 px = in.position.xy;
    uint2 ipx = uint2(px);

    if (in.material != 2 || !(fr.flags.x & ADV_WATER)) {
        // stained glass, ice, slime (and water with water effects off): lit translucent surface
        float3 albedo = toLinear(t.rgb * in.color.rgb);
        float3 c = albedo * (lightCol * ndl * shadow * skyGate + skyAmbient(fr, skyLut, lin, nWorld) * in.lm.y * in.lm.y +
                             fr.blockLight.rgb * pow(in.lm.x, fr.blockLight.a) * (1.0 - 0.75 * in.lm.y * in.lm.y * fr.sunDirWorld.w) + 0.004);
        return float4(c, t.a * in.color.a);
    }

    // ---- water ----
    uint wflags = uint(WATER_UNDER.z + 0.5);
    int style = int(WATER_WAVES.w + 0.5);
    float time = fr.params.x;
    float dist = length(in.eye);
    float2 xzRaw = in.world.xz + fr.camera.xz;
    float2 xz = style == 1 ? (floor(xzRaw * 16.0) + 0.5) / 16.0 : xzRaw;   // pixel style: one wave value per texel
    bool top = abs(nWorld.y) > 0.5;
    float3 up = float3(0, nWorld.y >= 0.0 ? 1.0 : -1.0, 0);
    WaterWaves wv = waterWaves(fr, waveTex, wrep, xz, dfdx(xzRaw), dfdy(xzRaw), time);
    float cosV = abs(dot(dirWorld, nWorld));
    float atten = mix(0.35, 1.0, saturate(cosV * 2.5));    // calmer at grazing angles: no horizon sparkle
    if (wflags & WF_CALM_INDOORS) atten *= mix(0.25, 1.0, smoothstep(0.55, 0.9, in.lm.y));
    if (style == 2 || !top) atten = 0.0;                   // vanilla texture style: a flat surface
    float2 slope = wv.slope * atten;
    float3 nw = top ? normalize(float3(-slope.x, 1.0, -slope.y)) * up.y : nWorld;
    float variance = wv.variance * atten * atten;

    // the water body's colour: user colour, optionally tinted by the biome (swamps)
    float3 waterCol = WATER_COLOR.rgb;
    if (wflags & WF_BIOME_TINT) waterCol *= toLinear(in.color.rgb) / max(toLinear(float3(1.0)), 1e-3);
    if (style == 2) waterCol = toLinear(t.rgb) * 0.35;
    float3 sigA = WATER_ABSORB.xyz;
    float3 sigT = sigA + WATER_ABSORB.w;
    float3 skyIn = skyAmbient(fr, skyLut, lin, float3(0, 1, 0)) * in.lm.y * in.lm.y;
    float3 inLight = skyIn + lightCol * shadow * skyGate * 0.6;

    // seen from below (vanilla draws the top face a second time, reversed): Snell's window
    // shows the refracted sky, outside it total internal reflection of the lit water
    if (nWorld.y < -0.5) {
        float3 inScat = underwaterInscatter(fr, skyLut, lin);
        float3 tr = refract(dirWorld, nw, 1.33);
        float3 c;
        if (dot(tr, tr) < 1e-6) {
            c = inScat * 1.2;
        } else {
            float cosI = saturate(dot(-dirWorld, nw));
            float fr0 = 0.02 + 0.98 * pow(1.0 - cosI, 5.0);
            float3 trn = normalize(tr);
            float3 skyC = skyRadiance(fr, skyLut, lin, trn, cloudMap) * skyGate;
            skyC += lightCol * pow(saturate(dot(trn, Lw)), 400.0) * 40.0 * shadow * skyGate;   // the sun through the surface
            c = mix(skyC, inScat * 1.2, fr0);
        }
        float f = underwaterFog(fr, dist);
        return float4(c * exp(-sigA * dist * 0.5) * (1.0 - f) + inScat * f, 1.0);
    }

    // opaque scene directly behind this pixel
    float sceneD0 = sceneDepth.read(ipx);
    float3 sceneEye0 = eyeFromDepth(fr, px, sceneD0);
    float thick0 = sceneD0 >= 1.0 ? 64.0 : max(length(sceneEye0) - dist, 0.0);

    // refraction: shift the lookup by the wave's tilt, a fixed world-space amount (fewer
    // pixels far away), fading in over the first block of depth (no halos at shores)
    float3 nvWave = normalize((fr.view * float4(nw, 0)).xyz);
    float3 nvFlat = normalize((fr.view * float4(nWorld, 0)).xyz);
    float pxPerBlock = fr.proj[1][1] * 0.5 * fr.screen.y / max(dist, 0.5);
    float2 edge = saturate(min(px, fr.screen.xy - px) / 48.0);
    float2 shift = (nvWave.xy - nvFlat.xy) * float2(1, -1) * WATER_SURFACE.z * 0.6 * pxPerBlock * saturate(thick0);
    shift = clamp(shift, float2(-48.0), float2(48.0)) * edge.x * edge.y;
    float2 refrPx = clamp(px + shift, float2(0.5), fr.screen.xy - 0.5);
    float sceneD = sceneDepth.read(uint2(refrPx));
    float3 sceneEye = eyeFromDepth(fr, refrPx, sceneD);
    if (sceneEye.z > in.eye.z || (sceneD >= 1.0 && sceneD0 < 1.0)) { refrPx = px; sceneD = sceneD0; sceneEye = sceneEye0; }
    float3 refr = sceneColor.read(uint2(refrPx)).rgb;
    float thickness = sceneD >= 1.0 ? 64.0 : max(length(sceneEye) - dist, 0.0);

    if (fr.flags.w != 0) return float4(refr, 1.0);   // debug views show through the water
    // the water column: absorption (red first) and light scattered back by the water itself
    float3 Tw = exp(-thickness * sigT);
    float3 below = refr * Tw + inLight * waterCol * (1.0 - Tw);

    // shoreline foam: lacy patches that are dense where terrain reaches the surface and
    // thin out to scattered bubbles over shallow ground (full-height surfaces only, so
    // flowing water's lower levels stay clear)
    float foam = 0.0;
    uint behind = uint(gLight.read(ipx).z * 255.0 + 0.5);   // material of the opaque pixel below
    if (top && WATER_SURFACE.w > 0.0 && behind != 7) {      // terrain makes foam, mobs swimming by do not
        float3 sceneWorld0 = (fr.invView * float4(sceneEye0, 1.0)).xyz;
        float depthBelow = sceneD0 >= 1.0 ? 64.0 : max(in.world.y - sceneWorld0.y, 0.0);
        float shore = saturate(1.0 - depthBelow / max(WATER_UNDER.w, 1e-3));
        float level = saturate((fract(in.world.y + fr.camera.y) - 0.7) * 10.0);
        if (shore * level > 0.0) {
            float n1 = waveTex.sample(wrep, (xz + float2(0.11, -0.07) * time) / 1.7).z;
            float n2 = waveTex.sample(wrep, (xz - float2(0.05, 0.09) * time) / 0.9).z;
            float pattern = saturate(0.5 + 0.18 * (n1 + 0.6 * n2));
            foam = smoothstep(1.0 - shore, 1.0 - shore + 0.1, pattern) * shore * level * min(WATER_SURFACE.w, 1.0) * 0.8;
        }
    }

    // reflection: direction from the wave normal, weight from the flat normal's Fresnel
    // (waves change what is reflected, not how much: no sparkle)
    float3 R = reflect(dirWorld, nw);
    if (R.y < 0.03) {
        // steep waves would reflect the underwater side: lean the normal back towards flat
        nw = normalize(mix(nw, up, saturate((0.03 - R.y) * 6.0)));
        R = reflect(dirWorld, nw);
        R = normalize(float3(R.x, max(R.y, 0.003), R.z));
    }
    float F0 = WATER_SURFACE.x;
    float fres = F0 + (1.0 - F0) * pow(1.0 - saturate(cosV), 5.0);
    fres *= 1.0 - foam;
    // the sky (no sun disk: the glint below is the sun's reflection); under cover, a dim
    // copy of the water's own colour instead of a sky it cannot see
    float skyVis = max(smoothstep(0.6, 0.95, in.lm.y), shadow * shadow * 0.3);
    float3 refl = mix(inLight * waterCol * 0.5, skyRadiance(fr, skyLut, lin, R, cloudMap, false), skyVis);
    float hitT = 0.0;   // reflected geometry blocks the sun glint
    float jitter = fract(hash12(px) + float(fr.flags.z % 64u) * 0.618034);
    if (ac_rt && (fr.flags.x & ADV_RT_REFL)) {
        // ray-traced reflection (off-screen geometry and entities included); skipped where
        // the Fresnel weight makes it invisible
        float3 o = in.world + fr.rtCam.xyz + nWorld * (0.02 + dist * 0.0005);
        RtHit rh;
        rh.hit = false;
        RtHit eh;
        eh.hit = false;
        if (fres > 0.02) {
            rh = rtClosest(tlas, rtInst, atlas, pointS, o, R, 320.0);
            if (fr.flags.x & ADV_RT_ENTITIES) eh = rtEntClosest(entAs, entV, entD, entT, o, R, rh.hit ? rh.t : 320.0);
        }
        if (eh.hit || rh.hit) {
            float3 hc = eh.hit ? rtEntShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, entV, entD, entT, eh, o, R, fres > 0.15)
                               : rtShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, rh, o, R, fres > 0.15);
            float hd = length((eh.hit ? eh.t : rh.t) * R + in.world);  // distance from the camera
            float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
            refl = mix(hc, skyBase(fr, skyLut, lin, R), hf * hf);
            hitT = 1.0;
        }
    } else if (fres > 0.02) {
        // screen-space: the march follows a normal 80% of the way to the waves (fewer broken hits)
        float3 Rs = reflect(dirWorld, normalize(mix(nWorld, nw, 0.8)));
        Rs.y = max(Rs.y, 0.003);
        float3 hit = ssr(fr, sceneDepth, in.eye + nvFlat * (0.02 + dist * 0.004), normalize((fr.view * float4(Rs, 0)).xyz), jitter);
        if (hit.z > 0.0) {
            refl = mix(refl, sceneColor.sample(lin, hit.xy).rgb, hit.z);
            hitT = hit.z;
        }
    }
    float3 c = mix(below, refl, fres);

    // the sun's reflection, widened by the wave detail filtering left unresolved
    if (fr.flags.y == 0 && WATER_SURFACE.y > 0.0) {
        float alpha = sqrt(0.0036 + 0.5 * variance);
        float g = sunGlint(nw, -dirWorld, Lw, alpha, 0.04);
        c += lightCol * g * WATER_SURFACE.y * shadow * skyGate * (1.0 - hitT) * (1.0 - foam) * (1.0 - 0.85 * fr.params.y);
    }

    // foam: an opaque, matte white cap lit like terrain
    if (foam > 0.0) {
        float3 foamAlbedo = float3(0.80, 0.86, 0.90) * max(WATER_SURFACE.w, 1.0);
        float3 lit = lightCol * saturate(dot(nWorld, Lw)) * shadow * skyGate + skyAmbient(fr, skyLut, lin, nWorld) * in.lm.y * in.lm.y +
                     fr.blockLight.rgb * pow(in.lm.x, fr.blockLight.a) * 0.5 + 0.004;
        c = mix(c, foamAlbedo * lit, foam);
    }

    float fogF = saturate((dist - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
    float haze = (1.0 - exp(-dist * (0.0012 + fr.params.y * 0.01) * SKY_TUNE.z)) * 0.6;
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
    float sigma = mix(0.0016, 0.006, fr.params.y) * (1.0 + 0.8 * (1.0 - smoothstep(0.05, 0.4, L.y))) * SKY_TUNE.z;
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

// Final grading of the tonemapped colour (user settings): saturation, contrast around
// mid grey, vignette; returns gamma-encoded output. advlight.h mirrors it.
static float3 grade(constant AdvFrame& fr, float3 c, float2 uv) {
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(mix(float3(luma), c, POST_TUNE.z), 0.0);
    float3 g = toGamma(c);
    g = saturate((g - 0.5) * POST_TUNE.w + 0.5);
    float2 q = uv - 0.5;
    return g * (1.0 - dot(q, q) * 0.35 * POST_TUNE.x);
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
        float3 amp = sqrt(saturate(min(mn, 1.0 - mxv) / max(mxv, 1e-4))) * POST_TUNE.y;   // sharpening setting
        float3 wgt = -amp / mix(8.0, 5.0, 0.55);
        c = saturate((c + (n + w_ + e + so) * wgt) / (1.0 + 4.0 * wgt));
    }
    return float4(grade(fr, c, in.uv), 1.0);
}
