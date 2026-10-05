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
#define GI_TUNE  fr.tune[15]  // x: global illumination (0 off, 1 world-space, 2 ray-traced), y: bounce strength, z: rays per texel
#define RT_SOFT  fr.tune[16].w   // the sun's angular radius for ray-traced shadows (radians, 0: hard)
#define RT_TUNE  fr.tune[17]  // x: reflection ray distance, y: AO radius, z: AO rays, w: GI ray distance (blocks)

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

// Stained glass, ice, slime and the like in light space (the glass shadow map) for coloured
// shadows: the nearest such surface towards the light (min-blended depth) and the light that
// passes all of them along that line (multiply-blended), so stacked panes mix their colours.
struct GlassShadowOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint material [[flat]];
};

struct GlassShadowTargets {
    float depth [[color(0)]];
    float4 transmit [[color(1)]];
};

vertex GlassShadowOut shadow_glass_vertex(uint vid [[vertex_id]],
                                          device const BlockVertex* verts [[buffer(0)]],
                                          constant AdvFrame& fr [[buffer(1)]],
                                          constant float4& sectionWorld [[buffer(4)]],
                                          device const uchar* materials [[buffer(5)]]) {
    BlockVertex v = verts[vid];
    ushort2 lmRaw = ushort2(v.lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    GlassShadowOut o;
    o.position = fr.shadowViewProj * float4(float3(v.pos) + sectionWorld.xyz, 1.0);
    o.uv = float2(v.uv);
    o.color = float4(v.color) * (1.0 / 255.0);
    o.material = materials[state];
    return o;
}

fragment GlassShadowTargets shadow_glass_fragment(GlassShadowOut in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                                  sampler s [[sampler(0)]]) {
    if (in.material == 2) discard_fragment();   // water has its own map
    float4 t = atlas.sample(s, in.uv, level(0)) * in.color;
    if (t.a < 0.02) discard_fragment();
    GlassShadowTargets o;
    o.depth = in.position.z;
    // coloured glass passes its own colour, saturated (it absorbs the rest), dark glass less of
    // everything; each face takes the square root, so a block (two faces) tints once
    float peak = max(max(t.r, t.g), max(t.b, 1e-3));
    float3 T = pow(t.rgb / peak, 1.5) * mix(1.0, peak, 0.6);
    o.transmit = float4(sqrt(mix(float3(1.0), T, saturate(t.a * 2.5))), 1.0);
    return o;
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

// Light reaching `world` (camera-relative) through tinted glass and the like (the glass shadow
// map): their colour if any lies between it and the sun, white otherwise.
static float3 glassTransmit(constant AdvFrame& fr, texture2d<float> glassDepth, texture2d<float> glassColor, float3 world) {
    if (!(fr.flags.x & ADV_GLASS_SHADOW)) return float3(1.0);
    float4 sc = fr.shadowViewProj * float4(world, 1.0);
    float2 uv = float2(sc.x * 0.5 + 0.5, 0.5 - sc.y * 0.5);
    if (any(uv < 0.0) || any(uv >= 1.0) || sc.z > 1.0) return float3(1.0);
    uint2 p = uint2(uv * float2(glassDepth.get_width(), glassDepth.get_height()));
    if (sc.z <= glassDepth.read(p).r + 0.1 / 512.0) return float3(1.0);   // in front of the glass (or on it)
    return glassColor.read(p).rgb;
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

// ---------------------------------------------------------------------------
// voxel volume for world-space reflections (voxels.mm): per block, where its texture is in
// the atlas, its tint and its light, written from the terrain sections' own quads

// ---------------------------------------------------------------------------
// voxel volume for world-space reflections (voxels.mm), built from the terrain quads
//
// vox (RGBA16Uint): xy: sprite origin (atlas texels), z: tint (RGB565, vertex colour without
// the face shade), w: kind (1 opaque, 2 cutout) | sky light << 2 | block light << 6 |
// (log2 sprite size - 2) << 10 | VOX_SHAPED | VOX_CROSS | VOX_PLUS.
// voxShape (RG32Uint, VOX_SHAPED and VOX_PLUS voxels), the block's shape in 1/8 block slices
// as two parts: x: the box around its faces that stay inside the cell (fence and wall posts):
// first slices x, y, z, last slices x, y, z (3 bits each) | present << 18 | the octants the
// other part fills (bit x + 2y + 4z) << 19; y: the box around its faces reaching the cell's
// sides (slabs, stairs, rails, walls, panes): first x, z, last x, z (3 bits each) | the y
// slices it fills << 12 (rails keep their gaps) | present << 20. Plants drawn as diagonal
// crossed planes (VOX_CROSS) and cutouts drawn as planes crossing through the centre
// (VOX_PLUS: torches, lone panes and bars, crops) are traced as those planes.
//
// Per section: voxel_accum_kernel gathers what each block's quads cover into scratch,
// voxel_resolve_kernel turns that into voxels (and clears the scratch), voxel_occ_kernel
// marks the 4-block bricks holding anything.

#define VOX_SHAPED (1u << 13)
#define VOX_CROSS  (1u << 14)
#define VOX_PLUS   (1u << 15)

struct VoxResolveArgs {
    int4 slot;     // xyz: the section's slot origin in texels
    float4 atlas;  // xy: atlas size in texels
    uint4 light;   // x: write light properties (coloured block light), y: clear the slot's spread light
};

// Light properties (coloured block light), RGBA8Uint per voxel: w: 0 lets light pass, 1 solid,
// 2 filters it by rgb (stained glass), 3 gives light of rgb (colour times level / 15).
static inline uint4 voxLightOfState(device const uchar4* lightColors, uint state, uint fallback) {
    uchar4 lc = lightColors[state];
    if (lc.a == 0) return uint4(0u, 0u, 0u, fallback);
    return uint4(uint3(float3(lc.rgb) * (float(lc.a) / 255.0) + 0.5), 3u);
}

kernel void voxel_accum_kernel(device const BlockVertex* verts [[buffer(0)]], constant uint2& info [[buffer(1)]],
                               device atomic_uint* scratch [[buffer(2)]], uint q [[thread_position_in_grid]]) {
    if (q >= info.x) return;   // info: quads, layer
    uint b = q * 4u;
    float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos), p3 = float3(verts[b + 3].pos);
    float3 nn = cross(p1 - p0, p2 - p0);
    if (dot(nn, nn) < 1e-12) return;
    float3 n = normalize(nn), an = abs(n);
    int3 cell = int3(floor((p0 + p1 + p2 + p3) * 0.25 - n * 0.02));   // the block the face belongs to
    if (any(cell < 0) || any(cell > 15)) return;
    device atomic_uint* s = scratch + ((uint(cell.z) * 16u + uint(cell.y)) * 16u + uint(cell.x)) * 4u;
    // the quad that textures the voxel: sides before tops and bottoms (reflections mostly
    // see sides), solid before cutout, larger before smaller (a pane's face, not its edge),
    // then the first drawn (a block's base texture before its overlays); kept as the
    // maximum of the complement, so 0 is none
    uint area = 255u - uint(saturate(length(nn)) * 255.0);
    uint key = (an.y > 0.5 ? 1u << 28 : 0u) | (info.y << 26) | (area << 18) | min(q, (1u << 18) - 1u);
    atomic_fetch_max_explicit(s + 2, ~key, memory_order_relaxed);
    if (an.y < 0.2 && an.x > 0.5 && an.z > 0.5) {   // a diagonal plane: plants
        atomic_fetch_or_explicit(s + 1, 1u << 24, memory_order_relaxed);
        return;
    }
    // what the face bounds, per axis, in 1/16 slices and in halves (along its own axis, the
    // slice behind it): their union over the block's faces is its shape
    float3 org = float3(cell);
    float3 lo = saturate(min(min(p0, p1), min(p2, p3)) - org), hi = saturate(max(max(p0, p1), max(p2, p3)) - org);
    // a cutout plane through the middle of the cell, across all of it (torches, panes and bars
    // standing alone, crops): with one across the other axis, the block is a plus of planes
    if (info.y > 0u && an.y < 0.01) {
        int k = an.x > 0.5 ? 0 : 2;
        if (lo[k] > 0.2 && lo[k] < 0.8 && hi[2 - k] - lo[2 - k] > 0.9) atomic_fetch_or_explicit(s + 1, k == 0 ? 1u << 25 : 1u << 26, memory_order_relaxed);
    }
    // the 1/8 slices it bounds per axis (along its own axis, the slice behind it), into the
    // part of the shape that reaches the cell's sides or the part inside it
    uint m[3], h[3];
    for (int k = 0; k < 3; k++) {
        if (hi[k] - lo[k] < 1e-3) {
            float c = lo[k] - n[k] / 32.0;
            m[k] = 1u << uint(clamp(floor(c * 8.0), 0.0, 7.0));
            h[k] = c < 0.5 ? 1u : 2u;
        } else {
            uint i0 = uint(clamp(floor(lo[k] * 8.0 + 0.01), 0.0, 7.0));
            uint i1 = uint(clamp(ceil(hi[k] * 8.0 - 0.01), float(i0 + 1u), 8.0));
            m[k] = ((1u << i1) - 1u) & ~((1u << i0) - 1u);
            h[k] = (lo[k] < 0.499 ? 1u : 0u) | (hi[k] > 0.501 ? 2u : 0u);
        }
    }
    uint mm = m[0] | (m[1] << 8) | (m[2] << 16);
    if (lo.x < 0.01 || hi.x > 0.99 || lo.z < 0.01 || hi.z > 0.99) {
        uint octs = 0u;
        for (uint k = 0; k < 8u; k++)
            if (((h[0] >> (k & 1u)) & (h[1] >> ((k >> 1) & 1u)) & (h[2] >> (k >> 2))) & 1u) octs |= 1u << k;
        atomic_fetch_or_explicit(s, octs << 24, memory_order_relaxed);
        atomic_fetch_or_explicit(s + 1, mm, memory_order_relaxed);
    } else {
        atomic_fetch_or_explicit(s, mm, memory_order_relaxed);
    }
}

kernel void voxel_resolve_kernel(device const BlockVertex* solid [[buffer(0)]], device const BlockVertex* mipped [[buffer(1)]],
                                 device const BlockVertex* cutout [[buffer(2)]], device uint4* scratch [[buffer(3)]],
                                 constant VoxResolveArgs& a [[buffer(4)]],
                                 constant uint* opaque [[buffer(5)]], device const uchar4* lightColors [[buffer(6)]],
                                 texture3d<ushort, access::write> vox [[texture(0)]], texture3d<uint, access::write> voxShape [[texture(1)]],
                                 texture3d<uint, access::write> props [[texture(2)]],
                                 texture3d<float, access::write> flood0 [[texture(3)]], texture3d<float, access::write> flood1 [[texture(4)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= 16u)) return;
    uint idx = (gid.z * 16u + gid.y) * 16u + gid.x;
    uint4 s = scratch[idx];
    scratch[idx] = uint4(0u);   // clean for the next section
    uint3 tc = uint3(a.slot.xyz) + gid;
    // coloured block light: solid blocks (buried ones too, from the chunk build) stop it
    uint bi = (gid.y << 8) | (gid.z << 4) | gid.x;
    uint solidBit = (opaque[bi >> 5] >> (bi & 31u)) & 1u;
    if (a.light.x != 0u && a.light.y != 0u) {
        flood0.write(float4(0.0), tc);
        flood1.write(float4(0.0), tc);
    }
    if (s.z == 0u) {
        vox.write(ushort4(0), tc);
        if (a.light.x != 0u) props.write(uint4(0u, 0u, 0u, solidBit), tc);
        return;
    }
    uint key = ~s.z, layer = (key >> 26) & 3u;
    device const BlockVertex* verts = layer == 0u ? solid : (layer == 1u ? mipped : cutout);
    uint b = (key & ((1u << 18) - 1u)) * 4u;
    if (a.light.x != 0u) {
        ushort2 lmRaw = ushort2(verts[b].lm);
        props.write(voxLightOfState(lightColors, uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8), solidBit), tc);
    }
    float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos), p3 = float3(verts[b + 3].pos);
    float3 n = normalize(cross(p1 - p0, p2 - p0)), an = abs(n);
    // the sprite: its size from how much texture the quad spans over how much face (a torch
    // or a slab side spans part of its sprite), its origin on that grid
    float2 t0 = float2(verts[b].uv), t1 = float2(verts[b + 1].uv), t2 = float2(verts[b + 2].uv), t3 = float2(verts[b + 3].uv);
    float2 tlo = min(min(t0, t1), min(t2, t3)) * a.atlas.xy, text = max(max(t0, t1), max(t2, t3)) * a.atlas.xy - tlo;
    float3 pext = max(max(p0, p1), max(p2, p3)) - min(min(p0, p1), min(p2, p3));
    float size = max(text.x, text.y);
    if (max3(an.x, an.y, an.z) > 0.999) {
        float2 f = an.y > 0.5 ? pext.xz : (an.z > 0.5 ? pext.xy : pext.zy);   // the face's extent along its u and v
        float2 r = text / max(f, 1e-3), rs = text / max(f.yx, 1e-3);          // as mapped, or rotated a quarter turn
        float2 rr = abs(r.x - r.y) <= abs(rs.x - rs.y) ? r : rs;
        size = f.x > 1e-3 && f.y > 1e-3 ? 0.5 * (rr.x + rr.y) : max(text.x / max(f.x, 1e-3), text.y / max(f.y, 1e-3));
    }
    size = exp2(clamp(round(log2(max(size, 4.0))), 2.0, 9.0));
    float2 origin = floor(tlo / size + 0.01) * size;
    uint lsize = uint(log2(size)) - 2u;
    float4 col = (float4(verts[b].color) + float4(verts[b + 1].color) + float4(verts[b + 2].color) + float4(verts[b + 3].color)) * (0.25 / 255.0);
    float3 tint = saturate(col.rgb / faceShade(n));
    uint rgb = (uint(tint.r * 31.0 + 0.5) << 11) | (uint(tint.g * 63.0 + 0.5) << 5) | uint(tint.b * 31.0 + 0.5);
    float2 lm = (float2(ushort2(verts[b].lm) & ushort2(0xFF)) + float2(ushort2(verts[b + 1].lm) & ushort2(0xFF)) +
                 float2(ushort2(verts[b + 2].lm) & ushort2(0xFF)) + float2(ushort2(verts[b + 3].lm) & ushort2(0xFF))) * (0.25 / 240.0);
    uint sky = uint(saturate(lm.y) * 15.0 + 0.5), blk = uint(saturate(lm.x) * 15.0 + 0.5);
    uint kind = layer == 0u ? 1u : 2u, flags = 0u;   // 1 opaque, 2 cutout (alpha-tested at hits)
    uint3 mA = uint3(s.x, s.x >> 8, s.x >> 16) & 0xFFu, mB = uint3(s.y, s.y >> 8, s.y >> 16) & 0xFFu;
    uint octs = s.x >> 24;
    bool hasA = all(mA != 0u), hasB = all(mB != 0u);
    if (hasA || hasB) {
        if (octs == 0u) octs = 0xFFu;
        bool plus = ((s.y >> 25) & 3u) == 3u;
        if (plus || !hasB || any(mB != 0xFFu) || octs != 0xFFu) {
            flags = plus ? VOX_PLUS : VOX_SHAPED;
            if (plus) kind = 2u;
            uint3 loA = hasA ? uint3(ctz(mA)) : uint3(0u), hiA = hasA ? uint3(31u) - uint3(clz(mA)) : uint3(0u);
            uint2 loB = hasB ? uint2(ctz(mB.x), ctz(mB.z)) : uint2(0u), hiB = hasB ? uint2(31u) - uint2(clz(mB.x), clz(mB.z)) : uint2(0u);
            uint r = loA.x | (loA.y << 3) | (loA.z << 6) | (hiA.x << 9) | (hiA.y << 12) | (hiA.z << 15) | (hasA ? 1u << 18 : 0u) | (octs << 19);
            uint g = loB.x | (loB.y << 3) | (hiB.x << 6) | (hiB.y << 9) | ((hasB ? mB.y : 0u) << 12) | (hasB ? 1u << 20 : 0u);
            voxShape.write(uint4(r, g, 0u, 0u), tc);
        }
    } else if ((s.y >> 24) & 1u) {
        flags = VOX_CROSS;
        kind = 2u;
    } else {
        vox.write(ushort4(0), tc);
        return;
    }
    vox.write(ushort4(ushort(origin.x + 0.5), ushort(origin.y + 0.5), ushort(rgb), ushort(kind | (sky << 2) | (blk << 6) | (lsize << 10) | flags)), tc);
}

