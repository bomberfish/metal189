// metal189: shaders that reproduce OpenGL 1.x fixed-function results for
// captured vanilla draws (GUI, entities, particles, sky, ...).
#include "common.h"
#include "ff.h"
#include "advlight.h"

// Structural variants (pipeline specialisation).
constant bool fc_alphaTest [[function_constant(0)]];
constant bool fc_logicOp   [[function_constant(1)]];
constant bool fc_flat      [[function_constant(2)]];
constant bool fc_terrain   [[function_constant(3)]];  // per-section modelview in buffer(3)
constant bool fc_modulate  [[function_constant(4)]];  // every enabled unit uses GL_MODULATE
constant bool fc_advLit    [[function_constant(5)]];  // shaders mode: lit by the advanced pipeline (advlight.h)
constant bool fc_smooth = !fc_flat;

struct FFOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 colorSmooth [[function_constant(fc_smooth)]];
    float4 colorFlat [[flat, function_constant(fc_flat)]];
    float4 tex0;      // projective
    float2 tex1;
    float fogFactor;   // per-vertex fog factor (clamped), as GL implementations compute it
    float3 eyePos [[function_constant(fc_advLit)]];
    float3 eyeNormal [[function_constant(fc_advLit)]];   // zero when the format has no normal
    float lineDist;    // window-space distance from the segment start (ff_line_vertex), for stipple
    float lineFlag;    // 1 for fragments of expanded lines, 2 for antialiased (GL_LINE_SMOOTH) ones
    float lineAcross;  // smooth lines: signed distance from the line centre in pixels
    float lineHalf [[flat]];   // smooth lines: half the line width in pixels
};

// ---------------------------------------------------------------------------
// vertex pulling

static float readComponent(device const uchar* p, int type, int i) {
    switch (type) {
        case 0x1406: return ((device const float*)p)[i];                     // FLOAT
        case 0x1401: return float(p[i]);                                     // UNSIGNED_BYTE
        case 0x1400: return float(((device const char*)p)[i]);               // BYTE
        case 0x1402: return float(((device const short*)p)[i]);              // SHORT
        case 0x1403: return float(((device const ushort*)p)[i]);             // UNSIGNED_SHORT
        case 0x1404: return float(((device const int*)p)[i]);                // INT
        case 0x1405: return float(((device const uint*)p)[i]);               // UNSIGNED_INT
        default: return 0.0;
    }
}

static float normScale(int type) {
    switch (type) {
        case 0x1401: return 1.0 / 255.0;
        case 0x1400: return 1.0 / 127.0;
        case 0x1403: return 1.0 / 65535.0;
        case 0x1402: return 1.0 / 32767.0;
        default: return 1.0;
    }
}

static float4 fetch(device const uchar* v, int4 a, float4 def) {
    if (a.x < 0) return def;
    device const uchar* p = v + a.x;
    float4 r = def;
    float s = a.w != 0 ? normScale(a.y) : 1.0;
    r.x = readComponent(p, a.y, 0) * s;
    if (a.z > 1) r.y = readComponent(p, a.y, 1) * s;
    if (a.z > 2) r.z = readComponent(p, a.y, 2) * s;
    if (a.z > 3) r.w = readComponent(p, a.y, 3) * s;
    if (a.w != 0 && (a.y == 0x1400 || a.y == 0x1402)) r = max(r, float4(-1.0));
    return r;
}

// ---------------------------------------------------------------------------
// lighting (GL 1.x per-vertex, single-sided, no specular/attenuation)

