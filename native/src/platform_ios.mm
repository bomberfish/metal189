// metal189: the window on iOS (experimental, for launchers such as Amethyst / PojavLauncher).
//
// There is no window of our own to create: the host app (the launcher) owns the UIWindow
// and runs UIKit on the main thread, while the game runs on a JVM thread.
//
// Under Amethyst (https://github.com/AngelAuraMC/Amethyst-iOS) metal189 uses the launcher's
// own game surface and input, through the C side of its GLFW (input_bridge_v3.m,
// egl_bridge.m): with the client API hint set to GLFW_NO_API, pojavCreateContext hands back
// the surface's CAMetalLayer instead of making a GL context; callbacks registered like
// LWJGL 3's receive what its touch controls, virtual mouse, keyboard and gamepad send, and
// are delivered when the game thread pumps them each frame (platformPumpEvents). Mouse grab
// goes back to the launcher, which switches its controls between menus and the game.
//
// Elsewhere the "window" is a full-screen view backed by a CAMetalLayer, added on top of
// the host's key window. Input arrives as the same events the macOS window produces
// (platform_window.mm), so the Java side's LWJGL logic is unchanged:
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
#include <dlfcn.h>

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

// ---------------------------------------------------------------------------
// Amethyst: its GLFW's C entry points, looked up in the process

namespace amethyst {

typedef void KeyFn(void*, int, int, int, int);
typedef void CharFn(void*, unsigned int);
typedef void CharModsFn(void*, unsigned int, int);
typedef void CursorPosFn(void*, double, double);
typedef void MouseButtonFn(void*, int, int, int);
typedef void ScrollFn(void*, double, double);
typedef void SizeFn(void*, int, int);
typedef jlong SetCallbackFn(JNIEnv*, jclass, jlong window, jlong callback);

int (*init)(BOOL useStackQueue) = nullptr;
void (*setWindowHint)(int hint, int value) = nullptr;
void* (*createContext)(void* share) = nullptr;
void (*pump)(void* window) = nullptr;
void (*rewind)(void) = nullptr;
void (*setShowingWindow)(JNIEnv*, jclass, jlong) = nullptr;
void (*setGrabbing)(JNIEnv*, jclass, jboolean, jfloat, jfloat) = nullptr;
int* windowWidth = nullptr;
int* windowHeight = nullptr;
jboolean* hostGrabbing = nullptr;   // Amethyst's own idea of whether the game holds the mouse (diagnostics)
long movesGrabbed = 0;              // cursor callbacks while grabbed, and their summed movement (diagnostics)
double movedGrabbed = 0;
void* window = nullptr;   // the surface's layer (Amethyst's window handle)
bool active = false;

constexpr int GLFW_CLIENT_API = 0x22001, GLFW_NO_API = 0;

// macOS virtual key codes (kVK_*) for GLFW key codes; -1 where macOS has none
int macKeyCode(int k) {
    if (k >= 'A' && k <= 'Z') {
        static const int16_t letters[26] = {0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06};
        return letters[k - 'A'];
    }
    if (k >= '0' && k <= '9') {
        static const int16_t digits[10] = {0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19};   // 0..9
        return digits[k - '0'];
    }
    if (k >= 290 && k <= 301) {   // F1..F12
        static const int16_t f[12] = {0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F};
        return f[k - 290];
    }
    if (k >= 320 && k <= 329) {   // keypad 0..9
        static const int16_t kp[10] = {0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C};
        return kp[k - 320];
    }
    switch (k) {
        case 32: return 0x31;  case 39: return 0x27;  case 44: return 0x2B;  case 45: return 0x1B;
        case 46: return 0x2F;  case 47: return 0x2C;  case 59: return 0x29;  case 61: return 0x18;
        case 91: return 0x21;  case 92: return 0x2A;  case 93: return 0x1E;  case 96: return 0x32;
        case 256: return 0x35; case 257: return 0x24; case 258: return 0x30; case 259: return 0x33;
        case 261: return 0x75; case 262: return 0x7C; case 263: return 0x7B; case 264: return 0x7D;
        case 265: return 0x7E; case 266: return 0x74; case 267: return 0x79; case 268: return 0x73;
        case 269: return 0x77; case 280: return 0x39;
        case 330: return 0x41; case 331: return 0x4B; case 332: return 0x43; case 333: return 0x4E;
        case 334: return 0x45; case 335: return 0x4C; case 336: return 0x51;
        case 340: return 0x38; case 341: return 0x3B; case 342: return 0x3A; case 343: return 0x37;
        case 344: return 0x3C; case 345: return 0x3E; case 346: return 0x3D; case 347: return 0x36;
        default: return -1;
    }
}

// GLFW reports a key press and the character it types separately (key first); macOS key
// events carry both, so a press waits for its character until the next callback.
int pendingKey = -1;
double lastX = 0, lastY = 0;
bool haveCursor = false;

void flushKey() {
    if (pendingKey >= 0) pushEvent({EV_KEY, pendingKey, 0, 1, 0, 0, 0, 0, nowNanos()});
    pendingKey = -1;
}

void resize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    WindowInfo& info = windowInfo();
    bool changed = info.pixelWidth.load() != w || info.pixelHeight.load() != h;
    info.pixelWidth = w;
    info.pixelHeight = h;
    CAMetalLayer* layer = g_layer;
    dispatch_async(dispatch_get_main_queue(), ^{ layer.drawableSize = CGSizeMake(w, h); });
    if (changed) pushEvent({EV_RESIZE, w, h, 0, 1.0f, 0, 0, 0, nowNanos()});
}