struct VoxTintArgs {
    int4 slot;     // xyz: the section's slot origin in texels
    uint4 info;    // x: quads
};

// The translucent layer's part in coloured block light: stained glass, ice and the like
// filter light by their colour (as they colour shadows), portals give purple light; water
// lets it pass.
kernel void voxel_tint_kernel(device const BlockVertex* verts [[buffer(0)]], device const uchar4* lightColors [[buffer(2)]],
                              device const uchar* materials [[buffer(3)]], constant VoxTintArgs& a [[buffer(4)]],
                              texture3d<uint, access::write> props [[texture(0)]], texture2d<float> atlas [[texture(1)]],
                              uint q [[thread_position_in_grid]]) {
    if (q >= a.info.x) return;
    uint b = q * 4u;
    float3 p0 = float3(verts[b].pos), p1 = float3(verts[b + 1].pos), p2 = float3(verts[b + 2].pos), p3 = float3(verts[b + 3].pos);
    float3 nn = cross(p1 - p0, p2 - p0);
    if (dot(nn, nn) < 1e-12) return;
    float3 n = normalize(nn);
    int3 cell = int3(floor((p0 + p1 + p2 + p3) * 0.25 - n * 0.02));
    if (any(cell < 0) || any(cell > 15)) return;
    uint3 tc = uint3(a.slot.xyz) + uint3(cell);
    ushort2 lmRaw = ushort2(verts[b].lm);
    uint state = uint(lmRaw.x >> 8) | (uint(lmRaw.y >> 8) << 8);
    if (lightColors[state].a != 0) {
        props.write(voxLightOfState(lightColors, state, 0u), tc);
        return;
    }
    if (materials[state] == 2) return;   // water
    constexpr sampler avg(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(verts[b].uv) + float2(verts[b + 2].uv)) * 0.5;   // the face's middle, coarse mip: its average
    float4 col = float4(verts[b].color) * (1.0 / 255.0);
    col.rgb /= faceShade(n);
    float4 t = atlas.sample(avg, uv, level(4.0)) * col;
    if (t.a < 0.02) return;
    float peak = max(max(t.r, t.g), max(t.b, 1e-3));
    float3 T = mix(float3(1.0), pow(t.rgb / peak, 1.5) * mix(1.0, peak, 0.6), saturate(t.a * 2.5));
    props.write(uint4(uint3(saturate(T) * 255.0 + 0.5), 2u), tc);
}

struct FloodArgs {
    int4 wrap;     // xyz: volume origin mod N, w: N
    int4 origin;   // xyz: the slot's corner in the volume (blocks), w: 1 to clear it instead
};

// One step of coloured block light spreading through the volume: as vanilla's light levels
// do, each block takes its brightest neighbour's light less a level (per channel); solid
// blocks stop it, filters colour it, lights give their own.
kernel void light_flood_kernel(texture3d<uint, access::read> props [[texture(0)]], texture3d<float, access::read> src [[texture(1)]],
                               texture3d<float, access::write> dst [[texture(2)]], constant FloodArgs& a [[buffer(0)]],
                               uint3 gid [[thread_position_in_grid]]) {
    int N = a.wrap.w;
    if (any(gid >= 16u)) return;
    uint3 c = uint3(a.origin.xyz) + gid;   // the block, in the volume
    uint m = uint(N - 1);
    uint3 wrap = uint3(a.wrap.xyz);
    uint3 tc = (c + wrap) & m;
    if (a.origin.w != 0) {
        dst.write(float4(0.0), tc);
        return;
    }
    uint4 p = props.read(tc);
    float3 L = float3(0.0);
    if (p.w != 1u) {
        float3 nb = float3(0.0);
        int3 ci = int3(c);
        for (int k = 0; k < 6; k++) {
            int3 o = ci;
            o[k >> 1] += (k & 1) ? 1 : -1;
            if (any(o < 0) || any(o >= N)) continue;   // outside the volume: nothing known
            nb = max(nb, src.read((uint3(o) + wrap) & m).rgb);
        }
        L = max(nb - 1.0 / 15.0, 0.0);
        if (p.w == 2u) L *= float3(p.xyz) * (1.0 / 255.0);
        else if (p.w == 3u) L = max(L, float3(p.xyz) * (1.0 / 255.0));
    }
    dst.write(float4(L, 1.0), tc);
}

// ---------------------------------------------------------------------------
// ray-traced block light: the lights of the voxel volume, binned by 8-block cell

// Every light-giving block of the volume into `lights` (volume coordinates), except those
// buried in solid blocks and other lights (the inside of a lava lake lights nothing).
kernel void light_list_kernel(texture3d<uint, access::read> props [[texture(0)]], constant int4& wrap [[buffer(0)]],
                              device atomic_uint* count [[buffer(1)]], device RtLight* lights [[buffer(2)]],
                              uint3 gid [[thread_position_in_grid]]) {
    int N = wrap.w;
    if (any(gid >= uint(N))) return;
    uint m = uint(N - 1);
    uint3 w = uint3(wrap.xyz);
    uint4 p = props.read((gid + w) & m);
    if (p.w != 3u) return;
    float3 col = float3(p.xyz) * (1.0 / 255.0);
    float level = max(col.r, max(col.g, col.b)) * 15.0;
    if (level < 0.5) return;
    bool open = false;
    for (int k = 0; k < 6 && !open; k++) {
        int3 o = int3(gid);
        o[k >> 1] += (k & 1) ? 1 : -1;
        if (any(o < 0) || any(o >= N)) { open = true; break; }
        uint ow = props.read((uint3(o) + w) & m).w;
        open = ow == 0u || ow == 2u;
    }
    if (!open) return;
    uint i = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    if (i >= RT_LIGHT_CAP) return;
    RtLight L;
    L.pos = float4(float3(gid) + 0.5, 0.0);
    L.color = float4(col, level);
    lights[i] = L;
}

// Per cell: the lights that can reach it (vanilla's reach: level - distance > 0), the
// strongest at its centre first. grid[cell * (RT_LIGHTS_PER_CELL + 1)] holds the count.
kernel void light_grid_kernel(device const RtLight* lights [[buffer(0)]], device atomic_uint* count [[buffer(1)]],
                              device uint* grid [[buffer(2)]], uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint(RT_LIGHT_CELLS))) return;
    float3 lo = float3(gid) * float(RT_LIGHT_CELL), hi = lo + float(RT_LIGHT_CELL), ctr = lo + float(RT_LIGHT_CELL) * 0.5;
    uint n = min(atomic_load_explicit(count, memory_order_relaxed), uint(RT_LIGHT_CAP));
    uint ids[RT_LIGHTS_PER_CELL];
    float sc[RT_LIGHTS_PER_CELL];
    uint k = 0;
    for (uint i = 0; i < n; i++) {
        RtLight L = lights[i];
        float reach = L.color.w;
        float3 q = clamp(L.pos.xyz, lo, hi);
        if (distance(q, L.pos.xyz) >= reach) continue;
        float dc = max(distance(ctr, L.pos.xyz) - float(RT_LIGHT_CELL) * 0.4, 0.0);
        float f = saturate((reach - dc) / 15.0);
        float s = dot(L.color.rgb, float3(0.2126, 0.7152, 0.0722)) / max(L.color.w, 1e-3) * f * f + 1e-6;
        if (k == RT_LIGHTS_PER_CELL && s <= sc[k - 1]) continue;
        int j = int(min(k, uint(RT_LIGHTS_PER_CELL - 1)));
        while (j > 0 && sc[j - 1] < s) {
            sc[j] = sc[j - 1];
            ids[j] = ids[j - 1];
            j--;
        }
        sc[j] = s;
        ids[j] = i;
        k = min(k + 1u, uint(RT_LIGHTS_PER_CELL));
    }
    uint base = ((gid.z * RT_LIGHT_CELLS + gid.y) * RT_LIGHT_CELLS + gid.x) * (RT_LIGHTS_PER_CELL + 1);
    grid[base] = k;
    for (uint i = 0; i < k; i++) grid[base + 1 + i] = ids[i];
}

