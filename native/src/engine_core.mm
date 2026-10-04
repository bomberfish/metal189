// metal189: Metal device, frame ring and presentation.

#import "m189.h"
#import "engine.h"
#import "gpu_profiler.h"
#import "resources.h"
#include <vector>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#import "interp.h"
#import <QuartzCore/QuartzCore.h>

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
    e.rtAccelerated = dev.supportsRaytracing && [dev supportsFamily:MTLGPUFamilyApple9];

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
    terrainOffset = 0;
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

// ---------------------------------------------------------------------------
// Screen targets and presentation.
//
// The GL default framebuffer is a ring of engine-owned textures. With vsync
// off ("mailbox"), a presenter thread waits for the compositor to free a
// drawable and shows the newest finished frame, so rendering is never paced
// by drawable availability (like GL with a swap interval of 0). With vsync on,
// frames present synchronously from the frame's own command buffer.

bool g_optPresent = true;
bool g_optGpuStats = false;
bool g_optSerialGpu = false;
static bool g_vsync = false;

enum ScreenState { SS_FREE, SS_WRITING, SS_READY, SS_PRESENTING };
constexpr int kScreenRing = 4;

struct Presenter {
    std::mutex m;
    std::condition_variable cv;
    id<MTLTexture> color[kScreenRing];
    id<MTLTexture> interp[kScreenRing];        // frame interpolation: the generated frame shown before color[i]
    bool hasInterp[kScreenRing] = {false, false, false, false};
    ScreenState state[kScreenRing] = {SS_FREE, SS_FREE, SS_FREE, SS_FREE};
    uint64_t readySeq[kScreenRing] = {0, 0, 0, 0};
    uint64_t seq = 0, presentedSeq = 0;
    int current = -1;          // ring slot the open frame renders into
    int lastFinished = -1;     // most recent completed slot (for readbacks)
    id<MTLCommandQueue> queue = nil;
    std::thread thread;
    bool running = false;
    int w = 0, h = 0;
};
static Presenter g_pres;

void setVSync(bool on) { g_vsync = on; }

static void blitToDrawable(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<CAMetalDrawable> drawable) {
    id<MTLTexture> dst = drawable.texture;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    NSUInteger w = std::min(dst.width, src.width), h = std::min(dst.height, src.height);
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1) toTexture:dst destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
}

static void presenterLoop() {
    while (true) {
        {
            std::unique_lock<std::mutex> lk(g_pres.m);
            g_pres.cv.wait(lk, [] { return !g_pres.running || g_pres.seq > g_pres.presentedSeq; });
            if (!g_pres.running) return;
        }
        @autoreleasepool {
            CAMetalLayer* layer = metalLayer();
            id<CAMetalDrawable> drawable = layer ? [layer nextDrawable] : nil;
            if (!drawable) continue;
            int slot = -1;
            id<MTLTexture> src = nil, generated = nil;   // held here: the game thread may replace the slot's
            {
                std::lock_guard<std::mutex> lk(g_pres.m);
                uint64_t best = 0;
                for (int i = 0; i < kScreenRing; i++) {
                    if (g_pres.state[i] == SS_READY && g_pres.readySeq[i] > best) { best = g_pres.readySeq[i]; slot = i; }
                }
                if (slot < 0) continue;
                g_pres.state[slot] = SS_PRESENTING;
                g_pres.presentedSeq = g_pres.readySeq[slot];
                src = g_pres.color[slot];
                if (g_pres.hasInterp[slot]) generated = g_pres.interp[slot];
            }
            id<MTLCommandBuffer> cb = [g_pres.queue commandBuffer];
            cb.label = @"present";
            if (generated) {
                // frame interpolation: the generated frame now, the rendered one half a frame later
                // (display-synced while interpolating, so neither tears). One drawable at a time:
                // holding two of the layer's three made nextDrawable wait up to its 1 s timeout.
                double due = CACurrentMediaTime() + interpFrameInterval() * 0.5;
                id<MTLCommandBuffer> first = [g_pres.queue commandBuffer];
                first.label = @"present generated";
                blitToDrawable(first, generated, drawable);
                [first presentDrawable:drawable];
                [first commit];
                double wait = due - CACurrentMediaTime();
                if (wait > 0) std::this_thread::sleep_for(std::chrono::microseconds((int64_t)(wait * 1e6)));
                drawable = [layer nextDrawable];
                if (drawable) {
                    blitToDrawable(cb, src, drawable);
                    [cb presentDrawable:drawable];
                }
            } else {
                blitToDrawable(cb, src, drawable);
                [cb presentDrawable:drawable];
            }
            [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
                std::lock_guard<std::mutex> lk(g_pres.m);
                if (g_pres.state[slot] == SS_PRESENTING) g_pres.state[slot] = SS_FREE;
                g_pres.cv.notify_all();
            }];
            [cb commit];
            if (g_optGpuStats) {
                // frames shown per second (rendered and generated)
                static double t0 = 0;
                static int shown = 0;
                shown += generated ? 2 : 1;
                double now = CACurrentMediaTime();
                if (t0 == 0) t0 = now;
                if (now - t0 >= 5.0) {
                    log("presented %.1f frames/s", shown / (now - t0));
                    t0 = now;
                    shown = 0;
                }
            }
        }
    }
}