static float4 lightVertex(constant FFUniforms& u, float4 color, float3 n, float3 eyePos) {
    uint f = u.flags.x;
    float4 matAmbient = float4(0.2, 0.2, 0.2, 1.0);
    float4 matDiffuse = float4(0.8, 0.8, 0.8, 1.0);
    if (f & FF_COLOR_MATERIAL) {
        matAmbient = color;
        if (!(f & FF_CM_AMBIENT_ONLY)) matDiffuse = color;
    }
    float3 c = matAmbient.rgb * u.lightModelAmbient.rgb;
    for (int i = 0; i < 2; i++) {
        if (!(f & (FF_LIGHT0 << i))) continue;
        float4 lp = u.lightPos[i];
        float3 L = lp.w == 0.0 ? normalize(lp.xyz) : normalize(lp.xyz - eyePos);
        float ndl = max(dot(n, L), 0.0);
        c += matAmbient.rgb * u.lightAmbient[i].rgb + ndl * matDiffuse.rgb * u.lightDiffuse[i].rgb;
    }
    return float4(saturate(c), saturate(matDiffuse.a));
}

// Fixed-function vertex processing of vertex `vid` (shared by points/lines/triangles
// and the wide-line expansion below). Returns GL clip space in `glClip` as well.
static FFOut ffProcess(uint vid, device const uchar* vbuf, constant VertexLayout& layout,
                       constant FFUniforms& u, constant DrawTransform& xf, thread float4& glClip) {
    device const uchar* v = vbuf + vid * layout.stride.x;
    float4 objPos = fetch(v, layout.pos, float4(0, 0, 0, 1));
    float4 color = fetch(v, layout.color, u.color);
    float4 t0 = fetch(v, layout.tex0, u.texCoord0);
    float4 t1 = fetch(v, layout.tex1, u.texCoord1);
    float3 nrm = fetch(v, layout.normal, float4(u.normal.xyz, 0)).xyz;

    float4 eye = xf.modelview * objPos;
    FFOut o;
    float4 clip = u.proj * eye;
    glClip = clip;
    if (u.flags.x & FF_FLIP_Y) clip.y = -clip.y;
    clip.z = 0.5 * (clip.z + clip.w); // GL [-1,1] depth to Metal [0,1]
    o.position = clip;
    o.pointSize = u.raster.x;
    o.lineDist = 0.0;
    o.lineFlag = 0.0;
    o.lineAcross = 0.0;
    o.lineHalf = 0.0;

    uint f = u.flags.x;
    if (fc_advLit) {
        // the advanced pipeline's lighting replaces GL's (applied per fragment)
        o.eyePos = eye.xyz;
        float3 n = float3x3(xf.normal0.xyz, xf.normal1.xyz, xf.normal2.xyz) * nrm;
        o.eyeNormal = layout.normal.x >= 0 && dot(n, n) > 1e-12 ? normalize(n) : float3(0);
        color = saturate(color);
    } else if (f & FF_LIGHTING) {
        float3 n = float3x3(xf.normal0.xyz, xf.normal1.xyz, xf.normal2.xyz) * nrm;
        if (f & FF_NORMALIZE) n = normalize(n);
        color = lightVertex(u, color, n, eye.xyz);
    } else {
        color = saturate(color);
    }
    if (fc_flat) o.colorFlat = color; else o.colorSmooth = color;

    if (f & (FF_TEXGEN_S | FF_TEXGEN_T | FF_TEXGEN_R | FF_TEXGEN_Q)) {
        uint modes = u.flags.y;
        for (int c = 0; c < 4; c++) {
            if (!(f & (FF_TEXGEN_S << c))) continue;
            float4 src = ((modes >> (c * 2)) & 3u) == 1u ? eye : objPos;
            t0[c] = dot(u.texGenPlane[c], src);
        }
    }
    o.tex0 = u.texMatrix0 * t0;
    float4 tc1 = u.texMatrix1 * t1;
    o.tex1 = tc1.xy / tc1.w;
    if (f & FF_FOG) {
        float dist = (f & FF_FOG_RADIAL) ? length(eye.xyz) : abs(eye.z);
        float ff;
        uint mode = u.flags.z;
        if (mode == 0) ff = (u.fogParams.y - dist) * u.fogParams.w;
        else if (mode == 1) ff = exp(-u.fogParams.z * dist);
        else { float d = u.fogParams.z * dist; ff = exp(-d * d); }
        o.fogFactor = saturate(ff);
    } else {
        o.fogFactor = 1.0;
    }
    return o;
}