// Which 4-block bricks of a slot hold any block, and whether the slot (16 blocks) does, so
// traces cross empty space a slot or a brick at a time. One threadgroup of 4^3 per slot.
kernel void voxel_occ_kernel(texture3d<ushort, access::read> vox [[texture(0)]], texture3d<ushort, access::write> occ [[texture(1)]],
                             texture3d<ushort, access::write> occSlot [[texture(2)]], constant int4& slot [[buffer(0)]],
                             uint3 gid [[thread_position_in_grid]], uint li [[thread_index_in_threadgroup]]) {
    threadgroup uint any4[64];
    uint3 base = uint3(slot.xyz) + gid * 4u;
    uint kinds = 0u;
    for (uint z = 0; z < 4u; z++)
        for (uint y = 0; y < 4u; y++)
            for (uint x = 0; x < 4u; x++) kinds |= uint(vox.read(base + uint3(x, y, z)).w);
    bool full = (kinds & 3u) != 0u;
    occ.write(ushort4(ushort(full)), base / 4u);
    any4[li] = full ? 1u : 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (li == 0u) {
        uint n = 0u;
        for (uint k = 0; k < 64u; k++) n |= any4[k];
        occSlot.write(ushort4(ushort(n)), uint3(slot.xyz) / 16u);
    }
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
    // rotating rays (AO Rays setting; TAA integrates them over frames, so without it twice as many)
    int rays = clamp(int(RT_TUNE.z + 0.5) * (fr.taa.w > 0.5 ? 1 : 2), 1, 16);
    float radius = RT_TUNE.y;
    float open = 0.0;
    float rot = hash12(in.position.xy) * 6.2831853 + float(fr.flags.z % 64u) * 2.399963;
    for (int i = 0; i < rays; i++) {
        float u = (float(i) + fract(hash12(in.position.yx + float(i)) + float(fr.flags.z % 16u) * 0.618034)) / float(rays);
        float r = sqrt(u), phi = rot + float(i) * 6.2831853 / float(rays);
        float3 dir = normalize(tx * (r * cos(phi)) + ty * (r * sin(phi)) + nWorld * sqrt(max(0.0, 1.0 - u)));
        bool occ = rtOccluded(tlas, rtInst, atlas, pointS, o, dir, radius);
        if (!occ && (fr.flags.x & ADV_RT_ENTITIES)) occ = rtEntOccludedSolid(entAs, o, dir, radius);
        open += occ ? 0.0 : 1.0;
    }
    return float4(open / float(rays), 1.0, 1.0, 1.0);
}

// ---------------------------------------------------------------------------
// ray-traced global illumination (one diffuse bounce, half resolution)

// One cosine-weighted GI ray (ray index `ray` decorrelates several per texel): rgb the
// radiance it brings back, a 1 if it reached the sky. With GI off (ray-traced sky light
// alone) it only asks whether the sky is visible that way.
static float4 giTraceRay(constant AdvFrame& fr, float2 px, int ray, float3 world, float3 eye, float3 nWorld, float3 tx, float3 ty,
                         texture2d<float> skyLut, instance_acceleration_structure tlas, device const RtInstance* rtInst,
                         primitive_acceleration_structure entAs, device const RtEntVertex* entV, device const RtEntDraw* entD,
                         device const RtEntTex* entT, device const uchar* emissions, texture2d<float> atlas, sampler pointS,
                         sampler lin) {
    float2 xi = hash22(px * 0.73 + float(fr.flags.z % 1024u) * float2(5.17, 11.3) + float(ray) * float2(1.37, 2.71));
    float r = sqrt(xi.x), phi = 6.2831853 * xi.y;
    float3 dir = normalize(tx * (r * cos(phi)) + ty * (r * sin(phi)) + nWorld * sqrt(max(0.0, 1.0 - xi.x)));
    float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
    // sky (no sun disc: direct sun is handled by the deferred pass)
    float3 skyC = (fr.flags.y != 0 ? toLinear(fr.fogColor.rgb) * 0.3 : skyBase(fr, skyLut, lin, dir)) * fr.ambient.a;
    if (GI_TUNE.x < 1.5) {
        bool occ = rtOccluded(tlas, rtInst, atlas, pointS, o, dir, RT_TUNE.w);
        if (!occ && (fr.flags.x & ADV_RT_ENTITIES)) occ = rtEntOccludedSolid(entAs, o, dir, RT_TUNE.w);
        return occ ? float4(0.0) : float4(skyC, 1.0);
    }
    RtHit h = rtClosest(tlas, rtInst, atlas, pointS, o, dir, RT_TUNE.w);
    if (fr.flags.x & ADV_RT_ENTITIES) {
        RtHit eh = rtEntClosestSolid(entAs, o, dir, h.t);
        if (eh.hit) return float4(rtEntShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, entV, entD, entT, eh, o, dir, true) * GI_TUNE.y, 0.0);
    }
    if (!h.hit) return float4(skyC, 1.0);
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
    // (no sun deep under cover, as in the lighting pass: no shadow ray needed there)
    float sunGate = smoothstep(0.35, 0.9, lm.y);
    if (ndl > 0.0 && sunGate > 0.0 && fr.flags.y == 0 && !rtOccluded(tlas, rtInst, atlas, pointS, p + n * 0.01, L, 128.0))
        c += lightCol * albedo * ndl * sunGate;
    c += albedo * skyAmbient(fr, skyLut, lin, n) * lm.y * lm.y * fr.ambient.a;
    c += albedo * fr.blockLight.rgb * pow(lm.x, fr.blockLight.a) * 0.5;
    c += albedo * float(emissions[state]) * (6.0 / 255.0);
    return float4(c * GI_TUNE.y, 0.0);
}

// Cosine-weighted rays per texel (GI quality); hits are shaded with sun (shadow ray), sky
// light and emission, misses see the sky. Output: rgb incoming indirect radiance
// (Lambert-normalised), a the share of rays that reached the sky (ray-traced sky light).
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
    float4 sum = float4(0.0);
    int rays = clamp(int(GI_TUNE.z + 0.5), 1, 4);
    for (int ray = 0; ray < rays; ray++)
        sum += giTraceRay(fr, in.position.xy, ray, world, eye, nWorld, tx, ty, skyLut, tlas, rtInst, entAs, entV, entD, entT, emissions, atlas, pointS, lin);
    return sum / float(rays);
}

// Temporal accumulation targets (GI, ray-traced block light): rgba, and depth with the count.
struct GiTemporalOut {
    float4 gi [[color(0)]];
    float2 z [[color(1)]];
};

// ---------------------------------------------------------------------------
// ray-traced block light (full resolution): each pixel weighs the lights of its 8-block cell
// by what they would give it unshadowed (vanilla's falloff curve, N.L, colour), picks two in
// proportion (resampled importance sampling over the whole cell list) and traces a shadow ray
// to a random point of each light's block: unbiased, soft-shadowed, averaged by TAA.
// Output: rgb the block light reaching the point (times fr.blockLight in the lighting pass),
// a 1, or a 0 outside the light volume (the lighting pass then uses the lightmap).
#define RTL_TUNE fr.tune[18]   // x: frame interpolation, y: ray-traced sky light, z: ray-traced block light, w: block light samples

fragment float4 blocklight_trace_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                          depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                          texture2d<float> gNormal [[texture(2)]],
                                          instance_acceleration_structure tlas [[buffer(10)]],
                                          device const RtInstance* rtInst [[buffer(11)]],
                                          primitive_acceleration_structure entAs [[buffer(12)]],
                                          device const RtLight* lights [[buffer(16)]],
                                          device const uint* grid [[buffer(17)]],
                                          texture3d<uint> props [[texture(3)]],
                                          texture2d<float> atlas [[texture(7)]], sampler pointS [[sampler(2)]]) {
    uint2 px = uint2(in.position.xy);
    if (depth.read(px) >= 1.0) return float4(0.0, 0.0, 0.0, 1.0);
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(px).r / -rd.z);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 nWorld = normalize((fr.invView * float4(normalize(gNormal.read(px).xyz), 0)).xyz);
    float3 vol = world + fr.voxCam.xyz + nWorld * 0.02;
    int3 cell = int3(floor(vol / float(RT_LIGHT_CELL)));
    if (any(cell < 0) || any(cell >= RT_LIGHT_CELLS)) return float4(0.0);
    uint base = ((uint(cell.z) * RT_LIGHT_CELLS + uint(cell.y)) * RT_LIGHT_CELLS + uint(cell.x)) * (RT_LIGHTS_PER_CELL + 1);
    uint k = min(grid[base], uint(RT_LIGHTS_PER_CELL));
    bool coloured = fr.tune[16].x > 0.5;   // coloured block light setting: lights keep their colour
    // the held light is one more candidate, at the hand (eye space: right, down, forward)
    bool hand = fr.post.z > 0.5;
    float3 handPos = fr.voxCam.xyz + (fr.invView * float4(0.25, -0.25, -0.3, 1.0)).xyz;
    uint kk = k + (hand ? 1u : 0u);
    float w[RT_LIGHTS_PER_CELL + 1];
    float3 cs[RT_LIGHTS_PER_CELL + 1];   // what each would give, unshadowed
    float wsum = 0.0;
    for (uint i = 0; i < kk; i++) {
        float3 pos, col;
        float level;
        if (i < k) {
            RtLight L = lights[grid[base + 1 + i]];
            pos = L.pos.xyz;
            level = L.color.w;
            col = coloured ? L.color.rgb / max(L.color.w / 15.0, 1e-3) : float3(1.0);
        } else {
            pos = handPos;
            level = fr.post.z;
            col = float3(1.0);
        }
        float3 dv = pos - vol;
        float d = length(dv);
        float fall = saturate((level - d) / 15.0);
        float geom = d > 0.05 ? saturate((dot(nWorld, dv / d) + 0.15) / 1.15) : 1.0;
        cs[i] = fall > 0.0 ? col * pow(fall, fr.blockLight.a) * geom : float3(0.0);
        w[i] = dot(cs[i], float3(0.2126, 0.7152, 0.0722));
        wsum += w[i];
    }
    if (wsum <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
    float3 toRt = fr.rtCam.xyz - fr.voxCam.xyz;   // volume coordinates -> ray tracing space
    int samples = clamp(int(RTL_TUNE.w + 0.5), 1, 4);
    float3 sum = float3(0.0);
    for (int s = 0; s < samples; s++) {
        float4 xi = float4(hash22(in.position.xy * 0.913 + float(fr.flags.z % 1024u) * float2(3.31, 7.17) + float(s) * float2(1.9, 4.3)),
                           hash22(in.position.yx * 1.137 + float(fr.flags.z % 1024u) * float2(5.73, 2.11) + float(s) * float2(6.1, 0.7)));
        float pick = xi.x * wsum;
        uint j = 0;
        for (; j + 1 < kk; j++) {
            pick -= w[j];
            if (pick < 0.0) break;
        }
        if (w[j] <= 0.0) continue;
        bool isHand = j >= k;
        float3 lpos = isHand ? handPos : lights[grid[base + 1 + j]].pos.xyz;
        // a random point of the light's block (of a small ball at the hand): soft shadows
        float3 target = lpos + (float3(xi.yzw) - 0.5) * (isHand ? 0.3 : 0.6) + toRt;
        float3 dv = target - o;
        float dist = length(dv);
        float tmax = dist - (isHand ? 0.35 : 0.9);   // stop short of the light's own block (the hand)
        bool vis = true;
        if (tmax > 0.0) {
            float3 dir = dv / dist;
            vis = !rtOccluded(tlas, rtInst, atlas, pointS, o, dir, tmax);
            // (not the player's own body for the held light)
            if (vis && !isHand && (fr.flags.x & ADV_RT_ENTITIES)) vis = !rtEntOccludedSolid(entAs, o, dir, tmax);
        }
        if (!vis) continue;
        // through stained glass and the like (not in the acceleration structures): their colour,
        // from the voxel volume's light properties along the way
        float3 T = float3(1.0);
        if (coloured) {
            float3 a = vol, b = lpos;
            float len = distance(a, b);
            int n = int(ceil(len * 2.0));
            int3 last = int3(floor(a)), lc = int3(floor(b));
            uint m = uint(fr.voxel.w - 1);
            for (int i = 1; i < n && i < 40; i++) {
                int3 cc = int3(floor(mix(a, b, float(i) / float(n))));
                if (all(cc == last) || all(cc == lc)) continue;
                last = cc;
                if (any(cc < 0) || any(cc >= fr.voxel.w)) continue;
                uint4 pr = props.read((uint3(cc) + uint3(fr.voxel.xyz)) & m);
                if (pr.w == 2u) T *= float3(pr.xyz) * (1.0 / 255.0);
            }
        }
        sum += T * cs[j] * (wsum / w[j]);
    }
    sum /= float(samples);
    if (!all(isfinite(sum))) sum = float3(0.0);   // a degenerate normal must not poison the history
    return float4(min(sum, float3(64.0)), 1.0);
}