static void allocScreen(int w, int h) {
    Engine& e = engine();
    for (int i = 0; i < kScreenRing; i++) {
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        g_pres.color[i] = [e.device newTextureWithDescriptor:d];
        g_pres.color[i].label = @"screen";
        g_pres.state[i] = SS_FREE;
        g_pres.interp[i] = nil;
        g_pres.hasInterp[i] = false;
    }
    MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:w height:h mipmapped:NO];
    dd.storageMode = MTLStorageModePrivate;
    dd.usage = MTLTextureUsageRenderTarget;
    e.screenDepth = [e.device newTextureWithDescriptor:dd];
    g_pres.w = w;
    g_pres.h = h;
    g_pres.lastFinished = -1;
}

static uint64_t g_waitNs = 0;   // this frame's time waiting for a free screen slot

// Picks the ring slot for the open frame's default framebuffer.
void ensureScreenTargets() {
    Engine& e = engine();
    if (g_pres.current >= 0 && e.screenColor) return;
    WindowInfo& wi = windowInfo();
    int w = wi.pixelWidth, h = wi.pixelHeight;
    std::unique_lock<std::mutex> lk(g_pres.m);
    if (!g_pres.color[0] || g_pres.w != w || g_pres.h != h) {
        // Resizing: wait for the presenter to let go of the old textures.
        g_pres.cv.wait(lk, [] {
            for (int i = 0; i < kScreenRing; i++) if (g_pres.state[i] == SS_PRESENTING) return false;
            return true;
        });
        allocScreen(w, h);
    }
    int slot = -1;
    while (slot < 0) {
        uint64_t newest = 0;
        int newestSlot = -1;
        for (int i = 0; i < kScreenRing; i++) {
            if (g_pres.state[i] == SS_READY && g_pres.readySeq[i] > newest) { newest = g_pres.readySeq[i]; newestSlot = i; }
        }
        for (int i = 0; i < kScreenRing && slot < 0; i++) if (g_pres.state[i] == SS_FREE) slot = i;
        for (int i = 0; i < kScreenRing && slot < 0; i++) if (g_pres.state[i] == SS_READY && i != newestSlot) slot = i;
        if (slot < 0) {
            uint64_t w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            g_pres.cv.wait(lk);
            g_waitNs += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - w0;   // GPU backpressure, not encoding
        }
    }
    g_pres.state[slot] = SS_WRITING;
    g_pres.current = slot;
    e.screenColor = g_pres.color[slot];
}

// Texture holding the most recent complete image of the default framebuffer.
id<MTLTexture> screenForReadback() {
    Engine& e = engine();
    if (e.screenDirty && e.screenColor) return e.screenColor;
    std::lock_guard<std::mutex> lk(g_pres.m);
    return g_pres.lastFinished >= 0 ? g_pres.color[g_pres.lastFinished] : e.screenColor;
}

static void startPresenter() {
    if (g_pres.running) return;
    g_pres.queue = [engine().device newCommandQueue];
    g_pres.running = true;
    g_pres.thread = std::thread(presenterLoop);
    g_pres.thread.detach(); // lives for the whole process
}