vertex FFOut ff_vertex(uint vid [[vertex_id]],
                       device const uchar* vbuf [[buffer(0)]],
                       constant VertexLayout& layout [[buffer(1)]],
                       constant FFUniforms& u [[buffer(2)]],
                       constant DrawTransform& xf [[buffer(3)]]) {
    float4 glClip;
    return ffProcess(vid, vbuf, layout, u, xf, glClip);
}

// Wide lines (glLineWidth > 1): each segment becomes a quad of 6 vertices. Like GL's
// non-antialiased wide lines, the quad is widened along the line's minor axis in window
// space (x-major lines grow vertically), after clipping the segment against the near
// plane. seg holds the segment endpoint indices; lp = (viewport w, h, width px, 0).
// Flat shading takes GL's provoking vertex, the segment's second vertex.
vertex FFOut ff_line_vertex(uint vid [[vertex_id]],
                            device const uchar* vbuf [[buffer(0)]],
                            constant VertexLayout& layout [[buffer(1)]],
                            constant FFUniforms& u [[buffer(2)]],
                            constant DrawTransform& xf [[buffer(3)]],
                            device const uint* seg [[buffer(4)]],
                            constant float4& lp [[buffer(5)]]) {
    uint s = vid / 6u, c = vid % 6u;
    uint ia = seg[s * 2u], ib = seg[s * 2u + 1u];
    // quad corners q0 = A-, q1 = A+, q2 = B+, q3 = B-; triangles (q0 q1 q2) (q0 q2 q3)
    bool atB = c == 2u || c == 4u || c == 5u;
    float side = (c == 1u || c == 2u || c == 4u) ? 1.0 : -1.0;
    float4 pa, pb;
    FFOut o = ffProcess(atB ? ib : ia, vbuf, layout, u, xf, atB ? pb : pa);
    FFOut other = ffProcess(atB ? ia : ib, vbuf, layout, u, xf, atB ? pa : pb);
    if (fc_flat) o.colorFlat = atB ? o.colorFlat : other.colorFlat;
    // clip against the near plane (z + w >= 0 in GL clip space)
    float da = pa.z + pa.w, db = pb.z + pb.w;
    if (da < 0.0 && db < 0.0) { o.position = float4(0, 0, 2, 1); return o; }
    if (da < 0.0) pa = mix(pa, pb, da / (da - db));
    if (db < 0.0) pb = mix(pb, pa, db / (db - da));
    float2 dwin = (pb.xy / pb.w - pa.xy / pa.w) * lp.xy;
    float4 p = atB ? pb : pa;
    // GL's stipple counter advances one per pixel along the major axis (dwin is in half-pixels)
    o.lineDist = atB ? max(abs(dwin.x), abs(dwin.y)) * 0.5 : 0.0;
    o.lineFlag = 1.0;
    if (lp.w > 0.5) {
        // GL_LINE_SMOOTH: a rectangle of the exact width perpendicular to the segment, plus
        // a one-pixel fringe for the coverage falloff
        float2 dpx = dwin * 0.5;
        float len = length(dpx);
        float2 perp = len > 1e-6 ? float2(-dpx.y, dpx.x) / len : float2(0, 1);
        float halfW = lp.z * 0.5;
        float ext = max(halfW, 0.5) + 0.5;
        p.xy += side * perp * ext * 2.0 / lp.xy * p.w;
        o.lineFlag = 2.0;
        o.lineAcross = side * ext;
        o.lineHalf = halfW;
    } else if (abs(dwin.x) >= abs(dwin.y)) p.y += side * (lp.z / lp.y) * p.w;
    else p.x += side * (lp.z / lp.x) * p.w;
    if (u.flags.x & FF_FLIP_Y) p.y = -p.y;
    p.z = 0.5 * (p.z + p.w);
    o.position = p;
    return o;
}

// ---------------------------------------------------------------------------
// terrain: vanilla BLOCK vertices (pos 3f, colour 4ub, uv 2f, lightmap 2s)

