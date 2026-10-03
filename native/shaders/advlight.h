// metal189: forward version of the advanced pipeline's lighting, for draws that the
// baseline executor replays on top of the tonemapped world in shaders mode (the hand,
// particles, weather). Mirrors light_fragment and tonemap_fragment in adv.metal so
// these draws match the deferred scene: sun with shadow-map PCF, sky ambient from the
// sky-view LUT, block light (fading in daylight), the held-item dynamic light, then the
// frame's exposure, ACES tonemap and vignette.
#pragma once
#include "adv.h"

static inline float3 fwdToLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
static inline float3 fwdToGamma(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

static inline float3 fwdAces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

static inline float2 fwdLutUv(float3 d) {
    float el = asin(clamp(d.y, -1.0, 1.0));
    float v = sign(el) * sqrt(abs(el) / 1.5707963);
    float az = atan2(d.z, d.x);
    if (az < 0.0) az += 2.0 * 3.14159265;
    return float2(az / (2.0 * 3.14159265), v * 0.5 + 0.5);
}

static float3 fwdSkyAmbient(constant AdvFrame& fr, texture2d<float> skyLut, sampler s, float3 nWorld) {
    if (fr.flags.y != 0) return fwdToLinear(fr.fogColor.rgb) * 0.3;
    float3 up = skyLut.sample(s, fwdLutUv(float3(0, 1, 0)), level(5.0)).rgb;
    float3 hor = skyLut.sample(s, fwdLutUv(normalize(float3(nWorld.x, 0.15, nWorld.z) + 1e-4)), level(5.0)).rgb;
    float t = saturate(nWorld.y * 0.5 + 0.5);
    return mix(hor * 0.6, mix(hor, up, 0.6), t) * 1.6;
}

static float fwdShadow(constant AdvFrame& fr, depth2d<float> shadowMap, sampler cmp, float3 world, float3 nWorld, float ndl) {
    float3 p = world + nWorld * (0.04 + 0.08 * (1.0 - ndl));
    float4 sc = fr.shadowViewProj * float4(p, 1.0);
    float3 ndc = sc.xyz / sc.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0) return 1.0;
    float texel = 1.0 / float(shadowMap.get_width());
    float sum = 0.0;
    for (int y = -1; y <= 2; y++)
        for (int x = -1; x <= 2; x++)
            sum += shadowMap.sample_compare(cmp, uv + (float2(x, y) - 0.5) * texel, ndc.z - 0.0004);
    return sum / 16.0;
}

// rgba: unlit texture * vertex colour (gamma space). eyePos/eyeNormal: eye space
// (eyeNormal zero when the vertex format has no normal, e.g. particles).
// lm: GL lightmap texture coordinates (vanilla's (coord + 8) / 256), hasLm: unit 1 bound.
static float4 fwdLight(constant AdvFrame& fr, float4 rgba, float3 eyePos, float3 eyeNormal, float2 lm, bool hasLm,
                       depth2d<float> shadowMap, sampler cmp, texture2d<float> skyLut, sampler lin,
                       device const float4* expState, float2 fragCoord) {
    float3 albedo = fwdToLinear(rgba.rgb);
    float block = 1.0, sky = 1.0;
    if (hasLm) {
        block = saturate((lm.x * 256.0 - 8.0) / 240.0);
        sky = saturate((lm.y * 256.0 - 8.0) / 240.0);
    }
    float dcam = length(eyePos);
    if (fr.post.z > 0.5) block = max(block, saturate((fr.post.z - dcam) / 15.0));   // held light source
    float3 world = (fr.invView * float4(eyePos, 1.0)).xyz;
    bool directional = dot(eyeNormal, eyeNormal) > 0.25;
    float3 n = directional ? normalize(eyeNormal) : float3(0, 0, 1);
    float3 nWorld = normalize((fr.invView * float4(n, 0.0)).xyz);
    bool sunUp = fr.sunDirView.w > 0.0;
    float3 lightDir = sunUp ? fr.sunDirView.xyz : fr.moonDirView.xyz;
    float3 lightCol = sunUp ? fr.sunColor.rgb : fr.moonColor.rgb;
    float ndl = dot(n, lightDir);
    // camera-facing sprites (no normal) take a soft, non-directional share of the sun
    float diffuse = directional ? saturate(ndl) : 0.55;
    float3 c = float3(0);
    if (fr.flags.y == 0 && diffuse > 0.0) {
        float shadow = (fr.flags.x & ADV_SHADOWS) ? fwdShadow(fr, shadowMap, cmp, world, nWorld, saturate(ndl)) : 1.0;
        c += lightCol * albedo * diffuse * shadow * smoothstep(0.35, 0.9, sky);
    }
    float daySky = sky * sky * fr.sunDirWorld.w;
    c += albedo * fwdSkyAmbient(fr, skyLut, lin, nWorld) * (sky * sky) * fr.ambient.a;
    c += albedo * fr.blockLight.rgb * pow(block, fr.blockLight.a) * (1.0 - 0.75 * daySky);
    c += albedo * 0.004;
    if (int(fr.flags.y) == -1) c += albedo * 0.03;
    if (int(fr.flags.y) == 1) c += albedo * float3(0.045, 0.038, 0.06);
    // distance haze towards the horizon colour (particles far away)
    if (fr.flags.y == 0 && fr.fog.w < 0.5) {
        float fogF = saturate((dcam - fr.fog.x) / max(fr.fog.y - fr.fog.x, 1.0));
        float3 d = normalize(world + 1e-5);
        float3 fogCol = skyLut.sample(lin, fwdLutUv(normalize(float3(d.x, max(d.y, 0.004), d.z))), level(0)).rgb;
        c = mix(c, fogCol, fogF * fogF);
    }
    float exposure = fr.params.z * ((fr.flags.x & ADV_AUTOEXP) ? expState[0].x : 1.0);
    c = fwdAces(c * exposure);
    float2 q = fragCoord * fr.screen.zw - 0.5;
    c *= 1.0 - dot(q, q) * 0.35;
    return float4(fwdToGamma(c), rgba.a);
}
