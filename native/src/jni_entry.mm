// metal189: JNI registration for metal189.engine.Native.

#import "engine.h"
#import "resources.h"
#import "advanced.h"
#import "raytrace.h"

namespace m189 {
void texGetImage(int id, int level, int format, int type, void* dst, size_t size);
void readPixels(int fbo, int x, int y, int w, int h, int format, int type, void* dst, size_t size);
bool captureToPng(int which, const char* path);
void refModeInstall();
void setOption(int key, int value);
}

using namespace m189;

static inline void* ptr(jlong a) { return (void*)(intptr_t)a; }

static NSString* jstr(JNIEnv* env, jstring s) {
    if (!s) return nil;
    const jchar* c = env->GetStringChars(s, nullptr);
    NSString* r = [NSString stringWithCharacters:(const unichar*)c length:(NSUInteger)env->GetStringLength(s)];
    env->ReleaseStringChars(s, c);
    return r;
}

static jint JNICALL n_init(JNIEnv*, jclass, jlong lib, jlong libSize, jint flags) {
    @autoreleasepool { return engineInit(ptr(lib), (size_t)libSize, flags) ? 0 : 1; }
}

static jstring JNICALL n_deviceName(JNIEnv* env, jclass) {
    @autoreleasepool {
        NSString* n = device() ? device().name : @"none";
        return env->NewStringUTF(n.UTF8String);
    }
}

static jboolean JNICALL n_windowCreate(JNIEnv* env, jclass, jint w, jint h, jstring title, jint flags) {
    @autoreleasepool { return windowCreate(w, h, jstr(env, title), flags) ? JNI_TRUE : JNI_FALSE; }
}
static void JNICALL n_windowDestroy(JNIEnv*, jclass) { @autoreleasepool { windowDestroy(); } }
static void JNICALL n_windowSetTitle(JNIEnv* env, jclass, jstring t) { @autoreleasepool { windowSetTitle(jstr(env, t)); } }
static void JNICALL n_windowSetResizable(JNIEnv*, jclass, jboolean r) { @autoreleasepool { windowSetResizable(r); } }
static void JNICALL n_windowSetSize(JNIEnv*, jclass, jint w, jint h) { @autoreleasepool { windowSetSize(w, h); } }
static void JNICALL n_windowSetFullscreen(JNIEnv*, jclass, jboolean f) { @autoreleasepool { windowSetFullscreen(f); } }
static void JNICALL n_windowSetVSync(JNIEnv*, jclass, jboolean v) { @autoreleasepool { windowSetVSync(v); } }

static jint JNICALL n_pollEvents(JNIEnv*, jclass, jlong addr, jint max) {
    platformPumpEvents();
    return popEvents((Event*)ptr(addr), max);
}

static void JNICALL n_windowInfo(JNIEnv*, jclass, jlong addr) {
    WindowInfo& wi = windowInfo();
    int32_t* o = (int32_t*)ptr(addr);
    o[0] = wi.pixelWidth;
    o[1] = wi.pixelHeight;
    o[2] = wi.focused;
    o[3] = wi.visible;
    o[4] = wi.mouseInside;
    o[5] = wi.closeRequested;
    o[6] = wi.fullscreen;
    o[7] = (int32_t)lroundf(wi.backingScale * 1000.0f);
    o[8] = (int32_t)lroundf(wi.screenScale * 1000.0f);
}

static void JNICALL n_cursorGrab(JNIEnv*, jclass, jboolean g) { @autoreleasepool { cursorSetGrabbed(g); } }
static void JNICALL n_cursorSetPos(JNIEnv*, jclass, jint x, jint y) { @autoreleasepool { cursorSetPosition(x, y); } }
static void JNICALL n_desktopMode(JNIEnv*, jclass, jlong addr) { @autoreleasepool { desktopMode((int*)ptr(addr)); } }

static void JNICALL n_beginFrame(JNIEnv*, jclass, jlong info) {
    @autoreleasepool {
        beginFrame();
        int64_t* o = (int64_t*)ptr(info);
        Engine& e = engine();
        o[0] = (int64_t)(intptr_t)e.cur->arenas[0].contents;
        o[1] = (int64_t)e.cur->arenas[0].length;
        o[2] = (int64_t)e.frameIndex;
        o[3] = 0;
    }
}

static void JNICALL n_endFrame(JNIEnv*, jclass, jlong cmds, jint len) {
    @autoreleasepool { endFrame((const uint8_t*)ptr(cmds), (size_t)len); }
}

