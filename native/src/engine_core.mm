// metal189: Metal device, frame ring and presentation.

#import "m189.h"
#import "engine.h"
#import "resources.h"
#include <vector>

namespace m189 {

static Engine* g_engine = nullptr;

Engine& engine() { return *g_engine; }
id<MTLDevice> device() { return g_engine ? g_engine->device : nil; }

bool engineInit(const void* metallib, size_t metallibSize, int flags) {
    if (g_engine) return true;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { log("no Metal device"); return false; }
    g_engine = new Engine();
    Engine& e = *g_engine;
    e.device = dev;
    e.queue = [dev newCommandQueueWithMaxCommandBufferCount:64];
    e.queue.label = @"metal189";
    e.inflight = dispatch_semaphore_create(kFramesInFlight);
    e.supportsRaytracing = dev.supportsRaytracing;

    NSError* err = nil;
    if (metallib && metallibSize > 0) {
        dispatch_data_t data = dispatch_data_create(metallib, metallibSize, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        e.library = [dev newLibraryWithData:data error:&err];
        if (!e.library) {
            log("failed to load shader library: %s", err.localizedDescription.UTF8String);
            return false;
        }
    }
    for (int i = 0; i < kFramesInFlight; i++) e.frames[i].init(dev, i);
    if (!executorInit()) return false;
    log("device: %s (raytracing=%d, apple9=%d)", dev.name.UTF8String, (int)e.supportsRaytracing,
        (int)[dev supportsFamily:MTLGPUFamilyApple9]);
    return true;
}

void FrameResources::init(id<MTLDevice> dev, int index) {
    id<MTLBuffer> a = [dev newBufferWithLength:kArenaInitialSize options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    a.label = [NSString stringWithFormat:@"vertex arena %d", index];
    arenas.push_back(a);
    indexCapacity = 4u << 20;
    indices = [dev newBufferWithLength:indexCapacity options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    uniformCapacity = 4u << 20;
    uniforms = [dev newBufferWithLength:uniformCapacity options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
}

// Called once the GPU has finished with this slot.
void FrameResources::reset() {
    if (arenas.size() > 1) arenas.resize(1);
    indexOffset = 0;
    uniformOffset = 0;
    retired.clear();
    for (id<MTLBuffer> b : stagingChunks) stagingFree.push_back(b);
    stagingChunks.clear();
    staging.clear();
    stagingCur = nil;
    stagingOffset = 0;
}

void beginFrame() {
    Engine& e = engine();
    if (e.frameOpen) return;
    dispatch_semaphore_wait(e.inflight, DISPATCH_TIME_FOREVER);
    e.frameOpen = true;
    e.frameIndex++;
    e.cur = &e.frames[e.frameIndex % kFramesInFlight];
    e.cur->reset();
}

void arenaGrow(size_t minBytes, int64_t* info) {
    Engine& e = engine();
    size_t size = std::max(kArenaInitialSize, (minBytes + 0xFFFF) & ~(size_t)0xFFFF);
    id<MTLBuffer> a = [e.device newBufferWithLength:size options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    e.cur->arenas.push_back(a);
    info[0] = (int64_t)(intptr_t)a.contents;
    info[1] = (int64_t)size;
    info[3] = (int64_t)(e.cur->arenas.size() - 1);
}

void ensureScreenTargets() {
    Engine& e = engine();
    WindowInfo& wi = windowInfo();
    int w = wi.pixelWidth, h = wi.pixelHeight;
    if (e.screenColor && (int)e.screenColor.width == w && (int)e.screenColor.height == h) return;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    e.screenColor = [e.device newTextureWithDescriptor:d];
    e.screenColor.label = @"screen";
    MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:w height:h mipmapped:NO];
    dd.storageMode = MTLStorageModePrivate;
    dd.usage = MTLTextureUsageRenderTarget;
    e.screenDepth = [e.device newTextureWithDescriptor:dd];
}

static void present(id<MTLCommandBuffer> cb) {
    Engine& e = engine();
    if (!e.screenDirty || !e.screenColor) return;
    e.screenDirty = false;
    CAMetalLayer* layer = metalLayer();
    if (!layer) return;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;
    id<MTLTexture> dst = drawable.texture;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    NSUInteger w = std::min(dst.width, e.screenColor.width), h = std::min(dst.height, e.screenColor.height);
    [blit copyFromTexture:e.screenColor sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1) toTexture:dst destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb presentDrawable:drawable];
}

static id<MTLCommandBuffer> encode(const uint8_t* cmds, size_t len) {
    Engine& e = engine();
    id<MTLCommandBuffer> cb = [e.queue commandBuffer];
    encodePendingResourceWork(cb);
    executeFrame(cb, cmds, len);
    return cb;
}

void endFrame(const uint8_t* cmds, size_t len) {
    Engine& e = engine();
    if (!e.frameOpen) beginFrame();
    @autoreleasepool {
        id<MTLCommandBuffer> cb = encode(cmds, len);
        cb.label = @"frame";
        present(cb);
        dispatch_semaphore_t sem = e.inflight;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
            if (b.status == MTLCommandBufferStatusError) log("command buffer error: %s", b.error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
        e.lastCommitted = cb;
        releaseDeferred();
    }
    e.frameOpen = false;
}

// Executes the commands recorded so far (no present) and waits for completion.
void submitPartial(const uint8_t* cmds, size_t len) {
    Engine& e = engine();
    @autoreleasepool {
        id<MTLCommandBuffer> cb = encode(cmds, len);
        cb.label = @"partial";
        [cb commit];
        [cb waitUntilCompleted];
        e.lastCommitted = cb;
    }
}

void waitIdle() {
    Engine& e = engine();
    if (e.lastCommitted) [e.lastCommitted waitUntilCompleted];
}

id<CAMetalDrawable> acquireDrawable() { return nil; }

} // namespace m189
