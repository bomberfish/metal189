// metal189: native window, CAMetalLayer and input event capture (macOS; the event queue,
// logging and timing are shared with iOS, whose window is in platform_ios.mm).
//
// AppKit runs on the process main thread (AWT's NSApplication run loop). The
// Minecraft client thread calls in through JNI; anything touching AppKit is
// marshalled onto the main thread. Input events are queued here and drained by
// the Java side once per frame (Display.processMessages).

#import "m189.h"
#import "engine.h"
#include <mutex>
#include <vector>
#include <mach/mach_time.h>

namespace m189 {

static std::mutex g_evMutex;
static std::vector<Event> g_events;
static WindowInfo g_info;

WindowInfo& windowInfo() { return g_info; }

int64_t nowNanos() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return (int64_t)(mach_absolute_time() * tb.numer / tb.denom);
}

void pushEvent(const Event& e) {
    std::lock_guard<std::mutex> lk(g_evMutex);
    if (g_events.size() < 65536) g_events.push_back(e);
}

int popEvents(Event* out, int max) {
    std::lock_guard<std::mutex> lk(g_evMutex);
    int n = (int)std::min<size_t>(g_events.size(), (size_t)max);
    if (n > 0) {
        memcpy(out, g_events.data(), sizeof(Event) * n);
        g_events.erase(g_events.begin(), g_events.begin() + n);
    }
    return n;
}

void log(const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[metal189/native] %s\n", buf);
    fflush(stderr);
}

void runOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

} // namespace m189

// The window itself: AppKit here, UIKit in platform_ios.mm.
#if !TARGET_OS_IPHONE

using namespace m189;

// ---------------------------------------------------------------------------
// Window configuration flags (shared with Java, see metal189.platform.NativeWindow)
enum : int32_t {
    WF_RESIZABLE  = 1 << 0,
    WF_RETINA     = 1 << 1,  // render at backing scale instead of 1x like vanilla
    WF_BACKGROUND = 1 << 2,  // test mode: never activate or become key
    WF_OFFSCREEN  = 1 << 3,  // test mode: no visible window at all
};

static NSWindow* g_window = nil;
static CAMetalLayer* g_layer = nil;
static int32_t g_flags = 0;
static bool g_cursorGrabbed = false;
static bool g_cursorHidden = false;
static id<NSObject> g_activity = nil;

CAMetalLayer* m189::metalLayer() { return g_layer; }

@interface M189View : NSView <NSWindowDelegate>
@end

static float currentRenderScale(NSWindow* w) {
    if (g_flags & WF_RETINA) return (float)(w ? w.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor);
    return 1.0f;
}

static void updateDrawableSize(M189View* view) {
    if (!g_layer) return;
    float scale = currentRenderScale(view.window);
    NSSize pts = view.bounds.size;
    int w = std::max(1, (int)lround(pts.width * scale));
    int h = std::max(1, (int)lround(pts.height * scale));
    g_layer.contentsScale = scale;
    g_layer.drawableSize = CGSizeMake(w, h);
    bool changed = g_info.pixelWidth.load() != w || g_info.pixelHeight.load() != h;
    g_info.pixelWidth = w;
    g_info.pixelHeight = h;
    g_info.backingScale = scale;
    g_info.screenScale = (float)(view.window ? view.window.backingScaleFactor : 1.0);
    if (changed) pushEvent({EV_RESIZE, w, h, 0, scale, 0, 0, 0, nowNanos()});
}

// NSEvent timestamps converted exactly like LWJGL: (jlong)(timestamp * 1e9).
static int64_t evNanos(NSEvent* e) { return (int64_t)(e.timestamp * 1000000000.0); }

// LWJGL's flagsChanged: keycodes 54..63 map to these modifier masks.
static const uint64_t kModifierMasks[10] = {
    0x10, 0x8, 0x2, 0x10000, 0x20, 0x1, 0x4, 0x40, 0x2000, 0x800000,
};
static uint64_t g_lastModifierFlags = 0;
static bool g_leftMouseDown = false, g_rightMouseDown = false;
// LWJGL turns Ctrl+left click into a right click on macOS. metal189 keeps it a left click
// unless the Ctrl+Click setting asks for LWJGL's behaviour (Config.applyInput).
namespace m189 { bool g_ctrlClickRight = false; }
using m189::g_ctrlClickRight;

@implementation M189View {
    NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    return self;
}

- (CALayer*)makeBackingLayer {
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = m189::device();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.maximumDrawableCount = 3;
    layer.displaySyncEnabled = NO;
    layer.allowsNextDrawableTimeout = YES;
    layer.needsDisplayOnBoundsChange = NO;
    layer.opaque = YES;
    // Vanilla's GL surface is not colour managed; keep values untouched.
    layer.colorspace = nil;
    g_layer = layer;
    return layer;
}

- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {}
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

// Same tracking setup as LWJGL: entered/exited only (moves come from
// acceptsMouseMovedEvents), and the inside state is re-evaluated on update.
- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
    NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    if (NSPointInRect(p, self.bounds)) [self mouseEntered:nil];
    else [self mouseExited:nil];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    updateDrawableSize(self);
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    updateDrawableSize(self);
    pushEvent({EV_SCALE, 0, 0, 0, (float)(self.window ? self.window.backingScaleFactor : 1.0), 0, 0, 0, nowNanos()});
}