struct BlockVertex {
    packed_float3 pos;
    uchar4 color;
    packed_float2 uv;
    packed_short2 lm;
};

vertex FFOut terrain_vertex(uint vid [[vertex_id]],
                            device const BlockVertex* verts [[buffer(0)]],
                            constant FFUniforms& u [[buffer(2)]],
                            constant float4x4& sectionMV [[buffer(3)]]) {
    BlockVertex v = verts[vid];
    float4 eye = sectionMV * float4(float3(v.pos), 1.0);
    FFOut o;
    float4 clip = u.proj * eye;
    if (u.flags.x & FF_FLIP_Y) clip.y = -clip.y;
    clip.z = 0.5 * (clip.z + clip.w);
    o.position = clip;
    o.pointSize = 1.0;
    float4 color = float4(v.color) * (1.0 / 255.0);
    if (fc_flat) o.colorFlat = color; else o.colorSmooth = color;
    o.tex0 = u.texMatrix0 * float4(float2(v.uv), 0.0, 1.0);
    // high bytes of the lightmap shorts carry the block state id (see Terrain.endBlock)
    float2 lm = float2(ushort2(v.lm) & ushort2(0xFF));
    float4 tc1 = u.texMatrix1 * float4(lm, 0.0, 1.0);
    o.tex1 = tc1.xy / tc1.w;
    uint f = u.flags.x;
    if (f & FF_FOG) {
        float dist = (f & FF_FOG_RADIAL) ? length(eye.xyz) : abs(eye.z);
        float ff;
        uint mode = u.flags.z;
        if (mode == 0) ff = (u.fogParams.y - dist) * u.fogParams.w;
        else if (mode == 1) ff = exp(-u.fogParams.z * dist);
        else { float d = u.fogParams.z * dist; ff = exp(-d * d); }
        o.fogFactor = saturate(ff);
    } else {
        o.fogFactor = 1.0;
    }
    return o;
}

// ---------------------------------------------------------------------------
// texture environment

static float3 operandRGB(float4 s, uint op) {
    switch (op) {
        case 0: return s.rgb;
        case 1: return 1.0 - s.rgb;
        case 2: return float3(s.a);
        default: return float3(1.0 - s.a);
    }
}

static float operandA(float4 s, uint op) { return (op & 1u) ? 1.0 - s.a : s.a; }

static float4 envSource(uint src, float4 texel, float4 primary, float4 prev, float4 constantColor,
                        thread const float4* texels) {
    switch (src) {
        case 0: return texel;
        case 1: return constantColor;
        case 2: return primary;
        case 3: return prev;
        default: return texels[min(src - 4u, 2u)];
    }
}

static float4 texEnv(uint4 env, float4 envScale, float4 texel, float4 primary, float4 prev, float4 constantColor,
                     thread const float4* texels) {
    switch (env.x) {
        case 0: return prev * texel;                                            // MODULATE
        case 1: return texel;                                                   // REPLACE
        case 2: return float4(mix(prev.rgb, texel.rgb, texel.a), prev.a);       // DECAL
        case 3: return float4(mix(prev.rgb, constantColor.rgb, texel.rgb), prev.a * texel.a); // BLEND
        case 4: return float4(saturate(prev.rgb + texel.rgb), prev.a * texel.a); // ADD
        default: break;                                                          // COMBINE
    }
    float4 s[3];
    for (int i = 0; i < 3; i++) {
        uint srcRGB = (env.z >> (i * 3)) & 7u;
        uint srcA = (env.z >> (9 + i * 3)) & 7u;
        float4 cs = envSource(srcRGB, texel, primary, prev, constantColor, texels);
        float4 as = envSource(srcA, texel, primary, prev, constantColor, texels);
        s[i] = float4(operandRGB(cs, (env.w >> (i * 2)) & 3u), operandA(as, (env.w >> (6 + i * 2)) & 3u));
    }
    float3 rgb;
    switch (env.y & 0xFFu) {
        case 0: rgb = s[0].rgb; break;
        case 1: rgb = s[0].rgb * s[1].rgb; break;
        case 2: rgb = s[0].rgb + s[1].rgb; break;
        case 3: rgb = s[0].rgb + s[1].rgb - 0.5; break;
        case 4: rgb = s[0].rgb * s[2].rgb + s[1].rgb * (1.0 - s[2].rgb); break;
        case 5: rgb = s[0].rgb - s[1].rgb; break;
        default: rgb = float3(4.0 * dot(s[0].rgb - 0.5, s[1].rgb - 0.5)); break;
    }
    float a;
    switch ((env.y >> 8) & 0xFFu) {
        case 0: a = s[0].a; break;
        case 1: a = s[0].a * s[1].a; break;
        case 2: a = s[0].a + s[1].a; break;
        case 3: a = s[0].a + s[1].a - 0.5; break;
        case 4: a = s[0].a * s[2].a + s[1].a * (1.0 - s[2].a); break;
        case 5: a = s[0].a - s[1].a; break;
        default: a = s[0].a; break;
    }
    return saturate(float4(rgb * envScale.x, a * envScale.y));
}

