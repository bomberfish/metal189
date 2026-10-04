// metal189: MetalFX upscaling (macOS 13+): the spatial scaler upscales an anti-aliased
// image, the temporal scaler anti-aliases and upscales the jittered HDR scene in one pass
// using depth and motion vectors (it then replaces the pipeline's own TAA).
#import "upscale.h"
#import <MetalFX/MetalFX.h>

namespace m189 {

namespace {

id<MTLFXSpatialScaler> g_spatial = nil;
id<MTLFXTemporalScaler> g_temporal = nil;
id g_denoised = nil;   // id<MTLFXTemporalDenoisedScaler> (macOS 26)
int g_key[5] = {0, 0, 0, 0, 0};   // mode, input and output size the scaler was made for

bool matches(const UpscaleFrame& f) {
    return g_key[0] == f.mode && g_key[1] == f.inW && g_key[2] == f.inH && g_key[3] == f.outW && g_key[4] == f.outH;
}

bool make(const UpscaleFrame& f) {
    if (matches(f) && (g_spatial || g_temporal || g_denoised)) return true;
    g_spatial = nil;
    g_temporal = nil;
    g_denoised = nil;
    g_key[0] = f.mode; g_key[1] = f.inW; g_key[2] = f.inH; g_key[3] = f.outW; g_key[4] = f.outH;
    id<MTLDevice> dev = device();
    if (f.mode == UPSCALE_SPATIAL) {
        MTLFXSpatialScalerDescriptor* d = [MTLFXSpatialScalerDescriptor new];
        d.colorTextureFormat = MTLPixelFormatRGBA16Float;
        d.outputTextureFormat = MTLPixelFormatRGBA16Float;
        d.inputWidth = f.inW;
        d.inputHeight = f.inH;
        d.outputWidth = f.outW;
        d.outputHeight = f.outH;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModeHDR;
        g_spatial = [d newSpatialScalerWithDevice:dev];
        if (!g_spatial) log("metalfx: no spatial scaler for %dx%d -> %dx%d", f.inW, f.inH, f.outW, f.outH);
        else log("metalfx: spatial %dx%d -> %dx%d, colour usage %lx, output usage %lx", f.inW, f.inH, f.outW, f.outH,
                 (unsigned long)g_spatial.colorTextureUsage, (unsigned long)g_spatial.outputTextureUsage);
        return g_spatial != nil;
    }
    if (f.mode == UPSCALE_DENOISED) {
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTLFXTemporalDenoisedScalerDescriptor* d = [MTLFXTemporalDenoisedScalerDescriptor new];
            d.colorTextureFormat = MTLPixelFormatRGBA16Float;
            d.depthTextureFormat = MTLPixelFormatDepth32Float;
            d.motionTextureFormat = MTLPixelFormatRG16Float;
            d.diffuseAlbedoTextureFormat = MTLPixelFormatRGBA8Unorm;
            d.specularAlbedoTextureFormat = MTLPixelFormatRGBA8Unorm;
            d.normalTextureFormat = MTLPixelFormatRGBA16Float;
            d.roughnessTextureFormat = MTLPixelFormatR8Unorm;
            d.denoiseStrengthMaskTextureEnabled = YES;
            d.denoiseStrengthMaskTextureFormat = MTLPixelFormatR8Unorm;
            d.outputTextureFormat = MTLPixelFormatRGBA16Float;
            d.inputWidth = f.inW;
            d.inputHeight = f.inH;
            d.outputWidth = f.outW;
            d.outputHeight = f.outH;
            d.autoExposureEnabled = YES;
            g_denoised = [d newTemporalDenoisedScalerWithDevice:dev];
        }
        if (!g_denoised) log("metalfx: no denoised scaler for %dx%d -> %dx%d", f.inW, f.inH, f.outW, f.outH);
        else log("metalfx: denoised %dx%d -> %dx%d", f.inW, f.inH, f.outW, f.outH);
        return g_denoised != nil;
    }
    MTLFXTemporalScalerDescriptor* d = [MTLFXTemporalScalerDescriptor new];
    d.colorTextureFormat = MTLPixelFormatRGBA16Float;
    d.depthTextureFormat = MTLPixelFormatDepth32Float;
    d.motionTextureFormat = MTLPixelFormatRG16Float;
    d.outputTextureFormat = MTLPixelFormatRGBA16Float;
    d.inputWidth = f.inW;
    d.inputHeight = f.inH;
    d.outputWidth = f.outW;
    d.outputHeight = f.outH;
    d.autoExposureEnabled = YES;   // scene-linear HDR input
    g_temporal = [d newTemporalScalerWithDevice:dev];
    if (!g_temporal) log("metalfx: no temporal scaler for %dx%d -> %dx%d", f.inW, f.inH, f.outW, f.outH);
    else log("metalfx: temporal %dx%d -> %dx%d, colour %lx depth %lx motion %lx output %lx", f.inW, f.inH, f.outW, f.outH,
             (unsigned long)g_temporal.colorTextureUsage, (unsigned long)g_temporal.depthTextureUsage,
             (unsigned long)g_temporal.motionTextureUsage, (unsigned long)g_temporal.outputTextureUsage);
    return g_temporal != nil;
}

} // namespace

