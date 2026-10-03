package metal189.world;

import metal189.engine.Native;

/** User-facing switch between the vanilla-exact renderer and the advanced pipeline. */
public final class Pipeline {
    private Pipeline() {}

    public static final int SHADOWS = 1, BLOOM = 2, SKY = 4, WATER = 8, SSAO = 16, PCSS = 32, RT_SHADOWS = 64, RT_REFLECTIONS = 128;

    private static boolean advanced = Boolean.getBoolean("metal189.shaders");
    private static int features = Integer.getInteger("metal189.shaderFeatures", SHADOWS | BLOOM | SKY | WATER);
    private static boolean applied;

    public static boolean advanced() { return advanced; }

    public static void setAdvanced(boolean on) {
        advanced = on;
        apply();
    }

    public static void toggle() { setAdvanced(!advanced); }

    /** Called when a world starts rendering (block registry and textures are ready). */
    public static void apply() {
        if (advanced) Materials.upload();
        Native.advSetFeatures(features);
        Native.advSetEnabled(advanced);
        applied = true;
    }

    public static void ensureApplied() { if (!applied) apply(); }
}
