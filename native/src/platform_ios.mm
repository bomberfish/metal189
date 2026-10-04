// metal189: the window on iOS (experimental, for launchers such as PojavLauncher).
//
// There is no window of our own to create: the host app (the launcher) owns the UIWindow
// and runs UIKit on the main thread, while the game runs on a JVM thread. The "window" is a
// full-screen view backed by a CAMetalLayer, added on top of the host's key window. Input
// arrives as the same events the macOS window produces (platform_window.mm), so the Java
// side's LWJGL logic is unchanged:
//
// * hardware keyboards: HID usages mapped to macOS virtual key codes;
// * a mouse or trackpad (iPad): pointer position, buttons and the scroll wheel;
// * touch: in menus a finger is the mouse (down, drag, up). In game (cursor grabbed) a
//   drag turns the camera, a tap is a left click and a two-finger tap a right click.
//
// The event queue, logging and timing are shared with macOS (platform_window.mm).
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE

#import "m189.h"
#import "engine.h"
#include <algorithm>
#include <cmath>

using namespace m189;

namespace m189 { bool g_ctrlClickRight = false; }   // a macOS setting; nothing to do on iOS

namespace {

enum : int32_t {   // window flags (metal189.platform.NativeWindow)
    WF_RESIZABLE  = 1 << 0,
    WF_RETINA     = 1 << 1,   // render at the screen's scale instead of 1x
    WF_BACKGROUND = 1 << 2,
    WF_OFFSCREEN  = 1 << 3,
};

UIView* g_view = nil;
CAMetalLayer* g_layer = nil;
int32_t g_flags = 0;
bool g_cursorGrabbed = false;

// macOS virtual key codes (kVK_*) for USB HID keyboard usages; -1 where macOS has none.
int macKeyCode(long hid) {
    static const int16_t letters[26] = {0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06};
    static const int16_t digits[10] = {0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D};   // 1..9, 0
    static const int16_t fkeys[12] = {0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F};
    static const int16_t keypad[10] = {0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x52};    // 1..9, 0
    if (hid >= 0x04 && hid <= 0x1D) return letters[hid - 0x04];
    if (hid >= 0x1E && hid <= 0x27) return digits[hid - 0x1E];
    if (hid >= 0x3A && hid <= 0x45) return fkeys[hid - 0x3A];
    if (hid >= 0x59 && hid <= 0x62) return keypad[hid - 0x59];
    switch (hid) {
        case 0x28: return 0x24;   // return
        case 0x29: return 0x35;   // escape
        case 0x2A: return 0x33;   // backspace
        case 0x2B: return 0x30;   // tab
        case 0x2C: return 0x31;   // space
        case 0x2D: return 0x1B;   // -
        case 0x2E: return 0x18;   // =
        case 0x2F: return 0x21;   // [
        case 0x30: return 0x1E;   // ]
        case 0x31: return 0x2A;   // backslash
        case 0x33: return 0x29;   // ;
        case 0x34: return 0x27;   // '
        case 0x35: return 0x32;   // `
        case 0x36: return 0x2B;   // ,
        case 0x37: return 0x2F;   // .
        case 0x38: return 0x2C;   // /
        case 0x39: return 0x39;   // caps lock
        case 0x4A: return 0x73;   // home
        case 0x4B: return 0x74;   // page up
        case 0x4C: return 0x75;   // forward delete
        case 0x4D: return 0x77;   // end
        case 0x4E: return 0x79;   // page down
        case 0x4F: return 0x7C;   // right
        case 0x50: return 0x7B;   // left
        case 0x51: return 0x7D;   // down
        case 0x52: return 0x7E;   // up
        case 0x54: return 0x4B;   // keypad /
        case 0x55: return 0x43;   // keypad *
        case 0x56: return 0x4E;   // keypad -
        case 0x57: return 0x45;   // keypad +
        case 0x58: return 0x4C;   // keypad enter
        case 0x63: return 0x41;   // keypad .
        case 0xE0: return 0x3B;   // left control
        case 0xE1: return 0x38;   // left shift
        case 0xE2: return 0x3A;   // left option
        case 0xE3: return 0x37;   // left command
        case 0xE4: return 0x3E;   // right control
        case 0xE5: return 0x3C;   // right shift
        case 0xE6: return 0x3D;   // right option
        case 0xE7: return 0x36;   // right command
        default: return -1;
    }
}

float renderScale(UIView* v) {
    if (g_flags & WF_RETINA) return (float)(v.window ? v.window.screen.scale : UIScreen.mainScreen.scale);
    return 1.0f;
}

UIWindow* hostWindow() {
    UIWindow* any = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* w in ((UIWindowScene*)scene).windows) {
            if (w.isKeyWindow) return w;
            if (!any) any = w;
        }
    }
    return any;
}

} // namespace

