package metal189.shim;

import org.lwjgl.opengl.ContextCapabilities;

/**
 * org.lwjgl.opengl.GLContext stand-in. Field reads on ContextCapabilities are
 * rewritten by the transformer into {@link #cap(String)} calls.
 */
public final class GLContext {
    private GLContext() {}

    /** Whether vanilla should use NV radial fog distance (matches what Apple's GL reports). */
    public static boolean radialFog = Boolean.parseBoolean(System.getProperty("metal189.radialFog", "false"));

    public static ContextCapabilities getCapabilities() { return null; }
    public static void useContext(Object context) {}
    public static void useContext(Object context, boolean forwardCompatible) {}

    public static boolean cap(String name) {
        if (name.startsWith("OpenGL")) {
            try {
                return Integer.parseInt(name.substring(6)) <= 30;
            } catch (NumberFormatException e) {
                return false;
            }
        }
        if ("GL_NV_fog_distance".equals(name)) return radialFog;
        return false;
    }
}
