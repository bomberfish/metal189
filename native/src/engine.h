// metal189: engine internals shared between native translation units.
#pragma once
#import "m189.h"
#include <vector>

namespace m189 {

constexpr int kFramesInFlight = 3;
constexpr size_t kArenaInitialSize = 32u << 20;
constexpr size_t kStagingChunk = 8u << 20;

struct FrameResources {
    // Vertex arena written by Java: chunk 0 is permanent, later chunks are overflow.
    std::vector<id<MTLBuffer>> arenas;
    // Index + uniform streams written by the executor.
    id<MTLBuffer> indices = nil;
    size_t indexCapacity = 0, indexOffset = 0;
    std::vector<id<MTLBuffer>> retired;      // buffers replaced mid-frame, kept until reuse
    id<MTLBuffer> uniforms = nil;
    size_t uniformCapacity = 0, uniformOffset = 0;
    // Per-section draw records for the terrain pass (vertex address + modelview).
    id<MTLBuffer> terrainDraws = nil;
    size_t terrainCapacity = 0, terrainOffset = 0;
    // Texture upload staging.
    std::vector<id<MTLBuffer>> stagingChunks, stagingFree, staging;
    id<MTLBuffer> stagingCur = nil;
    size_t stagingOffset = 0;

    void init(id<MTLDevice> dev, int index);
    void reset();
};

struct Engine {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLLibrary> library = nil;
    dispatch_semaphore_t inflight = nullptr;
    bool supportsRaytracing = false;
    bool rtAccelerated = false;   // hardware ray tracing (Apple GPU family 9: M3 and later)

    FrameResources frames[kFramesInFlight];
    FrameResources* cur = nullptr;
    uint64_t frameIndex = 0;
    bool frameOpen = false;

    id<CAMetalDrawable> pendingDrawable = nil;
    id<MTLCommandBuffer> lastCommitted = nil;

    // Engine-owned stand-in for the GL default framebuffer (Metal orientation).
    id<MTLTexture> screenColor = nil, screenDepth = nil;
    bool screenDirty = false;   // rendered this frame, needs presenting
};

Engine& engine();
bool engineInit(const void* metallib, size_t metallibSize, int flags);
void beginFrame();
void endFrame(const uint8_t* cmds, size_t len);
void submitPartial(const uint8_t* cmds, size_t len);
void arenaGrow(size_t minBytes, int64_t* info);
void waitIdle();
void ensureScreenTargets();
id<MTLTexture> screenForReadback();
void setVSync(bool on);
id<CAMetalDrawable> acquireDrawable();

// Implemented by the frame executor.
void executeFrame(id<MTLCommandBuffer> cb, const uint8_t* cmds, size_t len);
bool executorInit();

// platform_window.mm
bool windowCreate(int width, int height, NSString* title, int32_t flags);
void windowDestroy();
void windowSetTitle(NSString* title);
void windowSetResizable(bool r);
void windowSetSize(int w, int h);
void windowSetFullscreen(bool fs);
void windowSetVSync(bool on);
void cursorSetGrabbed(bool grab);
void cursorSetPosition(int x, int y);
void desktopMode(int* out);

} // namespace m189