@interface M189IOSView : UIView
@end

@implementation M189IOSView {
    UITouch* _primary;              // the finger acting as the mouse
    CGPoint _last;                  // its last position (points, top-left origin)
    CGPoint _start;
    NSTimeInterval _startTime;
    bool _moved, _down, _secondFinger;
}

+ (Class)layerClass { return CAMetalLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAMetalLayer* layer = (CAMetalLayer*)self.layer;
        layer.device = m189::device();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.maximumDrawableCount = 3;
        layer.allowsNextDrawableTimeout = YES;
        layer.opaque = YES;
        g_layer = layer;
        // a mouse or trackpad pointing without a button down
        if (@available(iOS 13.0, *))
            [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)]];
        // scrolling with a mouse wheel or two fingers on a trackpad
        UIPanGestureRecognizer* scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
        if (@available(iOS 13.4, *)) {
            scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
            scroll.allowedTouchTypes = @[];   // scroll events only, not finger drags
        }
        [self addGestureRecognizer:scroll];
    }
    return self;
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)layoutSubviews {
    [super layoutSubviews];
    float scale = renderScale(self);
    CGSize pts = self.bounds.size;
    int w = std::max(1, (int)lround(pts.width * scale)), h = std::max(1, (int)lround(pts.height * scale));
    g_layer.contentsScale = scale;
    g_layer.drawableSize = CGSizeMake(w, h);
    WindowInfo& info = windowInfo();
    bool changed = info.pixelWidth.load() != w || info.pixelHeight.load() != h;
    info.pixelWidth = w;
    info.pixelHeight = h;
    info.backingScale = scale;
    info.screenScale = (float)(self.window ? self.window.screen.scale : UIScreen.mainScreen.scale);
    if (changed) pushEvent({EV_RESIZE, w, h, 0, scale, 0, 0, 0, nowNanos()});
}

// positions as AppKit reports them: points from the bottom-left corner
- (void)pushMoveAt:(CGPoint)p dx:(float)dx dy:(float)dy dz:(int)dz {
    pushEvent({EV_MOUSE_MOVE, 0, 0, dz, (float)p.x, (float)(self.bounds.size.height - p.y), dx, dy, nowNanos()});
}

- (void)button:(int)b down:(bool)down {
    pushEvent({EV_MOUSE_BUTTON, b, 0, down ? 1 : 0, 0, 0, 0, 0, nowNanos()});
}

- (void)hover:(UIHoverGestureRecognizer*)g API_AVAILABLE(ios(13.0)) {
    CGPoint p = [g locationInView:self];
    [self pushMoveAt:p dx:(float)(p.x - _last.x) dy:(float)(p.y - _last.y) dz:0];
    _last = p;
}

- (void)scroll:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    if (t.y == 0 && t.x == 0) return;
    // NSEvent scroll deltas: positive up/left, in lines (about 10 points each)
    [self pushMoveAt:[g locationInView:self] dx:(float)(t.x / 10.0) dy:(float)(t.y / 10.0) dz:1];
}

static int pointerButton(UIEvent* e) {
    if (@available(iOS 13.4, *)) {
        if (e.buttonMask & UIEventButtonMaskSecondary) return 1;
    }
    return 0;
}

