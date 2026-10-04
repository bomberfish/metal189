// metal189: reference (vanilla OpenGL) test mode support.
//
// LWJGL activates its window and makes it key on creation. For test runs on a
// shared desktop those calls are swizzled so the window opens behind other
// windows and the app never takes focus.

#import "m189.h"
#import <objc/runtime.h>

namespace m189 {

static void swizzle(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

#if TARGET_OS_IPHONE
void refModeInstall() {}   // no other windows to stay behind
#else
void refModeInstall() {
    dispatch_block_t install = ^{
        swizzle([NSApplication class], @selector(activateIgnoringOtherApps:),
                imp_implementationWithBlock(^(id self, BOOL flag) {}));
        swizzle([NSApplication class], @selector(activate), imp_implementationWithBlock(^(id self) {}));
        swizzle([NSWindow class], @selector(makeKeyAndOrderFront:),
                imp_implementationWithBlock(^(NSWindow* self, id sender) { [self orderBack:sender]; }));
        swizzle([NSWindow class], @selector(orderFrontRegardless),
                imp_implementationWithBlock(^(NSWindow* self) { [self orderBack:nil]; }));
        log("reference mode: window activation disabled");
    };
    if ([NSThread isMainThread]) install();
    else dispatch_async(dispatch_get_main_queue(), install);
}

#endif

} // namespace m189
