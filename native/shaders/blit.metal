// metal189: full-screen blit (used for presenting offscreen targets).
#include "common.h"

struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blit_vertex(uint vid [[vertex_id]], constant float4& flip [[buffer(0)]]) {
    // One oversized triangle covering the viewport.
    float2 p = float2((vid << 1) & 2, vid & 2);
    BlitOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    float2 uv = float2(p.x, 1.0 - p.y);
    o.uv = mix(uv, float2(uv.x, 1.0 - uv.y), flip.x);
    return o;
}

fragment float4 blit_fragment(BlitOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return src.sample(smp, in.uv);
}

// Presenting: texel-exact copy into the drawable (a render pass is several times faster
// than a blit into the window's surface on Apple GPUs).
fragment float4 present_fragment(BlitOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.read(uint2(in.position.xy));
}

// glCopyTexSubImage2D from a top-down (Metal-oriented) source into a bottom-up (GL row
// order) texture: destination texel (xoff + i, yoff + j) receives source GL row y + j,
// i.e. source texel (x + i, srcTop - j). p = (x, srcTop, xoff, yoff).
fragment float4 copy_flip_fragment(BlitOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                   constant int4& p [[buffer(0)]]) {
    int2 d = int2(in.position.xy);
    int2 s = int2(p.x + (d.x - p.z), p.y - (d.y - p.w));
    return src.read(uint2(clamp(s, int2(0), int2(src.get_width() - 1, src.get_height() - 1))));
}
