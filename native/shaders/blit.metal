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
