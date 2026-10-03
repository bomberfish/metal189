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
            TAA = 256, CLOUDS = 512, VOLUMETRICS = 1024, AUTO_EXPOSURE = 2048, RT_AO = 8192, RT_GI = 16384;

    private static final String SHADERS_OVERRIDE = System.getProperty("metal189.shaders");
    private static final Integer FEATURES_OVERRIDE = Integer.getInteger("metal189.shaderFeatures");
    // native option keys (frame_exec.mm setOption)
    private static final int OPT_SHADOW_RES = 10, OPT_SHADOW_DIST = 11, OPT_EXPOSURE = 12, OPT_BLOOM = 13, OPT_RT_RELEASE = 14,
            OPT_WAVING = 15, OPT_RT_ENTITIES = 16;

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
            if (Config.volumetrics) features |= VOLUMETRICS;
            if (Config.autoExposure) features |= AUTO_EXPOSURE;
            if (Config.ssao) features |= SSAO;
            if (Config.rtAmbientOcclusion) features |= RT_AO;
            if (Config.rtGlobalIllumination) features |= RT_GI;
        }
        if (advanced) Materials.upload();
        Native.setOption(OPT_SHADOW_RES, Config.shadowResolution);
        Native.setOption(OPT_SHADOW_DIST, Config.shadowDistance);
        Native.setOption(OPT_EXPOSURE, Config.exposure);
        Native.setOption(OPT_BLOOM, Config.bloomStrength);
        Native.setOption(OPT_WAVING, Config.waving ? 1 : 0);
        Native.setOption(OPT_RT_ENTITIES, Config.rtEntities ? 1 : 0);
        boolean rtOn = advanced && (features & (RT_SHADOWS | RT_REFLECTIONS | RT_AO | RT_GI)) != 0;
        if (rtWasOn && !rtOn) Native.setOption(OPT_RT_RELEASE, 1); // free acceleration structures
        rtWasOn = rtOn;
        pushTuning();
        Native.advSetFeatures(features);
        Native.advSetEnabled(advanced);
        applied = true;
    }

    // Continuous settings for the shaders (adv.metal WATER_* / fr.tune), 4 floats per group.
    private static final int TUNING = 64;
    private static final int WATER_FLAG_BIOME_TINT = 1, WATER_FLAG_CALM_INDOORS = 2;
    private static long tuning;

    private static void pushTuning() {
        if (tuning == 0) tuning = metal189.engine.Mem.malloc(TUNING * 4);
        float[] t = new float[TUNING];
        // waves: strength, size, speed, style
        t[0] = Config.waterWaveStrength / 100f;
        t[1] = Config.waterWaveSize / 100f;
        t[2] = Config.waterWaveSpeed / 100f;
        t[3] = Config.waterStyle;
        // surface: reflectance at normal incidence, sun reflection, refraction, foam
        t[4] = Config.waterReflectivity / 100f;
        t[5] = Config.waterSunReflection / 100f;
        t[6] = Config.waterRefraction / 100f;
        t[7] = Config.waterFoam / 100f;
        // water body: the deep-water colour, and absorption derived from it and the clarity.
        // The mean extinction halves the light over the clarity distance; channels the colour
        // keeps are absorbed less (a quarter of the extinction is scattering).
        float[] col = {0.020f * Config.waterColorR / 100f, 0.140f * Config.waterColorG / 100f, 0.220f * Config.waterColorB / 100f};
        float max = Math.max(col[0], Math.max(col[1], col[2]));
        float[] w = new float[3];
        float mean = 0;
        for (int i = 0; i < 3; i++) {
            w[i] = 0.25f - (float) Math.log(Math.max(col[i] / max, 1e-3f));
            mean += w[i] / 3;
        }
        float sigma = (float) Math.log(2) / Math.max(Config.waterClarity, 1);
        for (int i = 0; i < 3; i++) t[8 + i] = 0.75f * sigma * w[i] / mean;
        t[11] = 0.25f * sigma;
        System.arraycopy(col, 0, t, 12, 3);
        t[15] = 1f;   // caustics
        // underwater visibility, distortion, flags, foam band width (blocks)
        t[16] = Config.underwaterVisibility;
        t[17] = 1f;
        t[18] = (Config.waterBiomeTint ? WATER_FLAG_BIOME_TINT : 0) | (Config.waterCalmIndoors ? WATER_FLAG_CALM_INDOORS : 0);
        t[19] = 1.2f * Config.waterFoamWidth / 100f;
        for (int i = 0; i < TUNING; i++) metal189.engine.Mem.putFloat(tuning + i * 4L, t[i]);
        Native.advSetTuning(tuning, TUNING);
    }

    public static void ensureApplied() { if (!applied) apply(); }
}