static void JNICALL n_waitIdle(JNIEnv*, jclass) { @autoreleasepool { waitIdle(); } }
static void JNICALL n_submitPartial(JNIEnv*, jclass, jlong cmds, jint len) { @autoreleasepool { submitPartial((const uint8_t*)ptr(cmds), (size_t)len); } }
static void JNICALL n_arenaGrow(JNIEnv*, jclass, jlong info, jint minBytes) { @autoreleasepool { arenaGrow((size_t)minBytes, (int64_t*)ptr(info)); } }
static void JNICALL n_formatRegister(JNIEnv*, jclass, jint id, jint stride, jlong attrs, jint count) { formatRegister(id, stride, (const int32_t*)ptr(attrs), count); }
static void JNICALL n_texImage(JNIEnv*, jclass, jint id, jint level, jint ifmt, jint w, jint h, jint fmt, jint type, jlong data, jint rowLength) {
    @autoreleasepool { texImage(id, level, ifmt, w, h, fmt, type, ptr(data), rowLength); }
}
static void JNICALL n_texSubImage(JNIEnv*, jclass, jint id, jint level, jint x, jint y, jint w, jint h, jint fmt, jint type, jlong data, jint rowLength) {
    @autoreleasepool { texSubImage(id, level, x, y, w, h, fmt, type, ptr(data), rowLength); }
}
static void JNICALL n_texParams(JNIEnv*, jclass, jint id, jint minF, jint magF, jint ws, jint wt, jint maxLevel, jfloat minLod, jfloat maxLod, jfloat aniso) {
    texParams(id, minF, magF, ws, wt, maxLevel, minLod, maxLod, aniso);
}
static void JNICALL n_texDelete(JNIEnv*, jclass, jint id) { texDelete(id); }
static void JNICALL n_texGetImage(JNIEnv*, jclass, jint id, jint level, jint fmt, jint type, jlong dst, jint size) {
    @autoreleasepool { texGetImage(id, level, fmt, type, ptr(dst), (size_t)size); }
}
static void JNICALL n_readPixels(JNIEnv*, jclass, jint fbo, jint x, jint y, jint w, jint h, jint fmt, jint type, jlong dst, jint size) {
    @autoreleasepool { readPixels(fbo, x, y, w, h, fmt, type, ptr(dst), (size_t)size); }
}
static jint JNICALL n_meshCreate(JNIEnv*, jclass, jlong data, jint size) { @autoreleasepool { return meshCreate(ptr(data), (size_t)size); } }
static void JNICALL n_meshDelete(JNIEnv*, jclass, jint id) { meshDelete(id); }
static jboolean JNICALL n_capture(JNIEnv* env, jclass, jint which, jstring path) {
    @autoreleasepool {
        const char* p = env->GetStringUTFChars(path, nullptr);
        bool ok = captureToPng(which, p);
        env->ReleaseStringUTFChars(path, p);
        return ok;
    }
}
static void JNICALL n_refModeInstall(JNIEnv*, jclass) { refModeInstall(); }
static void JNICALL n_setOption(JNIEnv*, jclass, jint k, jint v) { setOption(k, v); }
static void JNICALL n_sectionUpload(JNIEnv*, jclass, jint id, jint layer, jlong data, jint bytes, jint count, jint x, jint y, jint z) {
    @autoreleasepool { sectionUpload(id, layer, ptr(data), (size_t)bytes, (uint32_t)count, x, y, z); }
}
static void JNICALL n_sectionDelete(JNIEnv*, jclass, jint id) { sectionDelete(id); }
static void JNICALL n_sectionSolid(JNIEnv*, jclass, jint id, jlong bits, jboolean emits, jboolean tinted) {
    sectionSolid(id, (const uint32_t*)ptr(bits), emits, tinted);
}
static void JNICALL n_advSetEnabled(JNIEnv*, jclass, jboolean on) { advancedSetEnabled(on); }
static void JNICALL n_advSetFeatures(JNIEnv*, jclass, jint f) { advancedSetFeatures((uint32_t)f); }
static void JNICALL n_advSetTables(JNIEnv*, jclass, jlong mat, jlong emi, jlong col) {
    @autoreleasepool { advancedSetTables((const uint8_t*)ptr(mat), (const uint8_t*)ptr(emi), (const uint8_t*)ptr(col)); }
}
static jboolean JNICALL n_rtSupported(JNIEnv*, jclass) { return rtAvailable(); }
static jboolean JNICALL n_rtAccelerated(JNIEnv*, jclass) { return engine().rtAccelerated; }
static void JNICALL n_advSetPbr(JNIEnv*, jclass, jint n, jint s) { advancedSetPbr(n, s); }
static void JNICALL n_advSetTuning(JNIEnv*, jclass, jlong v, jint n) { advancedSetTuning((const float*)(intptr_t)v, n); }
static void JNICALL n_renderbufferStorage(JNIEnv*, jclass, jint id, jint fmt, jint w, jint h) { @autoreleasepool { renderbufferStorage(id, fmt, w, h); } }

