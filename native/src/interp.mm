// metal189: MetalFX frame interpolation (see interp.h).
#import "interp.h"
#import "advanced.h"
#import "m189.h"
#import <MetalFX/MetalFX.h>
#include <cmath>

namespace m189 {

extern int g_optAdvDebug;
extern bool g_optGpuStats;

namespace {

struct State {
    id interpolator = nil;   // id<MTLFXFrameInterpolator> (macOS 26)
    int w = 0, h = 0;
    MTLPixelFormat format = MTLPixelFormatInvalid;
    id<MTLTexture> world = nil, depth = nil, motion = nil, ui = nil, prev = nil;
    id<MTLComputePipelineState> uiKernel = nil;
    bool tried = false;
    // this frame's capture
    bool captured = false, cut = false;
    simd_float4x4 proj = matrix_identity_float4x4, view = matrix_identity_float4x4;
    bool havePrev = false;
    double lastTime = 0, interval = 1.0 / 60.0;
};
State S;

id<MTLTexture> tex(MTLPixelFormat f, int w, int h, MTLTextureUsage u, NSString* label) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = u;
    id<MTLTexture> t = [device() newTextureWithDescriptor:d];
    t.label = label;
    return t;
}

// The interpolator works on the screen's frames (colour format f); the world capture keeps the
// format of the framebuffer the world was rendered into (the UI kernel compares them as colours).
bool ensure(int w, int h, MTLPixelFormat f, int worldW, int worldH, MTLPixelFormat worldFormat) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        auto ensureWorld = [&]() {
            if (!S.world || S.world.pixelFormat != worldFormat || (int)S.world.width != worldW || (int)S.world.height != worldH)
                S.world = tex(worldFormat, worldW, worldH,
                              MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget, @"interp world");
            return S.world != nil;
        };
        if (S.interpolator && S.w == w && S.h == h && S.format == f) return ensureWorld();
        interpRelease();
        id<MTLDevice> dev = device();
        if (!S.uiKernel) {
            NSError* err = nil;
            id<MTLFunction> fn = [engine().library newFunctionWithName:@"interp_ui_kernel"];
            if (fn) S.uiKernel = [dev newComputePipelineStateWithFunction:fn error:&err];
            if (!S.uiKernel) return false;
        }
        MTLFXFrameInterpolatorDescriptor* d = [MTLFXFrameInterpolatorDescriptor new];
        d.colorTextureFormat = f;
        d.outputTextureFormat = f;
        d.depthTextureFormat = MTLPixelFormatDepth32Float;
        d.motionTextureFormat = MTLPixelFormatRG16Float;
        d.uiTextureFormat = MTLPixelFormatRGBA8Unorm;
        d.inputWidth = w;
        d.inputHeight = h;
        d.outputWidth = w;
        d.outputHeight = h;
        id<MTLFXFrameInterpolator> fi = [d newFrameInterpolatorWithDevice:dev];
        if (!fi) {
            log("metalfx: no frame interpolator for %dx%d", w, h);
            return false;
        }
        S.interpolator = fi;
        S.w = w;
        S.h = h;
        S.format = f;
        MTLTextureUsage rw = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        S.world = nil;
        ensureWorld();
        S.depth = tex(MTLPixelFormatDepth32Float, w, h, rw | fi.depthTextureUsage, @"interp depth");
        S.motion = tex(MTLPixelFormatRG16Float, w, h, rw | fi.motionTextureUsage, @"interp motion");
        S.ui = tex(MTLPixelFormatRGBA8Unorm, w, h, rw | fi.uiTextureUsage, @"interp ui");
        S.prev = tex(f, w, h, rw | fi.colorTextureUsage, @"interp previous frame");
        S.havePrev = false;
        log("metalfx: frame interpolation %dx%d", w, h);
        return S.world && S.depth && S.motion && S.ui && S.prev;
    }
    return false;
}

} // namespace

bool interpSupported() {
    if (@available(macOS 26.0, iOS 26.0, *)) return [MTLFXFrameInterpolatorDescriptor supportsDevice:device()];
    return false;
}

bool interpWanted() { return advancedEnabled() && advancedFrameInterpolation() && interpSupported(); }

bool interpBeginCapture(int worldW, int worldH, MTLPixelFormat worldFormat, InterpCapture& out) {
    S.captured = false;
    if (!interpWanted()) return false;
    // screen frames are BGRA8 at the window's pixel size (engine_core.mm allocScreen)
    const WindowInfo& wi = windowInfo();
    int w = wi.pixelWidth, h = wi.pixelHeight;
    if (w <= 0 || h <= 0 || !ensure(w, h, MTLPixelFormatBGRA8Unorm, worldW, worldH, worldFormat)) return false;
    out.world = S.world;
    out.depth = S.depth;
    out.motion = S.motion;
    out.screenW = w;
    out.screenH = h;
    return true;
}

