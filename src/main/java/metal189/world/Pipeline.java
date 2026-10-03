package metal189.world;

import metal189.config.Config;
import metal189.engine.Native;

/**
 * Switch between the vanilla-exact renderer and the advanced pipeline, and the
 * advanced pipeline's options. User settings come from {@link Config}; the
 * metal189.shaders / metal189.shaderFeatures system properties override them (tests).
 */
public final class Pipeline {
    private Pipeline() {}

    public static final int SHADOWS = 1, BLOOM = 2, SKY = 4, WATER = 8, SSAO = 16, PCSS = 32, RT_SHADOWS = 64, RT_REFLECTIONS = 128,
            TAA = 256, CLOUDS = 512;

    private static final String SHADERS_OVERRIDE = System.getProperty("metal189.shaders");
    private static final Integer FEATURES_OVERRIDE = Integer.getInteger("metal189.shaderFeatures");
    // native option keys (frame_exec.mm setOption)
    private static final int OPT_SHADOW_RES = 10, OPT_SHADOW_DIST = 11, OPT_EXPOSURE = 12, OPT_BLOOM = 13, OPT_RT_RELEASE = 14,
            OPT_WAVING = 15;

    private static boolean advanced;
    private static int features;
    private static boolean applied;
    private static boolean rtWasOn;

    public static boolean advanced() { return advanced; }

    public static boolean rtSupported() { return Native.rtSupported(); }

    public static void toggle() {
        Config.shaders = !advanced;
        Config.save();
        apply();
    }

    /** Called when a world starts rendering (block registry and textures are ready) and after settings change. */
    public static void apply() {
        advanced = SHADERS_OVERRIDE != null ? Boolean.parseBoolean(SHADERS_OVERRIDE) : Config.shaders;
        if (FEATURES_OVERRIDE != null) {
            features = FEATURES_OVERRIDE;
        } else {
            features = 0;
            if (Config.shadows) features |= SHADOWS;
            if (Config.bloom) features |= BLOOM;
            if (Config.sky) features |= SKY;
            if (Config.water) features |= WATER;
            if (Config.rtShadows) features |= RT_SHADOWS;
            if (Config.rtReflections) features |= RT_REFLECTIONS;
            if (Config.taa) features |= TAA;
            if (Config.clouds) features |= CLOUDS;
        }
        if (advanced) Materials.upload();
        Native.setOption(OPT_SHADOW_RES, Config.shadowResolution);
        Native.setOption(OPT_SHADOW_DIST, Config.shadowDistance);
        Native.setOption(OPT_EXPOSURE, Config.exposure);
        Native.setOption(OPT_BLOOM, Config.bloomStrength);
        Native.setOption(OPT_WAVING, Config.waving ? 1 : 0);
        boolean rtOn = advanced && (features & (RT_SHADOWS | RT_REFLECTIONS)) != 0;
        if (rtWasOn && !rtOn) Native.setOption(OPT_RT_RELEASE, 1); // free acceleration structures
        rtWasOn = rtOn;
        Native.advSetFeatures(features);
        Native.advSetEnabled(advanced);
        applied = true;
    }

    public static void ensureApplied() { if (!applied) apply(); }
}