static JNINativeMethod kMethods[] = {
    {(char*)"init", (char*)"(JJI)I", (void*)n_init},
    {(char*)"deviceName", (char*)"()Ljava/lang/String;", (void*)n_deviceName},
    {(char*)"windowCreate", (char*)"(IILjava/lang/String;I)Z", (void*)n_windowCreate},
    {(char*)"windowDestroy", (char*)"()V", (void*)n_windowDestroy},
    {(char*)"windowSetTitle", (char*)"(Ljava/lang/String;)V", (void*)n_windowSetTitle},
    {(char*)"windowSetResizable", (char*)"(Z)V", (void*)n_windowSetResizable},
    {(char*)"windowSetSize", (char*)"(II)V", (void*)n_windowSetSize},
    {(char*)"windowSetFullscreen", (char*)"(Z)V", (void*)n_windowSetFullscreen},
    {(char*)"windowSetVSync", (char*)"(Z)V", (void*)n_windowSetVSync},
    {(char*)"pollEvents", (char*)"(JI)I", (void*)n_pollEvents},
    {(char*)"windowInfo", (char*)"(J)V", (void*)n_windowInfo},
    {(char*)"cursorGrab", (char*)"(Z)V", (void*)n_cursorGrab},
    {(char*)"cursorSetPos", (char*)"(II)V", (void*)n_cursorSetPos},
    {(char*)"desktopMode", (char*)"(J)V", (void*)n_desktopMode},
    {(char*)"beginFrame", (char*)"(J)V", (void*)n_beginFrame},
    {(char*)"endFrame", (char*)"(JI)V", (void*)n_endFrame},
    {(char*)"waitIdle", (char*)"()V", (void*)n_waitIdle},
    {(char*)"submitPartial", (char*)"(JI)V", (void*)n_submitPartial},
    {(char*)"arenaGrow", (char*)"(JI)V", (void*)n_arenaGrow},
    {(char*)"formatRegister", (char*)"(IIJI)V", (void*)n_formatRegister},
    {(char*)"texImage", (char*)"(IIIIIIIJI)V", (void*)n_texImage},
    {(char*)"texSubImage", (char*)"(IIIIIIIIJI)V", (void*)n_texSubImage},
    {(char*)"texParams", (char*)"(IIIIIIFFF)V", (void*)n_texParams},
    {(char*)"texDelete", (char*)"(I)V", (void*)n_texDelete},
    {(char*)"texGetImage", (char*)"(IIIIJI)V", (void*)n_texGetImage},
    {(char*)"readPixels", (char*)"(IIIIIIIJI)V", (void*)n_readPixels},
    {(char*)"meshCreate", (char*)"(JI)I", (void*)n_meshCreate},
    {(char*)"meshDelete", (char*)"(I)V", (void*)n_meshDelete},
    {(char*)"renderbufferStorage", (char*)"(IIII)V", (void*)n_renderbufferStorage},
    {(char*)"capture", (char*)"(ILjava/lang/String;)Z", (void*)n_capture},
    {(char*)"refModeInstall", (char*)"()V", (void*)n_refModeInstall},
    {(char*)"setOption", (char*)"(II)V", (void*)n_setOption},
    {(char*)"sectionUpload", (char*)"(IIJIIIII)V", (void*)n_sectionUpload},
    {(char*)"sectionDelete", (char*)"(I)V", (void*)n_sectionDelete},
    {(char*)"sectionSolid", (char*)"(IJZZ)V", (void*)n_sectionSolid},
    {(char*)"advSetEnabled", (char*)"(Z)V", (void*)n_advSetEnabled},
    {(char*)"advSetFeatures", (char*)"(I)V", (void*)n_advSetFeatures},
    {(char*)"advSetTables", (char*)"(JJJ)V", (void*)n_advSetTables},
    {(char*)"rtSupported", (char*)"()Z", (void*)n_rtSupported},
    {(char*)"rtAccelerated", (char*)"()Z", (void*)n_rtAccelerated},
    {(char*)"advSetPbr", (char*)"(II)V", (void*)n_advSetPbr},
    {(char*)"advSetTuning", (char*)"(JI)V", (void*)n_advSetTuning},
};

// The Java side calls System.load on this library and then Native.register(),
// which binds against whichever class loader loaded metal189.engine.Native.
extern "C" JNIEXPORT void JNICALL Java_metal189_engine_Native_register(JNIEnv* env, jclass cls) {
    if (env->RegisterNatives(cls, kMethods, sizeof(kMethods) / sizeof(kMethods[0])) != 0) {
        log("RegisterNatives failed");
    }
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM*, void*) { return JNI_VERSION_1_8; }