// Temporal accumulation of the ray-traced block light (full resolution), as the GI's: last
// frame's history reprojected with the camera motion, disocclusions rejected by depth, up to
// `valid` frames (0: no history; fewer while a moving light, the held one, is lit).
fragment GiTemporalOut block_temporal_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                               constant float& valid [[buffer(0)]],
                                               texture2d<float> sample [[texture(0)]], texture2d<float> hist [[texture(1)]],
                                               texture2d<float> histZ [[texture(2)]], texture2d<float> gLinZ [[texture(3)]],
                                               depth2d<float> depth [[texture(4)]], sampler lin [[sampler(0)]]) {
    GiTemporalOut o;
    uint2 c = uint2(in.position.xy);
    float4 cur = sample.read(c);
    float z = gLinZ.read(c).r;
    o.z = float2(z, 1.0);
    o.gi = cur;
    if (valid < 0.5 || depth.read(c) >= 1.0) return o;
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 rel = (fr.invView * float4(rd * (z / -rd.z), 1.0)).xyz;
    float4 pc = fr.prevViewProj * float4(rel + fr.taa.xyz, 1.0);
    if (pc.w <= 0.0) return o;
    float2 puv = (pc.xy / pc.w) * 0.5 + 0.5;
    if (any(puv < 0.0) || any(puv > 1.0)) return o;
    uint2 ph = min(uint2(puv * float2(hist.get_width(), hist.get_height())), uint2(hist.get_width() - 1, hist.get_height() - 1));
    float2 pz = histZ.read(ph).rg;
    if (abs(pz.x - pc.w) > max(pc.w * 0.03, 0.05)) return o;   // disocclusion
    float4 h = hist.sample(lin, puv);
    if (!all(isfinite(h))) return o;
    float n = min(pz.y + 1.0, valid);
    o.gi = mix(h, cur, 1.0 / n);
    o.z = float2(z, n);
    return o;
}

// Separable depth/normal-aware blur of the ray-traced block light (full resolution, p.xy:
// direction, p.z: radius in pixels between taps).
fragment float4 blockblur_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                   texture2d<float> gNormal [[texture(2)]], constant float4& p [[buffer(0)]]) {
    int2 c = int2(in.position.xy);
    int2 mx = int2(src.get_width(), src.get_height()) - 1;
    float z0 = gLinZ.read(uint2(c)).r;
    float3 n0 = gNormal.read(uint2(c)).xyz;
    float4 sum = 0.0;
    float wsum = 0.0;
    for (int i = -4; i <= 4; i++) {
        int2 q = clamp(c + int2(p.xy * p.z) * i, int2(0), mx);
        float z = gLinZ.read(uint2(q)).r;
        float3 nq = gNormal.read(uint2(q)).xyz;
        float w = exp(-float(i * i) / 8.0) * exp(-abs(z - z0) / max(z0 * 0.02, 0.03)) * pow(saturate(dot(nq, n0)), 16.0);
        sum += src.read(uint2(q)) * w;
        wsum += w;
    }
    return sum / max(wsum, 1e-4);
}