// GL converts both the fragment alpha and the reference to the colour buffer's
// fixed-point precision (8 bits) before comparing.
static bool alphaPass(uint func, float af, float reff) {
    float a = rint(saturate(af) * 255.0);
    float ref = rint(saturate(reff) * 255.0);
    switch (func) {
        case 0: return false;          // NEVER
        case 1: return a < ref;        // LESS
        case 2: return a == ref;       // EQUAL
        case 3: return a <= ref;       // LEQUAL
        case 4: return a > ref;        // GREATER
        case 5: return a != ref;       // NOTEQUAL
        case 6: return a >= ref;       // GEQUAL
        default: return true;          // ALWAYS
    }
}

// GL logic ops on 8-bit unsigned normalised values.
static float4 logicOp(uint op, float4 s, float4 d) {
    uint4 S = uint4(round(saturate(s) * 255.0));
    uint4 D = uint4(round(saturate(d) * 255.0));
    uint4 r;
    switch (op) {
        case 0x1500: r = 0; break;            // CLEAR
        case 0x1501: r = S & D; break;        // AND
        case 0x1502: r = S & ~D; break;       // AND_REVERSE
        case 0x1503: r = S; break;            // COPY
        case 0x1504: r = ~S & D; break;       // AND_INVERTED
        case 0x1505: r = D; break;            // NOOP
        case 0x1506: r = S ^ D; break;        // XOR
        case 0x1507: r = S | D; break;        // OR
        case 0x1508: r = ~(S | D); break;     // NOR
        case 0x1509: r = ~(S ^ D); break;     // EQUIV
        case 0x150A: r = ~D; break;           // INVERT
        case 0x150B: r = S | ~D; break;       // OR_REVERSE
        case 0x150C: r = ~S; break;           // COPY_INVERTED
        case 0x150D: r = ~S | D; break;       // OR_INVERTED
        case 0x150E: r = ~(S & D); break;     // NAND
        default: r = 255u; break;             // SET
    }
    return float4(r & 255u) / 255.0;
}

struct FFFragOut {
    float4 color [[color(0)]];
};

