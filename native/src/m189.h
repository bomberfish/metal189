// metal189 native core: shared declarations.
#pragma once

#include <jni.h>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <atomic>

#include <TargetConditionals.h>

#ifdef __OBJC__
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

namespace m189 {

// ---------------------------------------------------------------------------
// Logging (routed to stderr; the Java side mirrors it into the game log)
void log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// ---------------------------------------------------------------------------
// Input/window events, produced on the AppKit thread and drained by Java.
// Values mirror what LWJGL 2's MacOSXOpenGLView hands to its Java listeners,
// so the Java side can apply LWJGL's own logic unchanged.
enum EventType : int32_t {
    EV_KEY = 1,          // a = mac keycode, b = first UTF-16 unit of [event characters] (0 if none), c = 1 press / 0 release
    EV_MOUSE_BUTTON = 2, // a = LWJGL button (0 left, 1 right / ctrl-click, 2 any other), c = 1 down / 0 up
    EV_MOUSE_MOVE = 3,   // f0/f1 = view position (points, bottom-left origin), f2/f3 = NSEvent deltaX/deltaY, c = dz (1 for scroll wheel)
    EV_FOCUS = 5,        // a = focused
    EV_RESIZE = 6,       // a = width px, b = height px
    EV_CLOSE = 7,
    EV_MOUSE_INSIDE = 8, // a = inside
    EV_SCALE = 10,       // f0 = window backingScaleFactor
    EV_CHAR = 11,        // b = UTF-16 unit typed without a key event (iOS on-screen keyboards)
};

struct Event {
    int32_t type, a, b, c;
    float f0, f1, f2, f3;
    int64_t time; // NSEvent timestamp in nanoseconds (as LWJGL computes it)
};
static_assert(sizeof(Event) == 40, "Event layout is shared with Java");

void pushEvent(const Event& e);
int popEvents(Event* out, int max);
void platformPumpEvents();   // delivers input a host app queued (iOS / Amethyst); nothing on macOS

// Window state readable from any thread.
struct WindowInfo {
    std::atomic<int32_t> pixelWidth{854}, pixelHeight{480};
    std::atomic<float> backingScale{1.0f};   // scale we render at (1 unless retina mode)
    std::atomic<float> screenScale{1.0f};    // the screen's backingScaleFactor
    std::atomic<bool> focused{false}, visible{false}, mouseInside{false}, closeRequested{false};
    std::atomic<bool> fullscreen{false};
};
WindowInfo& windowInfo();

int64_t nowNanos();

} // namespace m189

#ifdef __OBJC__
namespace m189 {
CAMetalLayer* metalLayer();      // nil until a window exists
id<MTLDevice> device();
void runOnMain(void (^block)(void));   // synchronously on the main (UI) thread
}
#endif
