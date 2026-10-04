// metal189: MetalFX upscaling for the advanced pipeline (spatial and temporal scalers).
#pragma once
#import "engine.h"

namespace m189 {

enum UpscaleMode { UPSCALE_OFF = 0, UPSCALE_SPATIAL = 1, UPSCALE_TEMPORAL = 2 };

struct UpscaleFrame {
    int mode = UPSCALE_OFF;
    int inW = 0, inH = 0, outW = 0, outH = 0;
    id<MTLTexture> color = nil;    // input (HDR, render resolution)
    id<MTLTexture> depth = nil;    // temporal: render-resolution depth
    id<MTLTexture> motion = nil;   // temporal: RG16Float, pixels to the previous frame's position
    id<MTLTexture> output = nil;   // HDR, output resolution
    float jitterX = 0, jitterY = 0;   // temporal: the frame's sub-pixel camera offset, pixels
    bool reset = false;            // temporal: discard history (camera cut, resize)
};

// Whether this GPU can run the mode, and the output/input size ratios it accepts.
bool upscaleSupported(int mode);
void upscaleScaleRange(int mode, float& minScale, float& maxScale);
// Usage flags the scaler needs on its output texture.
MTLTextureUsage upscaleOutputUsage();
bool upscaleEncode(id<MTLCommandBuffer> cb, const UpscaleFrame& f);
void upscaleRelease();

} // namespace m189
