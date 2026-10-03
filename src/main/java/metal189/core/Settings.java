package metal189.core;

/** Launch-time switches (system properties). */
public final class Settings {
    private Settings() {}

    /** Disable every patch and run vanilla OpenGL (used for reference captures). */
    public static final boolean DISABLED = Boolean.getBoolean("metal189.disable");
    /** Render at the screen's backing scale (Retina) instead of 1x like vanilla LWJGL. */
    public static final boolean RETINA = Boolean.getBoolean("metal189.retina");
    /** normal | background | offscreen. Tests use background/offscreen. */
    public static final String WINDOW_MODE = System.getProperty("metal189.window", "normal");
    /** Never grab, hide or warp the pointer (test runs on a shared desktop). */
    public static final boolean NO_GRAB = Boolean.getBoolean("metal189.noGrab");
    /** Verbose logging of unimplemented GL entry points. */
    public static final boolean DEBUG_GL = Boolean.getBoolean("metal189.debugGL");

    public static boolean background() {
        return "background".equals(WINDOW_MODE) || offscreen();
    }

    public static boolean offscreen() {
        return "offscreen".equals(WINDOW_MODE);
    }
}