// ---- keyboard (LWJGL: keyPressed/keyReleased(keyCode, characters, nanos)) ----
static void pushKey(NSEvent* e, int state) {
    NSString* s = e.characters;
    unichar ch = s.length > 0 ? [s characterAtIndex:0] : 0;
    pushEvent({EV_KEY, (int32_t)e.keyCode, (int32_t)ch, state, 0, 0, 0, 0, evNanos(e)});
}

- (void)keyDown:(NSEvent*)e { pushKey(e, 1); }
- (void)keyUp:(NSEvent*)e { pushKey(e, 0); }

- (void)flagsChanged:(NSEvent*)e {
    uint64_t flags = e.modifierFlags;
    int code = e.keyCode;
    uint64_t mask;
    int idx = code - 54;
    if (idx >= 0 && idx < 10) {
        mask = kModifierMasks[idx];
    } else {
        // LWJGL treats an unknown modifier as a left-command release when that
        // flag just went away; anything else is logged and ignored.
        if ((flags & 8) != 0 || (g_lastModifierFlags & 8) == 0) return;
        mask = ~0ull;
        code = 0x37;
    }
    g_lastModifierFlags = flags;
    int state = (mask & ~flags) != 0 ? 0 : 1;
    pushEvent({EV_KEY, code, 0, state, 0, 0, 0, 0, evNanos(e)});
}

// ---- mouse ----
- (NSPoint)viewPos:(NSEvent*)e { return [self convertPoint:e.locationInWindow fromView:nil]; }

- (void)button:(NSEvent*)e index:(int)b state:(int)down {
    pushEvent({EV_MOUSE_BUTTON, b, 0, down, 0, 0, 0, 0, evNanos(e)});
}

- (void)pushMove:(NSEvent*)e dz:(int)dz {
    NSPoint p = [self viewPos:e];
    pushEvent({EV_MOUSE_MOVE, 0, 0, dz, (float)p.x, (float)p.y, (float)e.deltaX, (float)e.deltaY, evNanos(e)});
}

// Ctrl-click becomes a right click only when g_ctrlClickRight (LWJGL's macOS behaviour) is on.
- (void)mouseDown:(NSEvent*)e {
    if (g_ctrlClickRight && (e.modifierFlags & NSEventModifierFlagControl)) {
        g_rightMouseDown = true;
        [self rightMouseDown:e];
    } else {
        g_leftMouseDown = true;
        [self button:e index:0 state:1];
    }
}
- (void)mouseUp:(NSEvent*)e {
    if (g_rightMouseDown) { g_rightMouseDown = false; [self rightMouseUp:e]; }
    if (g_leftMouseDown) { g_leftMouseDown = false; [self button:e index:0 state:0]; }
}
- (void)rightMouseDown:(NSEvent*)e { [self button:e index:1 state:1]; }
- (void)rightMouseUp:(NSEvent*)e { [self button:e index:1 state:0]; }
- (void)otherMouseDown:(NSEvent*)e { [self button:e index:2 state:1]; }
- (void)otherMouseUp:(NSEvent*)e { [self button:e index:2 state:0]; }
- (void)mouseMoved:(NSEvent*)e { [self pushMove:e dz:0]; }
- (void)mouseDragged:(NSEvent*)e { [self pushMove:e dz:0]; }
- (void)rightMouseDragged:(NSEvent*)e { [self pushMove:e dz:0]; }
- (void)otherMouseDragged:(NSEvent*)e { [self pushMove:e dz:0]; }
- (void)scrollWheel:(NSEvent*)e { [self pushMove:e dz:1]; }
- (void)mouseEntered:(NSEvent*)e { g_info.mouseInside = true; pushEvent({EV_MOUSE_INSIDE, 1, 0, 0, 0, 0, 0, 0, nowNanos()}); }
- (void)mouseExited:(NSEvent*)e { g_info.mouseInside = false; pushEvent({EV_MOUSE_INSIDE, 0, 0, 0, 0, 0, 0, 0, nowNanos()}); }

// ---- window delegate ----
- (BOOL)windowShouldClose:(NSWindow*)w {
    g_info.closeRequested = true;
    pushEvent({EV_CLOSE, 0, 0, 0, 0, 0, 0, 0, nowNanos()});
    return NO;
}
- (void)windowDidBecomeKey:(NSNotification*)n {
    g_info.focused = true;
    pushEvent({EV_FOCUS, 1, 0, 0, 0, 0, 0, 0, nowNanos()});
}
- (void)windowDidResignKey:(NSNotification*)n {
    g_info.focused = false;
    pushEvent({EV_FOCUS, 0, 0, 0, 0, 0, 0, 0, nowNanos()});
}
- (void)windowDidMiniaturize:(NSNotification*)n { g_info.visible = false; }
- (void)windowDidDeminiaturize:(NSNotification*)n { g_info.visible = true; }
- (void)windowDidChangeBackingProperties:(NSNotification*)n { updateDrawableSize(self); }
@end

