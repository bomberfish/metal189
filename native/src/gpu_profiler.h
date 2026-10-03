// metal189: per-pass GPU timing from Metal timestamp counters (enabled with -Dmetal189.gpuStats).
#pragma once
#import "engine.h"

namespace m189 {

// Starts a profiled frame (call once per command buffer before adding passes).
void profBeginFrame(id<MTLCommandBuffer> cb);
// Attaches timestamp sampling for a named pass to a pass descriptor. Fullscreen passes
// time their fragment stage only (their vertex stage starts early and would include
// waiting on the previous pass).
void profRender(MTLRenderPassDescriptor* rp, const char* name, bool fullscreen = false);
void profCompute(MTLComputePassDescriptor* cp, const char* name);
void profBlit(MTLBlitPassDescriptor* bp, const char* name);
void profAccel(MTLAccelerationStructurePassDescriptor* ap, const char* name);
bool profEnabled();

} // namespace m189