void interpCaptured(const simd_float4x4& proj, const simd_float4x4& view, bool cut) {
    S.captured = true;
    S.cut = cut;
    S.proj = proj;
    S.view = view;
}

MTLTextureUsage interpOutputUsage() {
    MTLTextureUsage u = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (S.interpolator) u |= ((id<MTLFXFrameInterpolator>)S.interpolator).outputTextureUsage;
    }
    return u;
}

bool interpEncode(id<MTLCommandBuffer> cb, id<MTLTexture> finalFrame, id<MTLTexture> out) {
    bool captured = S.captured;
    S.captured = false;
    double now = CACurrentMediaTime();
    if (S.lastTime > 0) S.interval = S.interval * 0.9 + std::min(now - S.lastTime, 0.25) * 0.1;
    S.lastTime = now;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        id<MTLFXFrameInterpolator> fi = (id<MTLFXFrameInterpolator>)S.interpolator;
        bool fits = fi && finalFrame && out && (int)finalFrame.width == S.w && (int)finalFrame.height == S.h &&
                    finalFrame.pixelFormat == S.format && out.pixelFormat == S.format;
        if (!captured || !fits) {
            if (g_optGpuStats) {
                static int n = 0;
                if (++n % 300 == 1)
                    log("frame interpolation skipped: captured %d, interpolator %d, final %dx%d fmt %d, capture %dx%d fmt %d, out fmt %d",
                        captured, fi != nil, finalFrame ? (int)finalFrame.width : 0, finalFrame ? (int)finalFrame.height : 0,
                        finalFrame ? (int)finalFrame.pixelFormat : 0, S.w, S.h, (int)S.format, out ? (int)out.pixelFormat : 0);
            }
            S.havePrev = false;
            return false;
        }
        bool generate = S.havePrev && !S.cut;
        if (g_optGpuStats) {
            static int frames = 0, generated = 0;
            frames++;
            generated += generate ? 1 : 0;
            if (frames == 300) {
                log("frame interpolation: %d of %d frames generated a frame, %.1f ms between frames", generated, frames,
                    S.interval * 1000.0);
                frames = generated = 0;
            }
        }
        if (generate) {
            // the UI layer: whatever was drawn over the captured world since
            id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
            c.label = @"interp ui";
            [c setComputePipelineState:S.uiKernel];
            [c setTexture:finalFrame atIndex:0];
            [c setTexture:S.world atIndex:1];
            [c setTexture:S.ui atIndex:2];
            [c dispatchThreads:MTLSizeMake(S.w, S.h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [c endEncoding];
            fi.colorTexture = finalFrame;
            fi.prevColorTexture = S.prev;
            fi.depthTexture = S.depth;
            fi.motionTexture = S.motion;
            fi.uiTexture = S.ui;
            fi.uiTextureComposited = YES;
            fi.outputTexture = out;
            fi.motionVectorScaleX = 1.0f;
            fi.motionVectorScaleY = 1.0f;
            fi.jitterOffsetX = 0.0f;
            fi.jitterOffsetY = 0.0f;
            // camera from the projection (OpenGL clip space: P[1][1] = cot(fov / 2), near/far from z terms)
            const simd_float4x4& P = S.proj;
            float a = P.columns[2][2], b = P.columns[3][2];
            fi.nearPlane = b / (a - 1.0f);
            fi.farPlane = b / (a + 1.0f);
            fi.fieldOfView = 2.0f * atanf(1.0f / P.columns[1][1]) * 57.29578f;
            fi.aspectRatio = P.columns[1][1] / P.columns[0][0];
            fi.deltaTime = (float)S.interval;
            fi.shouldResetHistory = NO;
            [fi encodeToCommandBuffer:cb];
        }
        // this frame becomes the next one's previous
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        b.label = @"interp keep frame";
        [b copyFromTexture:finalFrame toTexture:S.prev];
        // debug view 30: the generated frame in the rendered one's place (for captures)
        if (generate && g_optAdvDebug == 30) [b copyFromTexture:out toTexture:finalFrame];
        [b endEncoding];
        S.havePrev = true;
        return generate;
    }
    return false;
}

double interpFrameInterval() { return S.interval; }

void interpRelease() {
    S.interpolator = nil;
    S.world = S.depth = S.motion = S.ui = S.prev = nil;
    S.w = S.h = 0;
    S.havePrev = false;
}

} // namespace m189