// ---------------------------------------------------------------------------
// API used by the JNI layer

namespace m189 {

bool windowCreate(int width, int height, NSString* title, int32_t flags) {
    __block bool ok = true;
    g_flags = flags;
    runOnMain(^{
        if (!NSApp) [NSApplication sharedApplication];
        if (flags & WF_BACKGROUND) {
            // Keep test runs from App Nap throttling without ever taking focus.
            g_activity = [[NSProcessInfo processInfo]
                beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                  reason:@"metal189 rendering"];
        }
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        if (flags & WF_RESIZABLE) style |= NSWindowStyleMaskResizable;
        NSWindow* win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.releasedWhenClosed = NO;
        win.title = title ?: @"Minecraft 1.8.9";
        win.acceptsMouseMovedEvents = YES;
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        win.restorable = NO;
        M189View* view = [[M189View alloc] initWithFrame:frame];
        win.contentView = view;
        win.delegate = view;
        [win makeFirstResponder:view];
        [win center];
        g_window = win;
        if (!(flags & WF_OFFSCREEN)) {
            if (flags & WF_BACKGROUND) {
                [win orderBack:nil];
            } else {
                [win makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES];
            }
        }
        [view layoutSubtreeIfNeeded];
        updateDrawableSize(view);
        g_info.visible = !(flags & WF_OFFSCREEN);
        g_info.focused = win.isKeyWindow;
        if (!g_layer) ok = false;
    });
    return ok;
}

void windowDestroy() {
    runOnMain(^{
        if (g_window) { [g_window orderOut:nil]; [g_window close]; }
        g_window = nil;
        if (g_cursorHidden) { CGDisplayShowCursor(CGMainDisplayID()); g_cursorHidden = false; }
        if (g_cursorGrabbed) { CGAssociateMouseAndMouseCursorPosition(true); g_cursorGrabbed = false; }
        if (g_activity) { [[NSProcessInfo processInfo] endActivity:g_activity]; g_activity = nil; }
    });
}

void windowSetTitle(NSString* title) {
    runOnMain(^{ if (g_window) g_window.title = title; });
}

void windowSetResizable(bool r) {
    runOnMain(^{
        if (!g_window) return;
        NSWindowStyleMask m = g_window.styleMask;
        g_window.styleMask = r ? (m | NSWindowStyleMaskResizable) : (m & ~NSWindowStyleMaskResizable);
    });
}

void windowSetSize(int w, int h) {
    runOnMain(^{
        if (!g_window) return;
        float s = currentRenderScale(g_window);
        [g_window setContentSize:NSMakeSize(w / s, h / s)];
    });
}

void windowSetFullscreen(bool fs) {
    runOnMain(^{
        if (!g_window || (g_flags & WF_OFFSCREEN)) return;
        bool isFs = (g_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
        if (isFs != fs) [g_window toggleFullScreen:nil];
        g_info.fullscreen = fs;
    });
}

void windowSetVSync(bool on) {
    setVSync(on);
    runOnMain(^{ if (g_layer) g_layer.displaySyncEnabled = on; });
}

// LWJGL nGrabMouse: disassociate the cursor and hide it; no warping.
void cursorSetGrabbed(bool grab) {
    runOnMain(^{
        g_cursorGrabbed = grab;
        CGAssociateMouseAndMouseCursorPosition(!grab);
        if (grab) {
            if (!g_cursorHidden) { CGDisplayHideCursor(CGMainDisplayID()); g_cursorHidden = true; }
        } else if (g_cursorHidden) {
            CGDisplayShowCursor(CGMainDisplayID());
            g_cursorHidden = false;
        }
    });
}

// LWJGL nSetCursorPosition (windowed path): x from the content's left edge,
// y measured from the content's top edge, in points.
void cursorSetPosition(int x, int y) {
    runOnMain(^{
        if (!g_window) return;
        NSView* v = g_window.contentView;
        NSRect wf = g_window.frame;
        NSRect vf = v.frame;
        NSPoint o = [v convertPoint:vf.origin fromView:nil];
        NSScreen* primary = NSScreen.screens.firstObject;
        double screenH = primary.frame.size.height;
        double gx = wf.origin.x + o.x + x;
        double gy = screenH - (vf.size.height - y - 1.0 + wf.origin.y + o.y) - 1.0;
        CGWarpMouseCursorPosition(CGPointMake(gx, gy));
        if (g_cursorGrabbed) CGAssociateMouseAndMouseCursorPosition(false);
    });
}

void desktopMode(int* out) {
    runOnMain(^{
        NSScreen* sc = g_window.screen ?: NSScreen.mainScreen;
        float s = (g_flags & WF_RETINA) ? (float)sc.backingScaleFactor : 1.0f;
        out[0] = (int)(sc.frame.size.width * s);
        out[1] = (int)(sc.frame.size.height * s);
        out[2] = (int)sc.maximumFramesPerSecond;
        out[3] = 32;
    });
}

} // namespace m189

#endif // !TARGET_OS_IPHONE
