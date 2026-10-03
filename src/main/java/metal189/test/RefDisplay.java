package metal189.test;

/** Display.update wrapper for reference runs: test-driver step, then the real swap. */
public final class RefDisplay {
    private RefDisplay() {}

    private static boolean logged;

    public static void update() {
        if (!logged) {
            logged = true;
            metal189.engine.Native.LOG.info("metal189-ref GL_RENDERER={} GL_VERSION={}", org.lwjgl.opengl.GL11.glGetString(0x1F01), org.lwjgl.opengl.GL11.glGetString(0x1F02));
            metal189.engine.Native.LOG.info("metal189-ref GL_EXTENSIONS={}", org.lwjgl.opengl.GL11.glGetString(0x1F03));
        }
        TestDriver.beforeSwap();
        org.lwjgl.opengl.Display.update();
        TestDriver.onFrame();
    }
}
