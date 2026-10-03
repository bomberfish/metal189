package metal189.config;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Every user setting: its menu page, kind and range. Values live in the {@link Config}
 * static fields of the same name (booleans or ints); this table drives loading, saving,
 * validation and the settings screens. Names and tooltips come from the language file
 * ({@code metal189.opt.<key>} and {@code metal189.opt.<key>.desc}).
 */
public final class Options {
    private Options() {}

    public enum Kind { TOGGLE, SLIDER, CHOICE }

    /** Enabled only with shaders on / with hardware ray tracing. */
    public static final int NEEDS_SHADERS = 1, NEEDS_RT = 2;

    /** Settings pages after the main page, in menu order. */
    public static final String[] PAGES = {"lighting", "materials", "water", "sky", "post", "rt"};

    public static final class Opt {
        public final String key, page;
        public final Kind kind;
        public final int min, max, step;   // SLIDER
        public final int[] choices;        // CHOICE: allowed values
        public final boolean named;        // CHOICE: values have names (metal189.opt.<key>.<value>)
        public final String unit;          // shown after numeric values
        public final int needs;
        public final int def;
        private final Field field;

        Opt(String key, String page, Kind kind, int min, int max, int step, int[] choices, boolean named, String unit, int needs) {
            this.key = key;
            this.page = page;
            this.kind = kind;
            this.min = min;
            this.max = max;
            this.step = step;
            this.choices = choices;
            this.named = named;
            this.unit = unit;
            this.needs = needs;
            try {
                field = Config.class.getField(key);
            } catch (NoSuchFieldException e) {
                throw new IllegalStateException("metal189: no Config." + key, e);
            }
            def = get();
        }

        public int get() {
            try {
                return field.getType() == boolean.class ? (field.getBoolean(null) ? 1 : 0) : field.getInt(null);
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            }
        }

        public void set(int v) {
            v = sanitize(v);
            try {
                if (field.getType() == boolean.class) field.setBoolean(null, v != 0);
                else field.setInt(null, v);
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            }
        }

        public int sanitize(int v) {
            switch (kind) {
                case TOGGLE: return v != 0 ? 1 : 0;
                case SLIDER:
                    v = Math.max(min, Math.min(max, v));
                    return step > 1 ? Math.min(max, min + Math.round((v - min) / (float) step) * step) : v;
                default: return Config.pick(v, choices);
            }
        }

        /** Next value for a button press (toggles flip, choices advance and wrap). */
        public void cycle(boolean backwards) {
            if (kind == Kind.TOGGLE) {
                set(get() ^ 1);
                return;
            }
            if (kind != Kind.CHOICE) return;
            int v = get(), n = choices.length;
            for (int i = 0; i < n; i++)
                if (choices[i] == v) {
                    set(choices[(i + (backwards ? n - 1 : 1)) % n]);
                    return;
                }
            set(choices[0]);
        }

        public boolean isBoolean() { return field.getType() == boolean.class; }

        /** Value from a properties file (booleans as true/false, numbers as integers). */
        public void parse(String s) {
            s = s.trim();
            if (isBoolean()) set(Boolean.parseBoolean(s) ? 1 : 0);
            else {
                try {
                    set(Integer.parseInt(s));
                } catch (NumberFormatException ignored) {
                }
            }
        }

        public String format() { return isBoolean() ? Boolean.toString(get() != 0) : Integer.toString(get()); }
    }

    private static final List<Opt> ALL = new ArrayList<Opt>();

    /** Quality profiles: values for the performance-relevant options (others are left alone). */
    public static final String[] PROFILES = {"low", "medium", "high", "ultra"};
    private static final String[] PROFILE_KEYS = {"shadows", "shadowResolution", "shadowDistance", "ssao", "volumetrics",
            "clouds", "taa", "pom", "pomQuality", "rtShadows", "rtReflections", "rtAmbientOcclusion", "rtGlobalIllumination"};
    private static final int[][] PROFILE_VALUES = {
        {1, 2048, 64, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0},
        {1, 2048, 96, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0},
        {1, 4096, 112, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0},
        {1, 8192, 160, 1, 1, 1, 1, 1, 2, 1, 1, 1, 0},
    };

    public static void applyProfile(int p, boolean rt) {
        for (int i = 0; i < PROFILE_KEYS.length; i++) {
            Opt o = get(PROFILE_KEYS[i]);
            int v = PROFILE_VALUES[p][i];
            if ((o.needs & NEEDS_RT) != 0 && !rt) v = 0;
            o.set(v);
        }
    }

    /** The profile the current settings match, or -1 (custom). */
    public static int currentProfile(boolean rt) {
        for (int p = 0; p < PROFILES.length; p++) {
            boolean match = true;
            for (int i = 0; i < PROFILE_KEYS.length && match; i++) {
                Opt o = get(PROFILE_KEYS[i]);
                int v = PROFILE_VALUES[p][i];
                if ((o.needs & NEEDS_RT) != 0 && !rt) v = 0;
                match = o.get() == v;
            }
            if (match) return p;
        }
        return -1;
    }

    public static List<Opt> all() { return Collections.unmodifiableList(ALL); }

    public static List<Opt> page(String page) {
        List<Opt> r = new ArrayList<Opt>();
        for (Opt o : ALL) if (o.page.equals(page)) r.add(o);
        return r;
    }