void onKey(void*, int key, int scancode, int action, int mods) {
    flushKey();
    int code = macKeyCode(key);
    if (code < 0) return;
    if (action == 0) pushEvent({EV_KEY, code, 0, 0, 0, 0, 0, 0, nowNanos()});
    else pendingKey = code;   // press or repeat: its character may follow
}

void onChar(void*, unsigned int cp) {
    if (cp > 0xFFFF) cp = 0xFFFD;
    if (pendingKey >= 0) {
        pushEvent({EV_KEY, pendingKey, (int32_t)cp, 1, 0, 0, 0, 0, nowNanos()});
        pendingKey = -1;
    } else {
        pushEvent({EV_CHAR, 0, (int32_t)cp, 1, 0, 0, 0, 0, nowNanos()});   // typed without a key (on-screen keyboard)
    }
}

void onCharMods(void* w, unsigned int cp, int) { onChar(w, cp); }

// window pixels from the top-left, as AppKit reports them: points (1 px) from the bottom-left
void onCursorPos(void*, double x, double y) {
    flushKey();
    double dx = haveCursor ? x - lastX : 0, dy = haveCursor ? y - lastY : 0;
    lastX = x;
    lastY = y;
    haveCursor = true;
    if (g_cursorGrabbed) {
        amethyst::movesGrabbed++;
        amethyst::movedGrabbed += fabs(dx) + fabs(dy);
    }
    float h = (float)windowInfo().pixelHeight.load();
    pushEvent({EV_MOUSE_MOVE, 0, 0, 0, (float)x, h - (float)y, (float)dx, (float)dy, nowNanos()});
}

void onMouseButton(void*, int button, int action, int) {
    flushKey();
    if (button < 0 || button > 2) button = 2;   // LWJGL on macOS: 0 left, 1 right, 2 any other
    pushEvent({EV_MOUSE_BUTTON, button, 0, action != 0 ? 1 : 0, 0, 0, 0, 0, nowNanos()});
}

void onScroll(void*, double xoff, double yoff) {
    flushKey();
    pushEvent({EV_MOUSE_MOVE, 0, 0, 1, (float)lastX, windowInfo().pixelHeight.load() - (float)lastY, (float)xoff, (float)yoff,
               nowNanos()});
}

void onSize(void*, int w, int h) { resize(w, h); }

template <typename T> bool find(T& fn, const char* name) {
    fn = (T)dlsym(RTLD_DEFAULT, name);
    return fn != nullptr;
}

