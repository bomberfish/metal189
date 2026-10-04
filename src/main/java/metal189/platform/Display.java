package metal189.platform;

import java.lang.reflect.Constructor;
import java.nio.ByteBuffer;
import metal189.core.Settings;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.engine.Native;
import org.lwjgl.LWJGLException;
import org.lwjgl.opengl.Drawable;
import org.lwjgl.opengl.DisplayMode;
import org.lwjgl.opengl.PixelFormat;

/**
 * Drop-in replacement for org.lwjgl.opengl.Display backed by a native Cocoa
 * window with a CAMetalLayer. Calls in Minecraft/Forge are redirected here.
 */
public final class Display {
    private Display() {}

    static final int WF_RESIZABLE = 1, WF_RETINA = 2, WF_BACKGROUND = 4, WF_OFFSCREEN = 8;

    private static boolean created;
    private static String title = "Game";
    private static boolean resizable;
    private static boolean fullscreen;
    private static boolean vsync;
    private static DisplayMode mode = new DisplayMode(640, 480);
    private static int width = 640, height = 480;
    private static boolean resizedSinceUpdate;
    private static final long info = Mem.malloc(64);

    // ---- creation ----
    public static void create() throws LWJGLException { create(new PixelFormat()); }

    public static void create(PixelFormat pf) throws LWJGLException {
        if (created) throw new IllegalStateException("Only one LWJGL context may be instantiated at any one time.");
        // AppKit needs AWT's NSApplication running on the main thread.
        if (!java.awt.GraphicsEnvironment.isHeadless()) java.awt.Toolkit.getDefaultToolkit();
        Engine.initialize();
        int flags = 0;
        if (resizable) flags |= WF_RESIZABLE;
        if (Settings.RETINA) flags |= WF_RETINA;
        if (Settings.background()) flags |= WF_BACKGROUND;
        if (Settings.offscreen()) flags |= WF_OFFSCREEN;
        if (!Native.windowCreate(mode.getWidth(), mode.getHeight(), title, flags))
            throw new LWJGLException("Could not create Metal window");
        created = true;
        refreshInfo();
        resizedSinceUpdate = false;
        // the window may not be the size asked for (the screen clamps it; retina counts pixels):
        // the first update reports the real size as a resize, so the game renders at it
        if (!fullscreen) {
            width = mode.getWidth();
            height = mode.getHeight();
        }
        Native.windowSetVSync(vsync);
        if (fullscreen) Native.windowSetFullscreen(true);
        Mouse.created = true;
        Keyboard.created = true;
        Engine.beginFrame();
    }

    public static void create(PixelFormat pf, Drawable shared) throws LWJGLException { create(pf); }

    public static void destroy() {
        if (!created) return;
        Engine.shutdown();
        Native.windowDestroy();
        created = false;
        Mouse.created = false;
        Keyboard.created = false;
    }

    public static boolean isCreated() { return created; }

    // ---- frame ----
    public static void update() { update(true); }

    public static void update(boolean processMessages) {
        if (!created) throw new IllegalStateException("Display not created");
        Engine.endFrame();
        int ow = width, oh = height;
        refreshInfo();
        resizedSinceUpdate = !fullscreen && (ow != width || oh != height);
        if (processMessages) processMessages();
        Engine.beginFrame();
        metal189.test.TestDriver.onFrame();
    }

    public static void processMessages() {
        if (!created) throw new IllegalStateException("Display not created");
        Input.poll();
    }

    public static void sync(int fps) { Sync.sync(fps); }

    public static void swapBuffers() throws LWJGLException { update(false); }

    // ---- state ----
    static void refreshInfo() {
        if (!created) return;
        Native.windowInfo(info);
        width = Math.max(1, Mem.getInt(info));
        height = Math.max(1, Mem.getInt(info + 4));
    }

    static float backingScale() { return Mem.getInt(info + 28) / 1000.0f; }

    public static boolean isCloseRequested() { return created && Mem.getInt(info + 20) != 0; }
    public static boolean isActive() { return created && (Mem.getInt(info + 8) != 0 || Settings.background()); }
    public static boolean isVisible() { return created && (Mem.getInt(info + 12) != 0 || Settings.background()); }
    public static boolean isDirty() { return false; }
    public static boolean wasResized() { return resizedSinceUpdate; }
    public static int getWidth() { return fullscreen ? mode.getWidth() : created ? width : mode.getWidth(); }
    public static int getHeight() { return fullscreen ? mode.getHeight() : created ? height : mode.getHeight(); }
    public static int getX() { return 0; }
    public static int getY() { return 0; }
    public static float getPixelScaleFactor() { return 1.0f; }

    public static void setTitle(String t) {
        title = t == null ? "" : t;
        if (created) Native.windowSetTitle(title);
    }

    public static String getTitle() { return title; }

    public static void setResizable(boolean r) {
        resizable = r;
        if (created) Native.windowSetResizable(r);
    }

    public static boolean isResizable() { return resizable; }

    public static void setDisplayMode(DisplayMode m) throws LWJGLException {
        if (m == null) throw new NullPointerException("mode must be non-null");
        mode = m;
        if (created && !fullscreen) Native.windowSetSize(m.getWidth(), m.getHeight());
    }

    public static DisplayMode getDisplayMode() { return mode; }

    public static DisplayMode getDesktopDisplayMode() {
        long m = Mem.malloc(16);
        try {
            Native.desktopMode(m);
            return newMode(Mem.getInt(m), Mem.getInt(m + 4), Mem.getInt(m + 12), Mem.getInt(m + 8));
        } finally {
            Mem.free(m);
        }
    }

    public static DisplayMode[] getAvailableDisplayModes() throws LWJGLException {
        return new DisplayMode[] {getDesktopDisplayMode()};
    }

    public static void setFullscreen(boolean fs) throws LWJGLException {
        fullscreen = fs;
        if (created) Native.windowSetFullscreen(fs);
    }

    public static void setDisplayModeAndFullscreen(DisplayMode m) throws LWJGLException {
        mode = m;
        setFullscreen(m.isFullscreenCapable());
    }

    public static boolean isFullscreen() { return fullscreen; }

    public static void setVSyncEnabled(boolean v) {
        vsync = v;
        if (created) Native.windowSetVSync(v);
    }

    public static void setSwapInterval(int i) { setVSyncEnabled(i > 0); }

    public static int setIcon(ByteBuffer[] icons) { return 0; }
    public static void setLocation(int x, int y) {}
    public static void setInitialBackground(float r, float g, float b) {}
    public static void setParent(java.awt.Canvas parent) {}
    public static java.awt.Canvas getParent() { return null; }
    public static Drawable getDrawable() { return null; }
    public static void makeCurrent() {}
    public static void releaseContext() {}
    public static boolean isCurrent() { return true; }
    public static String getAdapter() { return "Metal"; }
    public static String getVersion() { return Native.deviceName(); }
    public static void setDisplayConfiguration(float gamma, float brightness, float contrast) {}

    private static DisplayMode newMode(int w, int h, int bpp, int freq) {
        try {
            Constructor<DisplayMode> c = DisplayMode.class.getDeclaredConstructor(int.class, int.class, int.class, int.class);
            c.setAccessible(true);
            return c.newInstance(w, h, bpp, freq);
        } catch (Exception e) {
            return new DisplayMode(w, h);
        }
    }
}