bool upscaleSupported(int mode) {
    id<MTLDevice> dev = device();
    if (mode == UPSCALE_SPATIAL) return [MTLFXSpatialScalerDescriptor supportsDevice:dev];
    if (mode == UPSCALE_TEMPORAL) return [MTLFXTemporalScalerDescriptor supportsDevice:dev];
    if (mode == UPSCALE_DENOISED) {
        if (@available(macOS 26.0, iOS 26.0, *)) return [MTLFXTemporalDenoisedScalerDescriptor supportsDevice:dev];
    }
    return false;
}

void upscaleScaleRange(int mode, float& minScale, float& maxScale) {
    minScale = 1.0f;
    maxScale = 2.0f;
    if (mode == UPSCALE_TEMPORAL) {
        id<MTLDevice> dev = device();
        minScale = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:dev];
        maxScale = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:dev];
    } else if (mode == UPSCALE_DENOISED) {
        if (@available(macOS 26.0, iOS 26.0, *)) {
            id<MTLDevice> dev = device();
            minScale = [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMinScaleForDevice:dev];
            maxScale = [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMaxScaleForDevice:dev];
        }
    } else if (mode == UPSCALE_SPATIAL) {
        maxScale = 3.0f;
    }
}

MTLTextureUsage upscaleOutputUsage() {
    MTLTextureUsage u = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (g_spatial) u |= g_spatial.outputTextureUsage;
    if (g_temporal) u |= g_temporal.outputTextureUsage;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (g_denoised) u |= ((id<MTLFXTemporalDenoisedScaler>)g_denoised).outputTextureUsage;
    }
    return u;
}

bool upscaleEncode(id<MTLCommandBuffer> cb, const UpscaleFrame& f) {
    if (f.mode == UPSCALE_OFF || !f.color || !f.output || !make(f)) return false;
    if (g_spatial) {
        g_spatial.colorTexture = f.color;
        g_spatial.outputTexture = f.output;
        g_spatial.inputContentWidth = f.inW;
        g_spatial.inputContentHeight = f.inH;
        [g_spatial encodeToCommandBuffer:cb];
        return true;
    }
    if (!f.depth || !f.motion) return false;
    if (g_denoised) {
        if (@available(macOS 26.0, iOS 26.0, *)) {
            if (!f.diffuse || !f.specular || !f.normal || !f.roughness) return false;
            id<MTLFXTemporalDenoisedScaler> ds = (id<MTLFXTemporalDenoisedScaler>)g_denoised;
            ds.colorTexture = f.color;
            ds.depthTexture = f.depth;
            ds.motionTexture = f.motion;
            ds.diffuseAlbedoTexture = f.diffuse;
            ds.specularAlbedoTexture = f.specular;
            ds.normalTexture = f.normal;
            ds.roughnessTexture = f.roughness;
            ds.denoiseStrengthMaskTexture = f.mask;
            ds.outputTexture = f.output;
            ds.jitterOffsetX = f.jitterX;
            ds.jitterOffsetY = f.jitterY;
            ds.motionVectorScaleX = 1.0f;
            ds.motionVectorScaleY = 1.0f;
            ds.depthReversed = NO;
            ds.worldToViewMatrix = f.worldToView;
            ds.viewToClipMatrix = f.viewToClip;
            ds.shouldResetHistory = f.reset;
            [ds encodeToCommandBuffer:cb];
            return true;
        }
        return false;
    }
    g_temporal.colorTexture = f.color;
    g_temporal.depthTexture = f.depth;
    g_temporal.motionTexture = f.motion;
    g_temporal.outputTexture = f.output;
    g_temporal.inputContentWidth = f.inW;
    g_temporal.inputContentHeight = f.inH;
    g_temporal.jitterOffsetX = f.jitterX;
    g_temporal.jitterOffsetY = f.jitterY;
    g_temporal.motionVectorScaleX = 1.0f;
    g_temporal.motionVectorScaleY = 1.0f;
    g_temporal.depthReversed = NO;
    g_temporal.reset = f.reset;
    [g_temporal encodeToCommandBuffer:cb];
    return true;
}

void upscaleRelease() {
    g_spatial = nil;
    g_temporal = nil;
    g_denoised = nil;
    g_key[0] = 0;
}

} // namespace m189