// Amethyst's surface, if this process is Amethyst; nil otherwise (or when its renderer gives
// the surface no Metal layer).
CAMetalLayer* attach() {
    SetCallbackFn *setKey = nullptr, *setChar = nullptr, *setCharMods = nullptr, *setCursor = nullptr, *setButton = nullptr,
                  *setScroll = nullptr, *setFbSize = nullptr, *setWinSize = nullptr;
    bool ok = find(init, "pojavInit") && find(setWindowHint, "pojavSetWindowHint") && find(createContext, "pojavCreateContext") &&
              find(pump, "pojavPumpEvents") && find(rewind, "pojavRewindEvents") &&
              find(setShowingWindow, "Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow") &&
              find(setKey, "Java_org_lwjgl_glfw_GLFW_nglfwSetKeyCallback") &&
              find(setChar, "Java_org_lwjgl_glfw_GLFW_nglfwSetCharCallback") &&
              find(setCharMods, "Java_org_lwjgl_glfw_GLFW_nglfwSetCharModsCallback") &&
              find(setCursor, "Java_org_lwjgl_glfw_GLFW_nglfwSetCursorPosCallback") &&
              find(setButton, "Java_org_lwjgl_glfw_GLFW_nglfwSetMouseButtonCallback") &&
              find(setScroll, "Java_org_lwjgl_glfw_GLFW_nglfwSetScrollCallback") &&
              find(setFbSize, "Java_org_lwjgl_glfw_GLFW_nglfwSetFramebufferSizeCallback") &&
              find(setWinSize, "Java_org_lwjgl_glfw_GLFW_nglfwSetWindowSizeCallback");
    if (!ok) return nil;
    find(setGrabbing, "Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing");
    find(hostGrabbing, "isGrabbing");
    find(windowWidth, "windowWidth");
    find(windowHeight, "windowHeight");
    log("ios: Amethyst found: using its game surface and input");
    init(YES);   // input queued for the game thread to pump
    setWindowHint(GLFW_CLIENT_API, GLFW_NO_API);   // no GL context: the surface's layer itself
    void* handle = createContext(nullptr);
    id layerObj = (__bridge id)handle;
    if (![layerObj isKindOfClass:CAMetalLayer.class]) {
        log("ios: Amethyst's surface has no Metal layer (the OSMesa/Zink renderer?); pick another renderer for this profile");
        return nil;
    }
    window = handle;
    setShowingWindow(nullptr, nullptr, (jlong)(uintptr_t)handle);
    setKey(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onKey);
    setChar(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onChar);
    setCharMods(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onCharMods);
    setCursor(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onCursorPos);
    setButton(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onMouseButton);
    setScroll(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onScroll);
    setFbSize(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onSize);
    setWinSize(nullptr, nullptr, (jlong)(uintptr_t)handle, (jlong)(uintptr_t)&onSize);
    active = true;
    return (CAMetalLayer*)layerObj;
}

} // namespace amethyst

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
    // Amethyst: its own surface and input (on this, the game thread, as LWJGL would call it)
    if (CAMetalLayer* layer = amethyst::attach()) {
        g_layer = layer;
        runOnMain(^{
            layer.device = m189::device();
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.maximumDrawableCount = 3;
            layer.allowsNextDrawableTimeout = YES;
            layer.opaque = YES;
        });
        int w = amethyst::windowWidth ? *amethyst::windowWidth : 0, h = amethyst::windowHeight ? *amethyst::windowHeight : 0;
        if (w <= 0 || h <= 0) {
            CGSize s = layer.bounds.size;
            float scale = (float)layer.contentsScale;
            w = (int)lround(s.width * scale);
            h = (int)lround(s.height * scale);
        }
        amethyst::resize(w, h);
        WindowInfo& info = windowInfo();
        info.backingScale = 1.0f;
        info.screenScale = 1.0f;
        info.visible = true;
        info.focused = true;
        info.mouseInside = true;
        log("ios: drawing into Amethyst's %dx%d surface", w, h);
        return true;
    }
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

void cursorSetGrabbed(bool grab) {
    g_cursorGrabbed = grab;
    // Amethyst switches its touch controls and virtual mouse between the game and menus, and
    // locks the pointer (mouse, trackpad) while the game holds it
    if (amethyst::active && amethyst::setGrabbing) amethyst::setGrabbing(nullptr, nullptr, grab, 0, 0);
    log("ios: mouse %s (Amethyst told: %s)", grab ? "grabbed" : "released",
        amethyst::active ? (amethyst::setGrabbing ? "yes" : "no hook") : "not Amethyst");
}

void platformPumpEvents() {
    if (!amethyst::active) return;
    {
        // diagnostics: what Amethyst and UIKit think, logged when it changes, and the cursor
        // movement that arrives while grabbed (every 5 seconds)
        static int lastHost = -1, lastLock = -1;
        static double lastReport = 0;
        int host = amethyst::hostGrabbing ? (int)*amethyst::hostGrabbing : -2;
        if (host != lastHost) {
            log("ios: Amethyst isGrabbing = %d", host);
            lastHost = host;
        }
        __block int lock = -1;
        static double lastLockCheck = 0;
        double now = CACurrentMediaTime();
        if (now - lastLockCheck > 1.0) {
            lastLockCheck = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindowScene* sc = nil;
                for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
                    if ([s isKindOfClass:UIWindowScene.class]) sc = (UIWindowScene*)s;
                int l = sc ? (sc.pointerLockState.locked ? 1 : 0) : -1;
                if (l != lastLock) {
                    log("ios: pointer locked = %d", l);
                    lastLock = l;
                }
            });
        }
        (void)lock;
        if (now - lastReport > 5.0) {
            if (g_cursorGrabbed) log("ios: %ld cursor moves while grabbed in 5 s (%.0f px)", amethyst::movesGrabbed, amethyst::movedGrabbed);
            amethyst::movesGrabbed = 0;
            amethyst::movedGrabbed = 0;
            lastReport = now;
        }
    }
    amethyst::pump(amethyst::window);
    amethyst::rewind();
    amethyst::flushKey();
}
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