// Temporal accumulation of the GI samples: reprojects last frame's history with the camera
// motion, rejects disocclusions by depth, and keeps up to 32 frames. rgba accumulate
// together (a: sky visibility); the depth target's second channel keeps the count.
fragment GiTemporalOut gi_temporal_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                            texture2d<float> sample [[texture(0)]], texture2d<float> hist [[texture(1)]],
                                            texture2d<float> histZ [[texture(2)]], texture2d<float> gLinZ [[texture(3)]],
                                            depth2d<float> depth [[texture(4)]], sampler lin [[sampler(0)]]) {
    GiTemporalOut o;
    uint2 c = uint2(in.position.xy);
    uint2 fp = min(c * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float4 cur = sample.read(c);
    float z = gLinZ.read(fp).r;
    o.z = float2(z, 1.0);
    o.gi = cur;
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
    float2 pz = histZ.read(ph).rg;
    if (abs(pz.x - pc.w) > max(pc.w * 0.04, 0.08)) return o;   // disocclusion
    float4 h = hist.sample(lin, puv);
    float n = min(pz.y + 1.0, 32.0);
    o.gi = mix(h, cur, 1.0 / n);
    o.z = float2(z, n);
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

// Separable depth/normal-aware blur of the half-resolution GI (rgb, and a: sky visibility), radius 6.
fragment float4 giblur_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                texture2d<float> src [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                texture2d<float> gNormal [[texture(2)]], constant float4& p [[buffer(0)]]) {
    int2 c = int2(in.position.xy);
    int2 mx = int2(src.get_width(), src.get_height()) - 1;
    uint2 fpc = min(uint2(c) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float z0 = gLinZ.read(fpc).r;
    float3 n0 = gNormal.read(fpc).xyz;
    float4 sum = 0.0;
    float wsum = 0.0;
    for (int i = -6; i <= 6; i++) {
        int2 q = clamp(c + int2(p.xy) * i, int2(0), mx);
        uint2 fq = min(uint2(q) * 2u + 1u, uint2(fr.screen.xy) - 1u);
        float z = gLinZ.read(fq).r;
        float3 nq = gNormal.read(fq).xyz;
        float w = exp(-float(i * i) / 18.0) * exp(-abs(z - z0) / max(z0 * 0.03, 0.05)) * pow(saturate(dot(nq, n0)), 16.0);
        sum += src.read(uint2(q)) * w;
        wsum += w;
    }
    return sum / max(wsum, 1e-4);
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
#define WF_RAIN_RIPPLES 4u
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

#define REFL_TUNE  fr.tune[12]   // x: reflections (0 off, 1 screen-space, 2 world-space), y: rough reflection limit
                                 // (roughness), z: rough reflection samples per frame, w: reflection strength
#define REFL_TUNE2 fr.tune[13]   // x: specular highlights, y: sky details (clouds, moon, stars) in reflections,
                                 // z: world-space reflection distance (blocks), w: water reflection distortion
#define WET_TUNE   fr.tune[14]   // x: rain wetness, y: puddles

constexpr sampler voxPoint(filter::nearest, mip_filter::linear, address::clamp_to_edge);

struct VoxHit {
    bool hit;
    float t;
    float3 n, p;   // face normal (world), hit point (voxel space)
    float2 uv;     // on the block's sprite
    uint4 v;
    float lod;     // atlas mip level for the ray's footprint there
    int steps;     // traversal steps taken (debug statistics)
};

// Sprite coordinates of a point on a block face (cell-local), as vanilla models map them.
static float2 voxFaceUv(float3 f, float3 n) {
    f = clamp(f, 0.0, 0.9999);
    float3 a = abs(n);
    if (a.y >= a.x && a.y >= a.z) return n.y > 0.0 ? f.xz : float2(f.x, 1.0 - f.z);
    if (a.z >= a.x) return float2(n.z > 0.0 ? f.x : 1.0 - f.x, 1.0 - f.y);
    return float2(n.x > 0.0 ? 1.0 - f.z : f.z, 1.0 - f.y);
}

static float2 voxAtlasUv(texture2d<float> atlas, uint4 v, float2 uv) {
    float size = exp2(float(((v.w >> 10) & 7u) + 2u));
    return (float2(v.xy) + min(uv, 0.9999) * size) / float2(atlas.get_width(), atlas.get_height());
}

// Atlas mip level for a face seen through a ray footprint `w` blocks wide: the texture
// would alias (and shimmer under TAA) at full resolution; grazing hits stretch it.
static float voxLod(uint4 v, float w, float3 n, float3 d) {
    float size = exp2(float(((v.w >> 10) & 7u) + 2u));
    return max(log2(w * size / max(abs(dot(n, d)), 0.3)), 0.0);
}

// Angle one pixel spans (radians): with the distance a ray has come, its footprint.
static inline float pixelAngle(constant AdvFrame& fr) { return 2.0 * fr.invProj[1][1] * fr.screen.w; }

// Keeps the nearer entry of a ray (o relative to the cell, inv = 1 / direction) into the box
// lo..hi, from tMin on.
static inline void voxBox(float3 lo, float3 hi, float3 o, float3 inv, float tMin, thread float& tHit, thread float3& nHit,
                          thread bool& found) {
    float3 t0 = (lo - o) * inv, t1 = (hi - o) * inv;
    float3 tn = min(t0, t1), tf = max(t0, t1);
    float te = max(max(tn.x, tn.y), tn.z), tx = min(min(tf.x, tf.y), tf.z);
    float tc = max(te, tMin);
    if (tc <= tx && tc < tHit) {
        tHit = tc;
        int ax = tn.x >= tn.y && tn.x >= tn.z ? 0 : (tn.y >= tn.z ? 1 : 2);
        nHit = float3(0.0);
        nHit[ax] = inv[ax] > 0.0 ? -1.0 : 1.0;
        found = true;
    }
}

// Where a ray enters a shaped block between tMin and tMax (voxShape: the inner box, and the
// box reaching the sides in its y slices and octants).
static bool voxShapeHit(uint2 sh, float3 o, float3 inv, float tMin, float tMax, thread float& tHit, thread float3& nHit) {
    bool found = false;
    tHit = tMax;
    if ((sh.x >> 18) & 1u)
        voxBox(float3(uint3(sh.x, sh.x >> 3, sh.x >> 6) & 7u) / 8.0, float3((uint3(sh.x >> 9, sh.x >> 12, sh.x >> 15) & 7u) + 1u) / 8.0,
               o, inv, tMin, tHit, nHit, found);
    if ((sh.y >> 20) & 1u) {
        float2 xr = float2(float(sh.y & 7u), float(((sh.y >> 6) & 7u) + 1u)) / 8.0;
        float2 zr = float2(float((sh.y >> 3) & 7u), float(((sh.y >> 9) & 7u) + 1u)) / 8.0;
        uint ym = (sh.y >> 12) & 0xFFu, octs = (sh.x >> 19) & 0xFFu;
        if (octs == 0xFFu) {
            while (ym != 0u) {   // each run of filled slices is a box (a fence's rails)
                uint l = ctz(ym), r = ctz(~(ym >> l));
                voxBox(float3(xr.x, float(l) / 8.0, zr.x), float3(xr.y, float(l + r) / 8.0, zr.y), o, inv, tMin, tHit, nHit, found);
                ym &= ~(((1u << r) - 1u) << l);
            }
        } else {
            float2 yr = float2(float(ctz(ym)), float(32u - clz(ym))) / 8.0;
            for (uint k = 0; k < 8u; k++) {   // stairs: the octants they fill
                if (((octs >> k) & 1u) == 0u) continue;
                float3 h = float3(uint3(k, k >> 1, k >> 2) & 1u) * 0.5;
                float3 lo = max(float3(xr.x, yr.x, zr.x), h), hi = min(float3(xr.y, yr.y, zr.y), h + 0.5);
                if (all(lo < hi)) voxBox(lo, hi, o, inv, tMin, tHit, nHit, found);
            }
        }
    }
    return found;
}

// Height range a shaped block spans (cutout planes run between them).
static float2 voxShapeHeight(uint2 sh) {
    float2 y = float2(1.0, 0.0);
    if ((sh.x >> 18) & 1u) y = float2(float((sh.x >> 3) & 7u), float(((sh.x >> 12) & 7u) + 1u)) / 8.0;
    uint ym = (sh.y >> 12) & 0xFFu;
    if (((sh.y >> 20) & 1u) && ym != 0u) y = float2(min(y.x, float(ctz(ym)) / 8.0), max(y.y, float(32u - clz(ym)) / 8.0));
    return y.x < y.y ? y : float2(0.0, 1.0);
}

// The nearest alpha-tested hit on a cell's two crossed planes (diagonal: a plant's, from
// 0.05 to 0.95 along them; otherwise through the centre across the cell, between heights
// yr). lo: the ray relative to the cell; o: in voxel space.
static bool voxPlanesHit(texture2d<float> atlas, uint4 v, bool diagonal, float3 o, float3 lo, float3 d, float3 inv,
                         float tMin, float tMax, float2 yr, float2 cone, thread VoxHit& h) {
    float2 tp;
    float3 nA, nB;
    if (diagonal) {
        tp = float2((lo.z - lo.x) / (d.x - d.z), (1.0 - lo.x - lo.z) / (d.x + d.z));
        nA = float3(0.70710678, 0.0, -0.70710678);
        nB = float3(0.70710678, 0.0, 0.70710678);
    } else {
        tp = float2((0.5 - lo.x) * inv.x, (0.5 - lo.z) * inv.z);
        nA = float3(1.0, 0.0, 0.0);
        nB = float3(0.0, 0.0, 1.0);
    }
    bool swapped = tp.y < tp.x;
    if (swapped) tp = tp.yx;
    for (int j = 0; j < 2; j++) {
        float tq = tp[j];
        if (!(tq >= tMin && tq <= tMax)) continue;
        float3 q = lo + d * tq;
        if (q.y < yr.x || q.y > yr.y) continue;
        float3 n = (j == 0) != swapped ? nA : nB;
        n = dot(n, d) > 0.0 ? -n : n;   // facing the ray
        float2 uv;
        if (diagonal) {
            if (q.x < 0.05 || q.x > 0.95) continue;
            uv = float2((q.x - 0.05) / 0.9, 1.0 - q.y);
        } else {
            if (any(q.xz < 0.0) || any(q.xz > 1.0)) continue;
            uv = voxFaceUv(q, n);
        }
        float lod = voxLod(v, cone.x + tq * cone.y, n, d);
        if (atlas.sample(voxPoint, voxAtlasUv(atlas, v, uv), level(lod)).a >= 0.1) {
            h.hit = true;
            h.t = tq;
            h.n = n;
            h.p = o + d * tq;
            h.uv = uv;
            h.v = v;
            h.lod = lod;
            return true;
        }
    }
    return false;
}

// Ray march through the voxel volume (voxel space: blocks from its min corner): empty
// 4-block bricks in one step, the others a block at a time. Cutouts (leaves, plants, glass,
// panes) are alpha-tested where hit; shaped blocks and plants are hit where their shape is.
// cone: the ray's footprint at o (blocks) and its growth per block.
static VoxHit voxTrace(constant AdvFrame& fr, texture3d<ushort> vox, texture3d<uint> voxShape, texture3d<ushort> occ,
                       texture3d<ushort> occSlot, texture2d<float> atlas, float3 o, float3 d, float tmax, float2 cone) {
    VoxHit h;
    h.hit = false;
    h.t = tmax;
    h.steps = 0;
    int N = fr.voxel.w;
    uint wrapMask = uint(N - 1);   // N is a power of two
    float3 inv = 1.0 / select(d, float3(1e-9), abs(d) < 1e-9);
    float3 ta = -o * inv, tb = (float3(float(N)) - o) * inv;
    float tEnter = max(max(max(min(ta.x, tb.x), min(ta.y, tb.y)), min(ta.z, tb.z)), 0.0);
    float tExit = min(min(min(max(ta.x, tb.x), max(ta.y, tb.y)), max(ta.z, tb.z)), tmax);
    if (tEnter >= tExit) return h;
    int3 cell = clamp(int3(floor(o + d * (tEnter + 1e-4))), int3(0), int3(N - 1));
    int3 st = int3(sign(d));
    float3 tDelta = abs(inv);
    float3 far01 = select(float3(0.0), float3(1.0), d > 0.0);
    float3 tNext = (float3(cell) + far01 - o) * inv;
    float t = tEnter;
    int axis = -1;
    int3 brick = int3(-1);
    bool brickFull = true;
    int i = 0;
    for (; i < 200; i++) {
        uint3 tc = (uint3(cell) + uint3(fr.voxel.xyz)) & wrapMask;
        int3 b = cell >> 2;
        if (any(b != brick)) {
            brick = b;
            // an empty 16-block slot is crossed whole, an empty 4-block brick likewise
            int size = 4;
            if (occSlot.read(tc >> 4).r == 0u) size = 16;
            else brickFull = occ.read(tc >> 2).r != 0u;
            if (size == 16 || !brickFull) {
                int3 lo = (cell / size) * size;
                float3 tf = (float3(lo) + far01 * float(size) - o) * inv;
                int ax = tf.x < tf.y && tf.x < tf.z ? 0 : (tf.y < tf.z ? 1 : 2);
                t = tf[ax];
                if (t >= tExit) break;
                int3 nc = clamp(int3(floor(o + d * t)), lo, lo + (size - 1));
                nc[ax] = st[ax] > 0 ? lo[ax] + size : lo[ax] - 1;
                cell = nc;
                axis = ax;
                tNext = (float3(cell) + far01 - o) * inv;
                brick = int3(-1);
                if (any(cell < 0) || any(cell >= N)) break;
                continue;
            }
        }
        uint4 v = uint4(vox.read(tc));
        uint kind = v.w & 3u;
        if (kind != 0u && axis >= 0) {
            float tOut = min(min(tNext.x, tNext.y), tNext.z);
            float3 lo = o - float3(cell);   // the ray relative to the cell
            if (v.w & (VOX_CROSS | VOX_PLUS)) {
                float2 yr = float2(0.0, 1.0);
                if (v.w & VOX_PLUS) yr = voxShapeHeight(voxShape.read(tc).rg);
                if (voxPlanesHit(atlas, v, (v.w & VOX_CROSS) != 0u, o, lo, d, inv, t, tOut, yr, cone, h)) {
                    h.steps = i + 1;
                    return h;
                }
            } else {
                float th = t;
                float3 n = float3(0.0);
                n[axis] = -float(st[axis]);
                if (!(v.w & VOX_SHAPED) || voxShapeHit(voxShape.read(tc).rg, lo, inv, t, tOut, th, n)) {
                    float2 uv = voxFaceUv(lo + d * th, n);
                    float lod = voxLod(v, cone.x + th * cone.y, n, d);
                    if (kind == 1u || atlas.sample(voxPoint, voxAtlasUv(atlas, v, uv), level(lod)).a >= 0.1) {
                        h.hit = true;
                        h.t = th;
                        h.n = n;
                        h.p = o + d * th;
                        h.uv = uv;
                        h.v = v;
                        h.lod = lod;
                        h.steps = i + 1;
                        return h;
                    }
                }
            }
        }
        if (tNext.x < tNext.y && tNext.x < tNext.z) { axis = 0; t = tNext.x; tNext.x += tDelta.x; cell.x += st.x; }
        else if (tNext.y < tNext.z) { axis = 1; t = tNext.y; tNext.y += tDelta.y; cell.y += st.y; }
        else { axis = 2; t = tNext.z; tNext.z += tDelta.z; cell.z += st.z; }
        if (t >= tExit || any(cell < 0) || any(cell >= N)) break;
    }
    h.steps = i + 1;
    return h;
}

// Coloured block light: the hue of the light spread through the voxel volume at `q` (voxel
// space): coloured lights, and stained glass it passed. Vanilla's light level still sets how
// bright block light is; where no coloured light is known, it is the standard colour.
static float3 blockLightTint(constant AdvFrame& fr, texture3d<float> light, float3 q) {
    if (!(fr.flags.x & ADV_COLORED_LIGHT)) return float3(1.0);
    float N = float(fr.voxel.w);
    if (any(q < 1.0) || any(q > N - 1.0)) return float3(1.0);
    constexpr sampler ls(filter::linear, address::repeat);
    float3 L = light.sample(ls, (q + float3(fr.voxel.xyz)) / N).rgb;
    float m = max(max(L.r, L.g), L.b);
    if (m < 1e-3) return float3(1.0);
    return mix(float3(1.0), L / m, saturate(m * 6.0));
}

// A voxel hit lit like the deferred pass: its texture and tint, sun with the shadow map,
// sky light and block light from the light it was built with.
static float3 voxShade(constant AdvFrame& fr, texture2d<float> atlas, depth2d<float> shadowMap, sampler cmp,
                       texture2d<float> skyLut, sampler lin, VoxHit h, texture2d<float> glassDepth, texture2d<float> glassColor,
                       texture3d<float> blockLightVol) {
    float4 tex = atlas.sample(voxPoint, voxAtlasUv(atlas, h.v, h.uv), level(h.lod));
    uint rgb = h.v.z;
    float3 tint = float3(float((rgb >> 11) & 31u) / 31.0, float((rgb >> 5) & 63u) / 63.0, float(rgb & 31u) / 31.0);
    float3 albedo = toLinear(tex.rgb * tint);
    float sky = float((h.v.w >> 2) & 15u) / 15.0, blk = float((h.v.w >> 6) & 15u) / 15.0;
    float3 n = h.n;
    bool sunUp = fr.sunDirWorld.w > 0.0;
    float3 L = sunUp ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = saturate(dot(n, L));
    float3 c = float3(0.0);
    if (ndl > 0.0 && fr.flags.y == 0) {
        float vis = (fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, h.p - fr.voxCam.xyz, n, ndl) : smoothstep(0.85, 1.0, sky);
        c += lightCol * albedo * ndl * smoothstep(0.35, 0.9, sky) * vis * glassTransmit(fr, glassDepth, glassColor, h.p - fr.voxCam.xyz + n * 0.02);
    }
    float daySky = sky * sky * fr.sunDirWorld.w;
    c += albedo * skyAmbient(fr, skyLut, lin, n) * sky * sky * fr.ambient.a;
    c += albedo * fr.blockLight.rgb * blockLightTint(fr, blockLightVol, h.p + h.n * 0.5) * pow(blk, fr.blockLight.a) * (1.0 - 0.75 * daySky);
    c += albedo * 0.004 * LIGHT_TUNE.x;
    return c;
}

// Global illumination without ray tracing (world-space): like gi_trace_fragment, cosine-
// weighted rays per texel at half resolution, but through the voxel volume, hits lit by
// voxShade. A ray that leaves the volume before its length is up is as open as the lightmap
// says; outside the volume, the sky light is the lightmap's as without GI.
fragment float4 gi_voxel_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                  depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                  texture2d<float> gNormal [[texture(2)]], texture2d<float> gLight [[texture(3)]],
                                  depth2d<float> shadowMap [[texture(4)]], texture2d<float> skyLut [[texture(5)]],
                                  texture2d<float> atlas [[texture(7)]],
                                  texture3d<ushort> vox [[texture(16)]], texture3d<ushort> voxOcc [[texture(18)]],
                                  texture3d<uint> voxShape [[texture(19)]], texture3d<ushort> voxOccSlot [[texture(20)]],
                                  texture2d<float> glassDepth [[texture(21)]], texture2d<float> glassColor [[texture(22)]],
                                  texture3d<float> blockLightVol [[texture(23)]],
                                  sampler cmp [[sampler(0)]], sampler lin [[sampler(1)]]) {
    uint2 fp = min(uint2(in.position.xy) * 2u + 1u, uint2(fr.screen.xy) - 1u);
    float d = depth.read(fp);
    if (d >= 1.0) return float4(0.0);
    float2 ndc = float2((float(fp.x) + 0.5) * fr.screen.z * 2.0 - 1.0, (float(fp.y) + 0.5) * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(fp).r / -rd.z);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 nWorld = normalize((fr.invView * float4(normalize(gNormal.read(fp).xyz), 0)).xyz);
    float sky = gLight.read(fp).y;
    float3 p = world + fr.voxCam.xyz + nWorld * 0.05;
    float N = float(fr.voxel.w);
    if (any(p < 1.0) || any(p > N - 1.0)) return float4(skyAmbient(fr, skyLut, lin, nWorld) * sky * sky * fr.ambient.a, 1.0);
    float3 up = abs(nWorld.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tx = normalize(cross(up, nWorld)), ty = cross(nWorld, tx);
    const float len = RT_TUNE.w;
    float3 sum = float3(0.0);
    int rays = clamp(int(GI_TUNE.z + 0.5), 1, 4);
    for (int ray = 0; ray < rays; ray++) {
        float2 xi = hash22(in.position.xy * 0.73 + float(fr.flags.z % 1024u) * float2(5.17, 11.3) + float(ray) * float2(1.37, 2.71));
        float r = sqrt(xi.x), phi = 6.2831853 * xi.y;
        float3 dir = normalize(tx * (r * cos(phi)) + ty * (r * sin(phi)) + nWorld * sqrt(max(0.0, 1.0 - xi.x)));
        // diffuse light needs no texture detail: a wide footprint picks coarse mips
        VoxHit h = voxTrace(fr, vox, voxShape, voxOcc, voxOccSlot, atlas, p, dir, len, float2(0.5, 0.1));
        if (h.hit) {
            sum += voxShade(fr, atlas, shadowMap, cmp, skyLut, lin, h, glassDepth, glassColor, blockLightVol) * GI_TUNE.y;
        } else {
            float3 skyC = (fr.flags.y != 0 ? toLinear(fr.fogColor.rgb) * 0.3 : skyBase(fr, skyLut, lin, dir)) * fr.ambient.a;
            float3 tf = (select(float3(0.0), float3(N), dir > 0.0) - p) / select(dir, float3(1e-9), abs(dir) < 1e-9);
            float leaves = min(min(tf.x, tf.y), tf.z);   // where the ray leaves the volume
            sum += leaves >= len ? skyC : skyC * sky * sky;
        }
    }
    return float4(sum / float(rays), 1.0);
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

// A G-buffer surface's material: LabPBR data when present, otherwise per-material defaults,
// and rain on what is open to the sky: exposed surfaces get wet (porous ones darken),
// puddles form on open ground. The light pass and the denoiser's guides share it.
struct Surface {
    float3 albedo;   // linear
    float3 F0;
    float metal;
    float rough;     // perceptual roughness (GGX alpha = rough^2)
};

static Surface surfaceAt(constant AdvFrame& fr, float4 alb, float4 spm, float rough, uint material, float skyLight,
                         float3 world, float3 nWorld, texture3d<float> cloudNoise, sampler rep) {
    Surface s;
    s.albedo = toLinear(alb.rgb);
    s.metal = 0.0;
    s.F0 = float3(0.04);
    s.rough = rough;
    if (spm.z > 0.5) {
        if (spm.x >= 229.5 / 255.0) { s.metal = 1.0; s.F0 = s.albedo; }
        else s.F0 = float3(spm.x);
    } else if (material == 4) {
        s.metal = 0.85;
        s.F0 = mix(float3(0.04), s.albedo, s.metal);
    }
    if (fr.params.y > 0.01 && WET_TUNE.x > 0.0 && fr.flags.y == 0 && !isFoliage(material) && material != 2 && material != 7) {
        float exposed = smoothstep(0.8, 0.97, skyLight);
        float up = smoothstep(0.6, 0.95, nWorld.y);
        float3 wa = world + fr.camera.xyz;
        float puddle = WET_TUNE.y > 0.5 ? up * smoothstep(0.45, 0.62, cloudNoise.sample(rep, float3(wa.xz / 80.0, 0.37)).g) : 0.0;
        float wet = saturate(fr.params.y * exposed * WET_TUNE.x);
        float porous = spm.z > 0.5 && spm.y < 0.26 ? spm.y * 4.0 : 0.6;
        s.albedo *= mix(1.0, 0.55, wet * porous * (1.0 - puddle * 0.5));
        s.rough = mix(s.rough, s.rough * 0.55, wet);
        s.rough = mix(s.rough, 0.03, wet * puddle);
        s.F0 = max(s.F0, float3(0.02 * wet));
    }
    return s;
}

// Split-sum environment BRDF (Lazarov's fit): reflectance scale and bias at a view angle.
static inline float2 envBrdf(float rough, float nv) {
    float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022), c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r4 = rough * c0 + c1;
    float a004 = min(r4.x * r4.x, exp2(-9.28 * nv)) * r4.x + r4.y;
    return float2(-1.04, 1.04) * a004 + r4.zw;
}

// The MetalFX denoiser's guides at render resolution (upscaling: Denoised): what each pixel's
// surface reflects diffusely and specularly, its world-space normal and roughness, and a mask
// where water and glass were drawn over the opaque scene (left as they are).
struct GuideOut {
    float4 diffuse [[color(0)]];
    float4 specular [[color(1)]];
    float4 normal [[color(2)]];
    float roughness [[color(3)]];
    float mask [[color(4)]];
};

fragment GuideOut fx_guides_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                     texture2d<float> gAlbedo [[texture(0)]], texture2d<float> gNormal [[texture(1)]],
                                     texture2d<float> gLight [[texture(2)]], depth2d<float> depth [[texture(3)]],
                                     texture2d<float> gLinZ [[texture(6)]], depth2d<float> opaqueDepth [[texture(7)]],
                                     texture3d<float> cloudNoise [[texture(9)]], texture2d<float> gSpec [[texture(10)]],
                                     sampler rep [[sampler(3)]]) {
    uint2 px = uint2(in.position.xy);
    GuideOut o;
    float d = depth.read(px);
    o.mask = d < opaqueDepth.read(px) - 1e-7 ? 1.0 : 0.0;   // translucent surfaces in front
    if (d >= 1.0) {
        o.diffuse = o.specular = float4(0.0);
        o.normal = float4(0.0, 1.0, 0.0, 0.0);
        o.roughness = 1.0;
        return o;
    }
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(px).r / -rd.z);
    float4 lgt = gLight.read(px);
    float3 n = normalize(gNormal.read(px).xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    Surface sf = surfaceAt(fr, gAlbedo.read(px), gSpec.read(px), lgt.w, uint(lgt.z * 255.0 + 0.5), lgt.y, world, nWorld, cloudNoise, rep);
    float2 env = envBrdf(sf.rough, saturate(dot(n, normalize(-eye))));
    o.diffuse = float4(sf.albedo * (1.0 - sf.metal), 1.0);
    o.specular = float4(saturate(sf.F0 * env.x + env.y), 1.0);
    o.normal = float4(nWorld, 0.0);
    o.roughness = sf.rough;
    return o;
}

// Ray-traced reflections of opaque surfaces, in their own pass (a fragment shader with ray
// tracing in it needs many more registers, which slowed all of the lighting): the same rays the
// lighting would trace (light_fragment), as the mean radiance of the samples that hit (rgb) and
// the share of samples that hit (a); the lighting fills the rest with the sky.
fragment float4 refl_trace_fragment(FullscreenOut in [[stage_in]],
                                    constant AdvFrame& fr [[buffer(1)]],
                                    texture2d<float> gAlbedo [[texture(0)]],
                                    texture2d<float> gNormal [[texture(1)]],
                                    texture2d<float> gLight [[texture(2)]],
                                    depth2d<float> depth [[texture(3)]],
                                    texture2d<float> skyLut [[texture(5)]],
                                    texture2d<float> gLinZ [[texture(6)]],
                                    texture3d<float> cloudNoise [[texture(9)]],
                                    texture2d<float> gSpec [[texture(10)]],
                                    sampler lin [[sampler(1)]], sampler rep [[sampler(3)]],
                                    instance_acceleration_structure tlas [[buffer(10)]],
                                    device const RtInstance* rtInst [[buffer(11)]],
                                    primitive_acceleration_structure entAs [[buffer(12)]],
                                    device const RtEntVertex* entV [[buffer(13)]],
                                    device const RtEntDraw* entD [[buffer(14)]],
                                    device const RtEntTex* entT [[buffer(15)]],
                                    texture2d<float> atlas [[texture(7)]],
                                    sampler pointS [[sampler(2)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    if (d >= 1.0) return float4(0.0);
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(px).r / -rd.z);
    float4 alb = gAlbedo.read(px);
    float4 nrm = gNormal.read(px);
    float4 lgt = gLight.read(px);
    float3 n = normalize(nrm.xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 v = normalize(-eye);
    uint material = uint(lgt.z * 255.0 + 0.5);
    Surface sf = surfaceAt(fr, alb, gSpec.read(px), lgt.w, material, lgt.y, world, nWorld, cloudNoise, rep);
    float rough = sf.rough;
    float lim = REFL_TUNE.y;
    float smoothW = 1.0 - smoothstep(lim * 0.3, max(lim, 1e-3), rough);
    if (smoothW <= 0.0) return float4(0.0);
    float3 R = reflect(-v, n);
    bool lobe = fr.taa.w > 0.5 && rough > 0.05;
    int samples = lobe ? clamp(int(REFL_TUNE.z + 0.5), 1, 4) : 1;
    float3 sum = float3(0.0);
    float hits = 0.0;
    for (int si = 0; si < samples; si++) {
        float3 Rr = R;
        if (lobe) {
            float2 xi = hash22(in.position.xy + float(fr.flags.z % 256u) * float2(17.13, 7.31) + float(si) * float2(3.71, 9.13));
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
        float3 o = world + fr.rtCam.xyz + nWorld * (0.01 + length(eye) * 0.0002);
        RtHit rh = rtClosest(tlas, rtInst, atlas, pointS, o, Rrw, RT_TUNE.x);
        RtHit eh;
        eh.hit = false;
        if (fr.flags.x & ADV_RT_ENTITIES) eh = rtEntClosest(entAs, entV, entD, entT, o, Rrw, rh.t);
        if (eh.hit || rh.hit) {
            float3 traced = eh.hit ? rtEntShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, entV, entD, entT, eh, o, Rrw, smoothW > 0.5)
                                   : rtShade(fr, tlas, rtInst, atlas, pointS, skyLut, lin, rh, o, Rrw, smoothW > 0.5);
            float hd = length(Rrw * (eh.hit ? eh.t : rh.t) + world);
            float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
            sum += mix(traced, skyBase(fr, skyLut, lin, Rrw), hf * hf);
            hits += 1.0;
        }
    }
    return float4(sum / float(samples), hits / float(samples));
}

// The lighting pass's rays, in their own pass (a ray-tracing variant of the lighting shader
// runs it all slower): r the sun's (or moon's) visibility, one ray per pixel and frame to a
// random point of a disc the sun's size (TAA averages the penumbra); g whether the camera
// sees the point (the held item's light).
fragment float4 sun_trace_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                   depth2d<float> depth [[texture(0)]], texture2d<float> gLinZ [[texture(1)]],
                                   texture2d<float> gNormal [[texture(2)]], texture2d<float> gLight [[texture(3)]],
                                   instance_acceleration_structure tlas [[buffer(10)]],
                                   device const RtInstance* rtInst [[buffer(11)]],
                                   texture2d<float> atlas [[texture(7)]], sampler pointS [[sampler(2)]]) {
    uint2 px = uint2(in.position.xy);
    if (depth.read(px) >= 1.0) return float4(1.0);
    float2 ndc = float2(in.position.x * fr.screen.z * 2.0 - 1.0, in.position.y * fr.screen.w * 2.0 - 1.0) - fr.jitter.xy;
    float4 pf = fr.invProj * float4(ndc, 1.0, 1.0);
    float3 rd = pf.xyz / pf.w;
    float3 eye = rd * (gLinZ.read(px).r / -rd.z);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 n = normalize(gNormal.read(px).xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float4 r = float4(1.0);
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    uint material = uint(gLight.read(px).z * 255.0 + 0.5);
    if ((dot(n, lightDir) > 0.0 || isFoliage(material)) && fr.flags.y == 0) {
        float3 Lw = fr.sunDirView.w > 0.0 ? fr.sunDirWorld.xyz : -fr.sunDirWorld.xyz;
        float3 nOff = dot(nWorld, Lw) >= 0.0 ? nWorld : -nWorld;
        float3 o = world + fr.rtCam.xyz + nOff * (0.004 + length(eye) * 0.0002);
        float3 Ls = Lw;
        if (RT_SOFT > 0.0 && (fr.flags.x & ADV_TAA)) {
            float2 xi = hash22(in.position.xy * 1.31 + float(fr.flags.z % 512u) * float2(3.17, 7.53));
            float rr = sqrt(xi.x) * tan(RT_SOFT), phi = 6.2831853 * xi.y;
            float3 a = normalize(cross(abs(Lw.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0), Lw)), b = cross(Lw, a);
            Ls = normalize(Lw + (a * cos(phi) + b * sin(phi)) * rr);
        }
        r.r = rtOccluded(tlas, rtInst, atlas, pointS, o, Ls, 320.0) ? 0.0 : 1.0;
    }
    float dcam = length(eye);
    if (fr.post.z > 0.5 && dcam > 1.0 && dcam < fr.post.z) {
        // towards the eye (world positions are relative to the view entity's feet, not the eye)
        float3 o = world + fr.rtCam.xyz + nWorld * 0.02;
        float3 toEye = normalize((fr.invView * float4(-eye, 0.0)).xyz);
        r.g = rtOccluded(tlas, rtInst, atlas, pointS, o, toEye, dcam - 0.8) ? 0.0 : 1.0;
    }
    return r;
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
                               texture3d<ushort> vox [[texture(16)]], texture2d<float> voxAtlas [[texture(17)]],
                               texture3d<ushort> voxOcc [[texture(18)]], texture3d<uint> voxShape [[texture(19)]],
                               texture3d<ushort> voxOccSlot [[texture(20)]],
                               device atomic_uint* voxStats [[buffer(21)]],
                               texture2d<float> glassDepth [[texture(21)]], texture2d<float> glassColor [[texture(22)]],
                               texture3d<float> blockLightVol [[texture(23)]],
                               texture2d<float> reflTex [[texture(24)]],
                               texture2d<float> blockRt [[texture(25)]],
                               texture2d<float> sunRt [[texture(26)]],
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
    if (fr.flags.w == 9u) {
        // debug: the voxel volume world-space reflections trace, seen from the camera
        if (!(fr.flags.x & ADV_WSR)) return float4(1.0, 0.0, 1.0, 1.0);
        // from the eye (camera-relative positions are relative to the view entity's feet)
        float3 eyeVox = fr.voxCam.xyz + (fr.invView * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        VoxHit vh = voxTrace(fr, vox, voxShape, voxOcc, voxOccSlot, voxAtlas, eyeVox, dirWorld, 128.0, float2(0.0, pixelAngle(fr)));
        return float4(vh.hit ? voxShade(fr, voxAtlas, shadowMap, cmp, skyLut, lin, vh, glassDepth, glassColor, blockLightVol) : skyBase(fr, skyLut, lin, dirWorld), 1.0);
    }
    if (d >= 1.0) {
        float3 sky = skyRadiance(fr, skyLut, lin, dirWorld, cloudMap);
        if (fr.fog.w > 1.5) sky = toLinear(fr.fogColor.rgb) * 2.0;
        else if (fr.fog.w > 0.5) sky = underwaterInscatter(fr, skyLut, lin);
        return float4(sky, 1.0);
    }

    float4 alb = gAlbedo.read(px);
    float4 nrm = gNormal.read(px);
    float4 lgt = gLight.read(px);
    float ao = alb.a;
    float3 n = normalize(nrm.xyz);
    float3 nWorld = normalize((fr.invView * float4(n, 0)).xyz);
    float3 world = (fr.invView * float4(eye, 1)).xyz;
    float3 v = normalize(-eye);
    uint material = uint(lgt.z * 255.0 + 0.5);
    float skyLight = lgt.y, blockL = lgt.x;
    Surface sf = surfaceAt(fr, alb, gSpec.read(px), lgt.w, material, skyLight, world, nWorld, cloudNoise, rep);
    float3 albedo = sf.albedo, F0 = sf.F0;
    float metal = sf.metal, rough = sf.rough;
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
    // light through stained glass on its way here takes its colour: all the sunlight, and the
    // sky light in part (glass towards the sun mostly means a glass roof or window overhead)
    float3 glassT = glassTransmit(fr, glassDepth, glassColor, world + nWorld * 0.02);
    waterSun *= glassT;
    float3 skyTint = mix(float3(1.0), glassT, 0.7);
    float3 color = float3(0);
    // GI (half resolution, denoised): rgb sky light and bounce, a the share of rays that saw
    // the sky, which ray-traced sky light uses instead of the lightmap's sky level
    float4 giS = (fr.flags.x & (ADV_RT_GI | ADV_WSGI)) ? giTex.sample(lin, in.uv) : float4(0.0);
    bool rtSky = (fr.flags.x & ADV_RT_SKY) && (fr.flags.x & ADV_RT_GI);
    float3 lightDir = fr.sunDirView.w > 0.0 ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = fr.sunDirView.w > 0.0 ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    bool foliage = isFoliage(material);
    float wrap = foliage ? 0.35 : 0.0; // foliage transmits some light
    float diffuse = saturate((ndl + wrap) / (1.0 + wrap));
    float rtShadow = 1.0;
    float sunVis = 0.0;   // the sun's visibility here (for the light scattered in water above)
    if ((diffuse > 0.0 || (foliage && fr.tune[5].x > 0.0)) && fr.flags.y == 0) {
        float shadow = 1.0;
        // shadow lookups offset towards the light (a backlit leaf must not shadow itself)
        float3 nShadow = ndl < 0.0 ? -nWorld : nWorld;
        if (fr.flags.x & ADV_RT_SHADOW) {
            // terrain: exact ray-traced shadows over the whole loaded world (traced in
            // sun_trace_fragment, its own pass); the shadow map then only holds dynamic
            // geometry (entities)
            rtShadow = sunRt.read(px).r;
            shadow = rtShadow;
            if (fr.flags.x & ADV_SHADOWS) shadow *= sampleShadow(fr, shadowMap, cmp, world, nShadow, abs(ndl));
        } else if (fr.flags.x & ADV_SHADOWS) shadow = sampleShadow(fr, shadowMap, cmp, world, nShadow, abs(ndl));
        // no direct light deep inside caves; under water the light path above decides instead
        float skyGate = waterPath > 0.0 ? 1.0 : rtSky ? smoothstep(0.0, 0.15, giS.a) : smoothstep(0.35, 0.9, skyLight);
        sunVis = shadow;
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
        color += lightCol * waterSun * (albedo * diffuse * (1.0 - F) * (1.0 - metal) + specular * nl * REFL_TUNE2.x) * shadow * skyGate;
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
        // reflected sky; below the horizon, a darkened horizon stands in for the ground. Smooth
        // surfaces show the clouds, moon and stars in it too (sky details setting)
        float3 envCol;
        if (fr.flags.y != 0) {
            envCol = toLinear(fr.fogColor.rgb) * 0.3;
        } else {
            float3 Rh = normalize(float3(Rw.x, max(Rw.y, 0.02), Rw.z));
            envCol = skyLut.sample(lin, lutUv(Rh), level(rough * 6.0)).rgb;
            if (REFL_TUNE2.y > 0.5 && rough < 0.25)
                envCol = mix(skyRadiance(fr, skyLut, lin, Rh, cloudMap, false), envCol, smoothstep(0.02, 0.25, rough));
        }
        envCol *= mix(1.0, 0.3, saturate(-Rw.y * 2.5));
        float3 skyVis = (rtSky ? saturate(giS.a) : skyLight * skyLight) * ao * fr.ambient.a * skyTint;
        if (fr.flags.x & (ADV_RT_GI | ADV_WSGI))
            color += albedo * (1.0 - metal) * giS.rgb * ao * skyTint;   // traced sky light + bounce
        else
            color += albedo * (1.0 - metal) * skyAmbient(fr, skyLut, lin, nWorld) * skyVis;
        // the glow of daylight scattered in the water above: only where daylight reaches (sky
        // light, or the sun through the water: the water shadow map sees cave pools under rock too)
        if (waterPath > 0.0)
            color += albedo * (1.0 - metal) * underwaterInscatter(fr, skyLut, lin) * exp(-WATER_ABSORB.xyz * waterPath * 0.5) * 0.6 * ao *
                     max(smoothstep(0.05, 0.4, skyLight), sunVis);
        // reflections off: no mirror image, but metals keep an even sheen of the sky light
        bool reflOn = REFL_TUNE.x > 0.5 || (fr.flags.x & ADV_RT_REFL);
        float3 refl = reflOn ? envCol * skyVis : skyAmbient(fr, skyLut, lin, nWorld) * skyVis;
        // surfaces smooth enough (rough reflections setting) reflect their surroundings, blurred
        // by their roughness (RT closest hit, or screen space into last frame's resolve with
        // world space behind it); rougher ones reflect only the sky
        float lim = REFL_TUNE.y;
        float smoothW = 1.0 - smoothstep(lim * 0.3, max(lim, 1e-3), rough);
        if (smoothW > 0.0 && reflOn) {
            // GGX samples of the lobe, TAA integrating them over frames: more per frame, less noise
            bool lobe = fr.taa.w > 0.5 && rough > 0.05;
            int samples = lobe ? clamp(int(REFL_TUNE.z + 0.5), 1, 4) : 1;
            float3 sum = float3(0.0);
            for (int si = 0; si < samples; si++) {
                float3 Rr = R;
                if (lobe) {
                    float2 xi = hash22(in.position.xy + float(fr.flags.z % 256u) * float2(17.13, 7.31) + float(si) * float2(3.71, 9.13));
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
                float3 traced = refl;   // the sky, where nothing is hit
                if (fr.flags.x & ADV_RT_REFL) {
                    // traced in refl_trace_fragment (its own pass: keeps this one light): the mean
                    // of the samples that hit something, and the share that did
                    float4 rt = reflTex.read(px);
                    traced = rt.rgb + (1.0 - rt.a) * refl;
                    sum += traced * float(samples);
                    break;
                } else if (REFL_TUNE.x > 0.5) {
                    float3 hit = float3(0.0);
                    if (fr.taa.w > 0.5)
                        hit = ssr(fr, depth, eye, Rr, fract(hash12(in.position.xy) + float(fr.flags.z % 64u) * 0.618034 + float(si) * 0.381966));
                    if (hit.z < 0.99 && (fr.flags.x & ADV_WSR)) {
                        VoxHit vh = voxTrace(fr, vox, voxShape, voxOcc, voxOccSlot, voxAtlas, world + fr.voxCam.xyz + nWorld * 0.03, Rrw, REFL_TUNE2.z,
                                             float2(length(eye), 1.0) * pixelAngle(fr));
                        if (fr.flags.w == 10u) {   // debug statistics: steps per ray (logged natively)
                            atomic_fetch_add_explicit(&voxStats[0], uint(vh.steps), memory_order_relaxed);
                            atomic_fetch_add_explicit(&voxStats[1], 1u, memory_order_relaxed);
                        }
                        if (vh.hit) {
                            traced = voxShade(fr, voxAtlas, shadowMap, cmp, skyLut, lin, vh, glassDepth, glassColor, blockLightVol);
                            float hd = length(Rrw * vh.t + world);
                            float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
                            traced = mix(traced, skyBase(fr, skyLut, lin, Rrw), hf * hf);
                        }
                    }
                    if (hit.z > 0.0) traced = mix(traced, history.sample(lin, hit.xy).rgb, hit.z);
                }
                sum += traced;
            }
            refl = mix(refl, sum / float(samples), smoothW);
        }
        color += refl * (F0 * env.x + env.y) * REFL_TUNE.w;
    }
    // dynamic light from the player's held item: vanilla falloff (one level per block);
    // ray-traced visibility when RT shadows are on, otherwise it passes walls like OptiFine's
    float handL = 0.0;
    if (fr.post.z > 0.5) {
        float dcam = length(eye);
        float lvl = saturate((fr.post.z - dcam) / 15.0);
        if (lvl > 0.0) {
            float vis = 1.0;
            if ((fr.flags.x & ADV_RT_SHADOW) && dcam > 1.0) vis = sunRt.read(px).g;
            handL = lvl * vis * (0.6 + 0.4 * saturate(dot(n, v)));
        }
    }
    // block light fades in daylight (vanilla's lightmap is closer to max(sky, block) than a sum)
    float daySky = (rtSky ? saturate(giS.a) : skyLight * skyLight) * fr.sunDirWorld.w;
    float4 rtb = (fr.flags.x & ADV_RT_BLOCK) ? blockRt.read(px) : float4(0.0);
    if (rtb.a > 0.5) {
        // ray traced (blocklight_trace_fragment): every light with its own shadows, the held
        // light included
        float3 bl = rtb.rgb;
        color += albedo * fr.blockLight.rgb * bl * ao * (1.0 - 0.75 * daySky);
        blockL = max(dot(rtb.rgb, float3(0.2126, 0.7152, 0.0722)), handL);   // (debug view 8)
    } else {
        blockL = max(blockL, handL);
        float3 blockTint = blockLightTint(fr, blockLightVol, world + fr.voxCam.xyz + nWorld * 0.5);
        color += albedo * fr.blockLight.rgb * blockTint * pow(blockL, fr.blockLight.a) * ao * (1.0 - 0.75 * daySky);
    }
    color += albedo * nrm.w * 6.0;
    color += albedo * 0.004 * LIGHT_TUNE.x * ao;
    if (int(fr.flags.y) == -1) color += albedo * 0.03; // Nether ambient
    if (int(fr.flags.y) == 1) color += albedo * float3(0.045, 0.038, 0.06); // the End's dim violet ambient

    // debug views: 1 no fog, 2 albedo, 3 normals, 4 white albedo lighting, 5 shadow term, 6 RT shadow,
    // 7 sunlight's path through water (yellow shallow, red deep), 8 lightmap (red sky, green block),
    // 9 (above) the voxel volume of world-space reflections; 10 renders normally and logs the
    // world-space reflection steps per ray; 12 the light let through stained glass; 13 traced
    // sky visibility (ray-traced sky light); 14 ray-traced block light
    uint dbg = fr.flags.w;
    if (dbg == 1) return float4(color, 1.0);
    if (dbg == 2) return float4(albedo, 1.0);
    if (dbg == 3) return float4(nWorld * 0.5 + 0.5, 1.0);
    if (dbg == 4) return float4(color / max(albedo, 0.02), 1.0);
    if (dbg == 5) return float4(float3((fr.flags.x & ADV_SHADOWS) ? sampleShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl)) : 1.0), 1.0);
    if (dbg == 6) return float4(float3(rtShadow), 1.0);
    if (dbg == 7) return float4(waterPath > 0.0 ? float3(1.0, 1.0 - saturate(waterPath / 16.0), 0.2) : float3(0.0), 1.0);
    if (dbg == 8) return float4(skyLight, blockL, 0.0, 1.0);    // G-buffer lightmap: red sky, green block
    if (dbg == 12) return float4(glassTransmit(fr, glassDepth, glassColor, world + nWorld * 0.02), 1.0);   // light through glass
    if (dbg == 13) return float4(float3(giS.a), 1.0);   // traced sky visibility (ray-traced sky light)
    if (dbg == 14) return float4(rtb.rgb * 0.5, 1.0);   // ray-traced block light

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

// Rain on the water: each cell of two jittered grids drops an expanding ring now and then.
// Returns the slope the rings add (a ring's height is a short damped wave around its radius).
static float2 rainRipples(float2 p, float t) {
    float2 slope = float2(0.0);
    for (int layer = 0; layer < 2; layer++) {
        float scale = layer == 0 ? 1.25 : 2.3;
        float2 q = p * scale + float2(float(layer) * 7.31, float(layer) * 3.17);
        float2 cell = floor(q), f = q - cell;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) {
                float2 c = float2(float(dx), float(dy));
                float2 h = hash22(cell + c + float(layer) * 19.0);
                float age = fract(t * (0.7 + 0.3 * h.y) + h.x * 7.0);   // 0 = the drop lands, 1 = gone
                float2 d = f - (c + 0.2 + 0.6 * h);
                float r = length(d);
                float x = (r - age * 0.85) * 28.0;                       // distance from the ring front
                float env = exp(-x * x * 0.08) * (1.0 - age) * (1.0 - age);
                float dh = -sin(x) * env;                                // d(height)/dr, up to scale
                slope += (r > 1e-4 ? d / r : float2(0.0)) * dh * scale;
            }
    }
    return slope * 0.12;
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
                               texture3d<ushort> vox [[texture(11)]], texture3d<ushort> voxOcc [[texture(12)]],
                               texture3d<uint> voxShape [[texture(13)]], texture3d<ushort> voxOccSlot [[texture(14)]],
                               texture2d<float> glassDepth [[texture(15)]], texture2d<float> glassColor [[texture(16)]],
                               texture3d<float> blockLightVol [[texture(17)]],
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
    lightCol *= glassTransmit(fr, glassDepth, glassColor, in.world + nWorld * 0.02);   // through stained glass
    float skyGate = smoothstep(0.35, 0.9, in.lm.y);
    float2 px = in.position.xy;
    uint2 ipx = uint2(px);

    if (in.material != 2 || !(fr.flags.x & ADV_WATER)) {
        // stained glass, ice, slime (and water with water effects off): lit translucent surface
        float3 albedo = toLinear(t.rgb * in.color.rgb);
        float3 c = albedo * (lightCol * ndl * shadow * skyGate + skyAmbient(fr, skyLut, lin, nWorld) * in.lm.y * in.lm.y +
                             fr.blockLight.rgb * blockLightTint(fr, blockLightVol, in.world + fr.voxCam.xyz + nWorld * 0.5) *
                             pow(in.lm.x, fr.blockLight.a) * (1.0 - 0.75 * in.lm.y * in.lm.y * fr.sunDirWorld.w) + 0.004);
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
    // flowing water: its surface slopes downhill along the flow; the waves drift with it
    float2 flow = top && length(nWorld.xz) > 0.01 ? normalize(nWorld.xz) * min(length(nWorld.xz) * 10.0, 2.0) : float2(0.0);
    WaterWaves wv = waterWaves(fr, waveTex, wrep, xz - flow * time, dfdx(xzRaw), dfdy(xzRaw), time);
    float cosV = abs(dot(dirWorld, nWorld));
    float atten = mix(0.35, 1.0, saturate(cosV * 2.5));    // calmer at grazing angles: no horizon sparkle
    if (wflags & WF_CALM_INDOORS) atten *= mix(0.25, 1.0, smoothstep(0.55, 0.9, in.lm.y));
    if (style == 2 || !top) atten = 0.0;                   // vanilla texture style: a flat surface
    float2 slope = wv.slope * atten;
    if ((wflags & WF_RAIN_RIPPLES) && top && fr.params.y > 0.01 && fr.fog.w < 0.5)
        slope += rainRipples(xzRaw, time) * fr.params.y * smoothstep(0.8, 0.97, in.lm.y) *
                 saturate(1.0 - dist / 48.0);   // fine detail: none far away
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

    if (fr.flags.w != 0 && fr.flags.w < 10u) return float4(refr, 1.0);   // debug views (1-9) show through the water
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
    // how far the waves bend what is reflected (reflection distortion setting)
    float3 nr = normalize(mix(nWorld, nw, REFL_TUNE2.w));
    R = reflect(dirWorld, nr);
    R = normalize(float3(R.x, max(R.y, 0.003), R.z));
    float F0 = WATER_SURFACE.x;
    float fres = F0 + (1.0 - F0) * pow(1.0 - saturate(cosV), 5.0);
    fres = saturate(fres * REFL_TUNE.w) * (1.0 - foam);
    bool reflOn = REFL_TUNE.x > 0.5 || (ac_rt && (fr.flags.x & ADV_RT_REFL));
    if (!reflOn) fres = 0.0;   // reflections off
    // the sky (no sun disk: the glint below is the sun's reflection); under cover, a dim
    // copy of the water's own colour instead of a sky it cannot see
    float skyVis = max(smoothstep(0.6, 0.95, in.lm.y), shadow * shadow * 0.3 * smoothstep(0.05, 0.4, in.lm.y));   // no sky in a cave
    float3 skyR = REFL_TUNE2.y > 0.5 ? skyRadiance(fr, skyLut, lin, R, cloudMap, false) : skyBase(fr, skyLut, lin, R);
    float3 refl = mix(inLight * waterCol * 0.5, skyR, skyVis);
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
            rh = rtClosest(tlas, rtInst, atlas, pointS, o, R, RT_TUNE.x);
            if (fr.flags.x & ADV_RT_ENTITIES) eh = rtEntClosest(entAs, entV, entD, entT, o, R, rh.hit ? rh.t : RT_TUNE.x);
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
        float3 Rs = normalize(reflect(dirWorld, normalize(mix(nWorld, nr, 0.8))));
        Rs.y = max(Rs.y, 0.003);
        float3 hit = ssr(fr, sceneDepth, in.eye + nvFlat * (0.02 + dist * 0.004), normalize((fr.view * float4(Rs, 0)).xyz), jitter);
        if (hit.z > 0.0) {
            refl = mix(refl, sceneColor.sample(lin, hit.xy).rgb, hit.z);
            hitT = hit.z;
        }
        if (hit.z < 0.99 && (fr.flags.x & ADV_WSR)) {
            // world space: off-screen terrain from the voxel volume where screen space has
            // nothing (along the screen-space ray, so the two agree where they meet)
            VoxHit vh = voxTrace(fr, vox, voxShape, voxOcc, voxOccSlot, atlas, in.world + fr.voxCam.xyz + nWorld * 0.02, Rs, REFL_TUNE2.z, float2(dist, 1.0) * pixelAngle(fr));
            if (vh.hit) {
                float3 hc = voxShade(fr, atlas, shadowMap, cmp, skyLut, lin, vh, glassDepth, glassColor, blockLightVol);
                float hd = length(vh.t * Rs + in.world);
                float hf = saturate((hd - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
                refl = mix(mix(hc, skyBase(fr, skyLut, lin, Rs), hf * hf), refl, hit.z);
                hitT = 1.0;
            }
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
                                    texture2d<float> glassDepth [[texture(4)]], texture2d<float> glassColor [[texture(5)]],
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
    float3 vis = float3(0.0);
    float T = 1.0;
    for (int i = 0; i < N; i++) {
        float3 pEye = dirEye * ((i + jit) * dt);
        float3 world = (fr.invView * float4(pEye, 1.0)).xyz;
        float4 sc = fr.shadowViewProj * float4(world, 1.0);
        float3 sn = sc.xyz / sc.w;
        float2 uv = float2(sn.x * 0.5 + 0.5, 0.5 - sn.y * 0.5);
        float v = (any(uv < 0.0) || any(uv > 1.0)) ? 1.0 : shadowMap.sample_compare(cmp, uv, sn.z - 0.0005);
        // light shafts through stained glass take its colour
        vis += v * glassTransmit(fr, glassDepth, glassColor, world) * T * dt;
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

// Motion vectors for MetalFX temporal upscaling: where each pixel's surface was last frame,
// in pixels (camera motion; the sky by direction only), without this frame's jitter (MetalFX
// takes the jitter on its own).
fragment float4 motion_fragment(FullscreenOut in [[stage_in]], constant AdvFrame& fr [[buffer(1)]],
                                depth2d<float> depth [[texture(0)]]) {
    float2 fc = in.position.xy;
    float d = depth.read(uint2(fc));
    float3 eye = eyeFromDepth(fr, fc, d >= 1.0 ? 0.9999999 : d);
    float3 rel = (fr.invView * float4(eye, 1.0)).xyz;
    float3 prevRel = d >= 1.0 ? normalize(rel) * 1e5 : rel + fr.taa.xyz;
    float4 pc = fr.prevViewProj * float4(prevRel, 1.0);
    if (pc.w <= 0.0) return float4(0.0);
    float2 cur = (fc * fr.screen.zw * 2.0 - 1.0) - fr.jitter.xy;
    return float4((pc.xy / pc.w - cur) * 0.5 * fr.screen.xy, 0.0, 0.0);
}

// Frame interpolation's UI layer (interp.mm): whatever was drawn over the captured world since
// it was finished (hand, particles, weather, HUD, menus), opaque, for MetalFX to lay over the
// generated frame unwarped; transparent where the frame still shows the world.
kernel void interp_ui_kernel(texture2d<float, access::read> finalFrame [[texture(0)]],
                             texture2d<float, access::read> world [[texture(1)]],
                             texture2d<float, access::write> ui [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    uint2 size = uint2(ui.get_width(), ui.get_height());
    if (any(p >= size)) return;
    float4 f = finalFrame.read(p);
    // the world texel this screen pixel shows (Minecraft scales its framebuffer with nearest filtering)
    uint2 ws = uint2(world.get_width(), world.get_height());
    uint2 q = min(uint2((float2(p) + 0.5) * float2(ws) / float2(size)), ws - 1u);
    bool drawn = any(abs(f.rgb - world.read(q).rgb) > 0.5 / 255.0);
    ui.write(drawn ? float4(f.rgb, 1.0) : float4(0.0), p);
}

// Minecraft's framebuffer depth from the scene's render-resolution depth (upscaling), for the
// hand, particles and weather vanilla draws afterwards.
struct DepthOut {
    float depth [[depth(any)]];
};

fragment DepthOut depth_upsample_fragment(FullscreenOut in [[stage_in]], depth2d<float> src [[texture(0)]]) {
    constexpr sampler pt(filter::nearest, address::clamp_to_edge);
    DepthOut o;
    o.depth = src.sample(pt, in.uv);
    return o;
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
    // under water: a slow, slight wobble of the whole image (Water: Underwater Distortion)
    bool wobble = fr.fog.w > 0.5 && fr.fog.w < 1.5 && fr.tune[4].y > 0.0;
    float3 c;
    if (wobble) {
        float t = fr.params.x;
        float2 o = float2(sin(in.uv.y * 23.0 + t * 1.9), cos(in.uv.x * 19.0 + t * 1.6)) * fr.tune[4].y * 1.5 /
                   float2(hdr.get_width(), hdr.get_height());
        c = aces((hdr.sample(s, in.uv + o).rgb + b) * exposure);
    } else {
        c = aces((hdr.read(uint2(px)).rgb + b) * exposure);
    }
    if ((fr.flags.x & ADV_TAA) && !wobble) {
        // contrast-adaptive sharpening (after AMD CAS) to restore texture detail TAA softens
        int2 mx = int2(hdr.get_width(), hdr.get_height()) - 1;   // the output resolution (fr.screen is the scene's when upscaling)
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
