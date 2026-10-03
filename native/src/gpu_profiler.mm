// metal189: per-pass GPU timing from Metal timestamp counters.
//
// Each profiled pass samples a timestamp at its first stage start and last stage end
// (Apple GPUs sample at stage boundaries only). Passes may overlap on the GPU, so the
// numbers are durations, not an exclusive breakdown. Logged every 600 frames.
#import "gpu_profiler.h"
#include <map>
#include <mutex>
#include <string>

namespace m189 {

extern bool g_optGpuStats;

namespace {

constexpr int kSlots = kFramesInFlight + 1;
constexpr int kMaxSamples = 64;  // per frame (2 per pass)

id<MTLCounterSampleBuffer> g_buf = nil;
bool g_tried = false;
int g_slot = 0;
int g_used = 0;
std::vector<const char*> g_names[kSlots];
double g_nsPerTick = 1.0;

std::mutex g_mu;
std::map<std::string, std::pair<double, int>> g_acc;
int g_frames = 0;

bool init() {
    if (g_tried) return g_buf != nil;
    g_tried = true;
    id<MTLDevice> dev = device();
    if (![dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return false;
    id<MTLCounterSet> ts = nil;
    for (id<MTLCounterSet> s in dev.counterSets)
        if ([s.name isEqualToString:MTLCommonCounterSetTimestamp]) ts = s;
    if (!ts) return false;
    MTLCounterSampleBufferDescriptor* d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = ts;
    d.storageMode = MTLStorageModeShared;
    d.sampleCount = kSlots * kMaxSamples;
    NSError* err = nil;
    g_buf = [dev newCounterSampleBufferWithDescriptor:d error:&err];
    if (!g_buf) return false;
    // GPU ticks -> ns, calibrated against the CPU clock over a short interval
    MTLTimestamp c0, g0, c1, g1;
    [dev sampleTimestamps:&c0 gpuTimestamp:&g0];
    usleep(20000);
    [dev sampleTimestamps:&c1 gpuTimestamp:&g1];
    // sampleTimestamps reports the CPU side in nanoseconds
    g_nsPerTick = g1 > g0 ? (double)(c1 - c0) / (double)(g1 - g0) : 1.0;
    return true;
}

// Reserves two sample indices for a pass in the current frame, or -1.
int reserve(const char* name) {
    if (!g_optGpuStats || !g_buf || g_used + 2 > kMaxSamples) return -1;
    int i = g_slot * kMaxSamples + g_used;
    g_used += 2;
    g_names[g_slot].push_back(name);
    return i;
}

} // namespace

bool profEnabled() { return g_optGpuStats && g_buf; }

void profBeginFrame(id<MTLCommandBuffer> cb) {
    if (!g_optGpuStats || !init()) return;
    g_slot = (g_slot + 1) % kSlots;
    g_used = 0;
    g_names[g_slot].clear();
    int slot = g_slot;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        size_t n = g_names[slot].size();
        if (!n) return;
        NSData* data = [g_buf resolveCounterRange:NSMakeRange((NSUInteger)slot * kMaxSamples, n * 2)];
        if (!data) return;
        const MTLCounterResultTimestamp* t = (const MTLCounterResultTimestamp*)data.bytes;
        std::lock_guard<std::mutex> lock(g_mu);
        for (size_t i = 0; i < n; i++) {
            uint64_t a = t[2 * i].timestamp, b = t[2 * i + 1].timestamp;
            if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) continue;
            auto& e = g_acc[g_names[slot][i]];
            e.first += (double)(b - a) * g_nsPerTick * 1e-6;
            e.second++;
        }
        if (++g_frames == 600) {
            std::string line;
            for (auto& [name, v] : g_acc) {
                char buf[96];
                snprintf(buf, sizeof buf, "%s %.3f  ", name.c_str(), v.first / g_frames);
                line += buf;
            }
            log("gpu passes (ms/frame): %s", line.c_str());
            g_acc.clear();
            g_frames = 0;
        }
    }];
}

void profRender(MTLRenderPassDescriptor* rp, const char* name, bool fullscreen) {
    int i = reserve(name);
    if (i < 0) return;
    MTLRenderPassSampleBufferAttachmentDescriptor* a = rp.sampleBufferAttachments[0];
    a.sampleBuffer = g_buf;
    a.startOfVertexSampleIndex = fullscreen ? MTLCounterDontSample : (NSUInteger)i;
    a.endOfVertexSampleIndex = MTLCounterDontSample;
    a.startOfFragmentSampleIndex = fullscreen ? (NSUInteger)i : MTLCounterDontSample;
    a.endOfFragmentSampleIndex = (NSUInteger)i + 1;
}

void profCompute(MTLComputePassDescriptor* cp, const char* name) {
    int i = reserve(name);
    if (i < 0) return;
    MTLComputePassSampleBufferAttachmentDescriptor* a = cp.sampleBufferAttachments[0];
    a.sampleBuffer = g_buf;
    a.startOfEncoderSampleIndex = (NSUInteger)i;
    a.endOfEncoderSampleIndex = (NSUInteger)i + 1;
}

void profBlit(MTLBlitPassDescriptor* bp, const char* name) {
    int i = reserve(name);
    if (i < 0) return;
    MTLBlitPassSampleBufferAttachmentDescriptor* a = bp.sampleBufferAttachments[0];
    a.sampleBuffer = g_buf;
    a.startOfEncoderSampleIndex = (NSUInteger)i;
    a.endOfEncoderSampleIndex = (NSUInteger)i + 1;
}

void profAccel(MTLAccelerationStructurePassDescriptor* ap, const char* name) {
    int i = reserve(name);
    if (i < 0) return;
    MTLAccelerationStructurePassSampleBufferAttachmentDescriptor* a = ap.sampleBufferAttachments[0];
    a.sampleBuffer = g_buf;
    a.startOfEncoderSampleIndex = (NSUInteger)i;
    a.endOfEncoderSampleIndex = (NSUInteger)i + 1;
}

} // namespace m189