static bool isPointer(UITouch* t) {
    if (@available(iOS 13.4, *)) return t.type == UITouchTypeIndirectPointer;
    return false;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self becomeFirstResponder];
    for (UITouch* t in touches) {
        CGPoint p = [t locationInView:self];
        if (isPointer(t)) {
            [self pushMoveAt:p dx:0 dy:0 dz:0];
            [self button:pointerButton(event) down:true];
            _last = p;
            continue;
        }
        if (_primary) {   // a second finger
            _secondFinger = true;
            continue;
        }
        _primary = t;
        _last = _start = p;
        _startTime = t.timestamp;
        _moved = false;
        _secondFinger = false;
        [self pushMoveAt:p dx:0 dy:0 dz:0];
        if (!g_cursorGrabbed) {   // menus: the finger is the mouse
            [self button:0 down:true];
            _down = true;
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        CGPoint p = [t locationInView:self];
        if (t != _primary && !isPointer(t)) continue;
        if (hypot(p.x - _start.x, p.y - _start.y) > 8.0) _moved = true;
        // in game, deltas turn the camera (NSEvent deltaY: positive downwards)
        [self pushMoveAt:p dx:(float)(p.x - _last.x) dy:(float)(p.y - _last.y) dz:0];
        _last = p;
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        if (isPointer(t)) {
            [self button:pointerButton(event) down:false];
            [self button:1 - pointerButton(event) down:false];
            continue;
        }
        if (t != _primary) continue;
        if (_down) {
            [self button:0 down:false];
            _down = false;
        } else if (!_moved && t.timestamp - _startTime < 0.3) {
            // a tap in game: a click (two fingers: the right button)
            int b = _secondFinger ? 1 : 0;
            [self button:b down:true];
            [self button:b down:false];
        }
        _primary = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_down) [self button:0 down:false];
    _down = false;
    _primary = nil;
}

// ---- hardware keyboards ----
- (void)keys:(NSSet<UIPress*>*)presses down:(bool)down API_AVAILABLE(ios(13.4)) {
    for (UIPress* p in presses) {
        UIKey* k = p.key;
        if (!k) continue;
        int code = macKeyCode((long)k.keyCode);
        if (code < 0) continue;
        NSString* s = k.characters;
        unichar ch = s.length > 0 ? [s characterAtIndex:0] : 0;
        pushEvent({EV_KEY, code, (int32_t)ch, down ? 1 : 0, 0, 0, 0, 0, nowNanos()});
    }
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    if (@available(iOS 13.4, *)) [self keys:presses down:true];
    else [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    if (@available(iOS 13.4, *)) [self keys:presses down:false];
    else [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    if (@available(iOS 13.4, *)) [self keys:presses down:false];
    else [super pressesCancelled:presses withEvent:event];
}
@end

// ---------------------------------------------------------------------------
// API used by the JNI layer (the same as the macOS window's)

namespace m189 {

CAMetalLayer* metalLayer() { return g_layer; }

bool windowCreate(int width, int height, NSString* title, int32_t flags) {
    __block bool ok = false;
    g_flags = flags;
    runOnMain(^{
        UIWindow* host = hostWindow();
        if (!host) {
            log("ios: no window to draw into");
            return;
        }
        UIView* parent = host.rootViewController.view ?: host;
        M189IOSView* view = [[M189IOSView alloc] initWithFrame:parent.bounds];
        [parent addSubview:view];
        [view becomeFirstResponder];
        [view layoutIfNeeded];
        g_view = view;
        WindowInfo& info = windowInfo();
        info.visible = true;
        info.focused = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        info.mouseInside = true;
        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification*) {
            windowInfo().focused = true;
            pushEvent({EV_FOCUS, 1, 0, 0, 0, 0, 0, 0, nowNanos()});
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification*) {
            windowInfo().focused = false;
            pushEvent({EV_FOCUS, 0, 0, 0, 0, 0, 0, 0, nowNanos()});
        }];
        log("ios: drawing into a %dx%d layer over %s", windowInfo().pixelWidth.load(), windowInfo().pixelHeight.load(),
            NSStringFromClass(parent.class).UTF8String);
        ok = g_layer != nil;
    });
    return ok;
}

void windowDestroy() {
    runOnMain(^{
        [g_view removeFromSuperview];
        g_view = nil;
    });
}

void windowSetTitle(NSString* title) {}
void windowSetResizable(bool r) {}
void windowSetSize(int w, int h) {}   // the host app decides the size
void windowSetFullscreen(bool fs) { windowInfo().fullscreen = fs; }
void windowSetVSync(bool on) { setVSync(on); }   // iOS layers always present on the refresh

void cursorSetGrabbed(bool grab) { g_cursorGrabbed = grab; }
void cursorSetPosition(int x, int y) {}

void desktopMode(int* out) {
    runOnMain(^{
        UIScreen* sc = g_view.window.screen ?: UIScreen.mainScreen;
        float s = (g_flags & WF_RETINA) ? (float)sc.scale : 1.0f;
        out[0] = (int)(sc.bounds.size.width * s);
        out[1] = (int)(sc.bounds.size.height * s);
        out[2] = (int)sc.maximumFramesPerSecond;
        out[3] = 32;
    });
}

} // namespace m189

#endif // TARGET_OS_IPHONE