    public static Opt get(String key) {
        for (Opt o : ALL) if (o.key.equals(key)) return o;
        return null;
    }

    private static void toggle(String page, String key, int needs) {
        ALL.add(new Opt(key, page, Kind.TOGGLE, 0, 1, 1, null, false, "", needs));
    }

    private static void slider(String page, String key, int needs, int min, int max, int step, String unit) {
        ALL.add(new Opt(key, page, Kind.SLIDER, min, max, step, null, false, unit, needs));
    }

    private static void numbers(String page, String key, int needs, String unit, int... values) {
        ALL.add(new Opt(key, page, Kind.CHOICE, 0, 0, 1, values, false, unit, needs));
    }

    private static void named(String page, String key, int needs, int count) {
        int[] v = new int[count];
        for (int i = 0; i < count; i++) v[i] = i;
        ALL.add(new Opt(key, page, Kind.CHOICE, 0, count - 1, 1, v, true, "", needs));
    }

    static {
        final int S = NEEDS_SHADERS, RT = NEEDS_SHADERS | NEEDS_RT;
        toggle("main", "shaders", 0);
        toggle("main", "ctrlClickRightClick", 0);

        toggle("lighting", "shadows", S);
        numbers("lighting", "shadowResolution", S, "", Config.SHADOW_RESOLUTIONS);
        numbers("lighting", "shadowDistance", S, " blocks", Config.SHADOW_DISTANCES);
        toggle("lighting", "playerShadow", S);
        toggle("lighting", "plantShadows", S);
        slider("lighting", "foliageTranslucency", S, 0, 200, 5, "%");
        toggle("lighting", "ssao", S);
        toggle("lighting", "waving", S);
        toggle("lighting", "autoExposure", S);
        slider("lighting", "exposure", S, 25, 400, 5, "%");
        slider("lighting", "sunBrightness", S, 25, 300, 5, "%");
        slider("lighting", "skyLightBrightness", S, 25, 300, 5, "%");
        slider("lighting", "blockLightBrightness", S, 25, 300, 5, "%");
        slider("lighting", "blockLightWarmth", S, 0, 200, 5, "%");
        slider("lighting", "minimumLight", S, 0, 400, 10, "%");
        toggle("lighting", "heldLight", S);

        toggle("materials", "pbr", S);
        named("materials", "pbrFormat", S, 2);
        slider("materials", "pbrNormalStrength", S, 0, 200, 5, "%");
        slider("materials", "pbrSpecularStrength", S, 0, 200, 5, "%");
        slider("materials", "pbrEmissionStrength", S, 0, 300, 5, "%");
        toggle("materials", "pom", S);
        slider("materials", "pomDepth", S, 5, 50, 1, "%");
        named("materials", "pomQuality", S, 4);
        slider("materials", "pomDistance", S, 8, 64, 4, " blocks");

        toggle("water", "water", S);
        named("water", "waterStyle", S, 3);
        slider("water", "waterWaveStrength", S, 0, 250, 5, "%");
        slider("water", "waterWaveSize", S, 25, 300, 5, "%");
        slider("water", "waterWaveSpeed", S, 0, 300, 5, "%");
        toggle("water", "waterCalmIndoors", S);
        toggle("water", "waterRainRipples", S);
        named("water", "waterReflections", S, 2);
        slider("water", "waterReflectivity", S, 2, 25, 1, "%");
        slider("water", "waterSunReflection", S, 0, 300, 5, "%");
        slider("water", "waterRefraction", S, 0, 300, 5, "%");
        slider("water", "waterClarity", S, 2, 48, 1, " blocks");
        slider("water", "waterColorR", S, 25, 300, 5, "%");
        slider("water", "waterColorG", S, 25, 300, 5, "%");
        slider("water", "waterColorB", S, 25, 300, 5, "%");
        toggle("water", "waterBiomeTint", S);
        slider("water", "waterFoam", S, 0, 150, 5, "%");
        slider("water", "waterFoamWidth", S, 25, 300, 5, "%");
        slider("water", "underwaterVisibility", S, 8, 128, 4, " blocks");
        slider("water", "underwaterDistortion", S, 0, 200, 10, "%");
        toggle("water", "underwaterOverlay", 0);
        toggle("water", "hideUnderwaterParticles", S);

        toggle("sky", "sky", S);
        toggle("sky", "clouds", S);
        toggle("sky", "volumetrics", S);
        slider("sky", "cloudCoverage", S, 0, 200, 5, "%");
        slider("sky", "cloudSpeed", S, 0, 400, 10, "%");
        slider("sky", "hazeDensity", S, 0, 400, 10, "%");
        slider("sky", "starBrightness", S, 0, 300, 10, "%");

        toggle("post", "taa", S);
        toggle("post", "bloom", S);
        slider("post", "bloomStrength", S, 0, 300, 5, "%");
        slider("post", "vignette", S, 0, 300, 10, "%");
        slider("post", "sharpening", S, 0, 300, 10, "%");
        slider("post", "saturation", S, 0, 200, 5, "%");
        slider("post", "contrast", S, 50, 150, 5, "%");

        toggle("rt", "rtShadows", RT);
        toggle("rt", "rtReflections", RT);
        toggle("rt", "rtAmbientOcclusion", RT);
        toggle("rt", "rtGlobalIllumination", RT);
        toggle("rt", "rtEntities", RT);
    }
}