// Called when the frame's command buffer is encoded: wires the screen slot
// into presentation. Synchronous (vsync) frames present from `cb` itself.
static void present(id<MTLCommandBuffer> cb) {
    Engine& e = engine();
    int slot = g_pres.current;
    bool rendered = e.screenDirty && slot >= 0;
    e.screenDirty = false;
    g_pres.current = -1;
    e.screenColor = nil;
    if (slot < 0) return;
    if (!rendered) {
        std::lock_guard<std::mutex> lk(g_pres.m);
        g_pres.state[slot] = SS_FREE;
        return;
    }
    CAMetalLayer* layer = metalLayer();
    // frame interpolation: the generated frame between the previous one and this, shown first
    // (the slot is ours, SS_WRITING; the presenter takes its textures under the lock)
    static bool interpWas = false;
    bool interp = false;
    if (interpWanted() && g_optPresent && layer) {
        id<MTLTexture> src = g_pres.color[slot], out = nil;
        {
            std::lock_guard<std::mutex> lk(g_pres.m);
            out = g_pres.interp[slot];
        }
        if (!out || out.width != src.width || out.height != src.height || out.pixelFormat != src.pixelFormat) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width
                                                                                       height:src.height mipmapped:NO];
            d.storageMode = MTLStorageModePrivate;
            d.usage = interpOutputUsage() | MTLTextureUsageShaderRead;
            out = [e.device newTextureWithDescriptor:d];
            out.label = @"interpolated frame";
        }
        interp = interpEncode(cb, src, out);
        std::lock_guard<std::mutex> lk(g_pres.m);
        g_pres.interp[slot] = out;
        g_pres.hasInterp[slot] = interp;
        interpWas = true;
    } else {
        std::lock_guard<std::mutex> lk(g_pres.m);
        g_pres.hasInterp[slot] = false;
        if (interpWas) {
            interpRelease();
            for (int i = 0; i < kScreenRing; i++) {
                g_pres.interp[i] = nil;   // a frame being presented keeps its own reference
                g_pres.hasInterp[i] = false;
            }
            interpWas = false;
        }
    }
    if (!g_optPresent || !layer) {
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            std::lock_guard<std::mutex> lk(g_pres.m);
            g_pres.state[slot] = SS_FREE;
            g_pres.lastFinished = slot;
            g_pres.cv.notify_all();
        }];
        return;
    }
    // display sync while interpolating (tear-free generated frames), else as the vsync setting says
    static bool syncForInterp = false;
    if (interp != syncForInterp) {
        syncForInterp = interp;
        bool on = interp || g_vsync;
#if !TARGET_OS_IPHONE   // iOS layers always present on the display's refresh
        dispatch_async(dispatch_get_main_queue(), ^{ layer.displaySyncEnabled = on; });
#else
        (void)on;
#endif
    }
    if (g_vsync && !interp) {   // interpolated frames are paced by the presenter
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable) {
            blitToDrawable(cb, g_pres.color[slot], drawable);
            [cb presentDrawable:drawable];
        }
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            std::lock_guard<std::mutex> lk(g_pres.m);
            g_pres.state[slot] = SS_FREE;
            g_pres.lastFinished = slot;
            g_pres.cv.notify_all();
        }];
        return;
    }
    startPresenter();
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        std::lock_guard<std::mutex> lk(g_pres.m);
        // Older finished frames that were never shown are superseded.
        for (int i = 0; i < kScreenRing; i++) if (g_pres.state[i] == SS_READY) g_pres.state[i] = SS_FREE;
        g_pres.state[slot] = SS_READY;
        g_pres.readySeq[slot] = ++g_pres.seq;
        g_pres.lastFinished = slot;
        g_pres.cv.notify_all();
    }];
}

static id<MTLCommandBuffer> encode(const uint8_t* cmds, size_t len) {
    Engine& e = engine();
    id<MTLCommandBuffer> cb = [e.queue commandBuffer];
    profBeginFrame(cb);
    encodePendingResourceWork(cb);
    executeFrame(cb, cmds, len);
    return cb;
}

void endFrame(const uint8_t* cmds, size_t len) {
    Engine& e = engine();
    if (!e.frameOpen) beginFrame();
    @autoreleasepool {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        g_waitNs = 0;
        id<MTLCommandBuffer> cb = encode(cmds, len);
        cb.label = @"frame";
        present(cb);
        if (g_optGpuStats) {
            // CPU time the engine spends turning the frame's commands into Metal work
            static double cpuAcc = 0, waitAcc = 0, bytesAcc = 0;
            static int cpuN = 0;
            double total = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) * 1e-6, wait = g_waitNs * 1e-6;
            cpuAcc += total - wait;
            waitAcc += wait;
            bytesAcc += (double)len;
            if (++cpuN == 600) {
                log("cpu encode time avg %.3f ms, waiting for the GPU %.3f ms (%.0f KB of commands per frame)", cpuAcc / cpuN,
                    waitAcc / cpuN, bytesAcc / cpuN / 1024.0);
                cpuAcc = waitAcc = bytesAcc = 0;
                cpuN = 0;
            }
        }
        dispatch_semaphore_t sem = e.inflight;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
            if (b.status == MTLCommandBufferStatusError) log("command buffer error: %s", b.error.localizedDescription.UTF8String);
            double gpu = (b.GPUEndTime - b.GPUStartTime) * 1000.0;
            static double acc = 0; static int n = 0;
            acc += gpu; n++;
            int every = g_optSerialGpu ? 100 : 600;
            if (n >= every) { if (g_optGpuStats || g_optSerialGpu) log("gpu frame time avg %.3f ms", acc / n); acc = 0; n = 0; }
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
        // benchmarking: one frame on the GPU at a time, so its GPU time is its own
        if (g_optSerialGpu) [cb waitUntilCompleted];
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