fragment FFFragOut ff_fragment(FFOut in [[stage_in]],
                               constant FFUniforms& u [[buffer(2)]],
                               texture2d<float> tex0 [[texture(0)]],
                               texture2d<float> tex1 [[texture(1)]],
                               texture2d<float> tex2 [[texture(2)]],
                               sampler s0 [[sampler(0)]],
                               sampler s1 [[sampler(1)]],
                               sampler s2 [[sampler(2)]],
                               float4 dst [[color(0), function_constant(fc_logicOp)]],
                               constant AdvFrame& fr [[buffer(6), function_constant(fc_advLit)]],
                               device const float4* expState [[buffer(7), function_constant(fc_advLit)]],
                               depth2d<float> shadowMap [[texture(3), function_constant(fc_advLit)]],
                               texture2d<float> skyLut [[texture(4), function_constant(fc_advLit)]],
                               sampler cmp [[sampler(3), function_constant(fc_advLit)]],
                               sampler lin [[sampler(4), function_constant(fc_advLit)]]) {
    float4 primary = fc_flat ? in.colorFlat : in.colorSmooth;
    uint f = u.flags.x;
    float4 texels[3] = {float4(1), float4(1), float4(1)};
    float2 uv0 = in.tex0.xy / in.tex0.w;
    // antialiased lines: coverage across the width multiplies alpha (before the alpha test, as in GL)
    float coverage = 1.0;
    if (in.lineFlag > 1.5) coverage = saturate(max(in.lineHalf, 0.5) + 0.5 - abs(in.lineAcross)) * min(in.lineHalf * 2.0, 1.0);
    if (in.lineFlag > 0.5 && u.raster.y > 0.5) {
        // glLineStipple: bit (distance / factor) mod 16 of the pattern decides coverage
        uint bit = uint(floor(in.lineDist / u.raster.y)) & 15u;
        if (((uint(u.raster.z) >> bit) & 1u) == 0u) discard_fragment();
    }
    if (fc_advLit) {
        // albedo from unit 0 only (unit 1 is the lightmap, replaced by the lighting model)
        float4 c = primary;
        if (f & FF_TEX0) {
            float4 t0 = tex0.sample(s0, uv0);
            // combine setups may name the unit explicitly (GL_TEXTURE0, as vanilla's entity
            // brightness code leaves unit 0): that source reads texels[0]
            texels[0] = t0;
            c = fc_modulate ? primary * t0 : texEnv(u.env[0], u.envScale[0], t0, primary, primary, u.envColor[0], texels);
        }
        c.a *= coverage;
        if (fc_alphaTest) {
            if (!alphaPass(u.flags.w, c.a, u.alpha.x)) discard_fragment();
        }
        FFFragOut o;
        o.color = fwdLight(fr, c, in.eyePos, in.eyeNormal, in.tex1, (f & FF_TEX1) != 0, shadowMap, cmp, skyLut, lin,
                           expState, in.position.xy);
        return o;
    }
    if (f & FF_TEX0) texels[0] = tex0.sample(s0, uv0);
    if (f & FF_TEX1) texels[1] = tex1.sample(s1, in.tex1);
    if (f & FF_TEX2) texels[2] = tex2.sample(s2, float2(0.0)); // unit 2 keeps its default coords
    float4 c = primary;
    if (fc_modulate) {
        c *= texels[0] * texels[1] * texels[2]; // disabled units hold 1.0
    } else {
        if (f & FF_TEX0) c = texEnv(u.env[0], u.envScale[0], texels[0], primary, c, u.envColor[0], texels);
        if (f & FF_TEX1) c = texEnv(u.env[1], u.envScale[1], texels[1], primary, c, u.envColor[1], texels);
        if (f & FF_TEX2) c = texEnv(u.env[2], u.envScale[2], texels[2], primary, c, u.envColor[2], texels);
    }

    if (f & FF_FOG) c.rgb = mix(u.fogColor.rgb, c.rgb, in.fogFactor);
    c.a *= coverage;
    if (fc_alphaTest) {
        if (!alphaPass(u.flags.w, c.a, u.alpha.x)) discard_fragment();
    }
    FFFragOut o;
    if (fc_logicOp) o.color = logicOp(u.alpha.y, c, dst);
    else o.color = c;
    return o;
}

// ---------------------------------------------------------------------------
// clears that cannot use a load action (scissored / masked / mid-pass)

struct ClearOut {
    float4 position [[position]];
};

vertex ClearOut clear_vertex(uint vid [[vertex_id]], constant ClearUniforms& u [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    ClearOut o;
    o.position = float4(p * 2.0 - 1.0, u.depth.x, 1.0);
    return o;
}

fragment float4 clear_fragment(ClearOut in [[stage_in]], constant ClearUniforms& u [[buffer(0)]]) {
    return u.color;
}
