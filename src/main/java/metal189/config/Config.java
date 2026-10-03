package metal189.config;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Properties;
import metal189.engine.Native;
import net.minecraft.client.Minecraft;

/** User settings, persisted to config/metal189.properties. */
public final class Config {
    private Config() {}

    public static boolean shaders = false;
    public static boolean shadows = true;
    public static int shadowResolution = 4096;
    public static int shadowDistance = 112;
    public static boolean bloom = true;
    public static int bloomStrength = 100;   // percent of the default
    public static boolean sky = true;
    public static boolean water = true;
    public static boolean waving = true;
    public static boolean taa = true;
    public static boolean clouds = true;
    public static boolean volumetrics = true;
    public static boolean autoExposure = true;
    public static int exposure = 100;        // percent
    public static boolean rtShadows = false;
    public static boolean rtReflections = false;
    public static boolean rtAmbientOcclusion = false;

    public static final int[] SHADOW_RESOLUTIONS = {2048, 4096, 8192};
    public static final int[] SHADOW_DISTANCES = {64, 96, 112, 128, 160, 192};

    private static File file;

    public static File file() {
        if (file == null) file = new File(new File(Minecraft.getMinecraft().mcDataDir, "config"), "metal189.properties");
        return file;
    }

    public static void load() {
        Properties p = new Properties();
        File f = file();
        if (f.isFile()) {
            InputStream in = null;
            try {
                in = new FileInputStream(f);
                p.load(in);
            } catch (IOException e) {
                Native.LOG.warn("metal189: cannot read {}: {}", f, e.toString());
            } finally {
                if (in != null) try { in.close(); } catch (IOException ignored) {}
            }
        }
        shaders = bool(p, "shaders", shaders);
        shadows = bool(p, "shadows", shadows);
        shadowResolution = pick(integer(p, "shadowResolution", shadowResolution), SHADOW_RESOLUTIONS);
        shadowDistance = pick(integer(p, "shadowDistance", shadowDistance), SHADOW_DISTANCES);
        bloom = bool(p, "bloom", bloom);
        bloomStrength = clamp(integer(p, "bloomStrength", bloomStrength), 0, 300);
        sky = bool(p, "sky", sky);
        water = bool(p, "water", water);
        waving = bool(p, "waving", waving);
        taa = bool(p, "taa", taa);
        clouds = bool(p, "clouds", clouds);
        volumetrics = bool(p, "volumetrics", volumetrics);
        autoExposure = bool(p, "autoExposure", autoExposure);
        exposure = clamp(integer(p, "exposure", exposure), 25, 400);
        rtShadows = bool(p, "rtShadows", rtShadows);
        rtReflections = bool(p, "rtReflections", rtReflections);
        rtAmbientOcclusion = bool(p, "rtAmbientOcclusion", rtAmbientOcclusion);
    }

    public static void save() {
        Properties p = new Properties();
        p.setProperty("shaders", Boolean.toString(shaders));
        p.setProperty("shadows", Boolean.toString(shadows));
        p.setProperty("shadowResolution", Integer.toString(shadowResolution));
        p.setProperty("shadowDistance", Integer.toString(shadowDistance));
        p.setProperty("bloom", Boolean.toString(bloom));
        p.setProperty("bloomStrength", Integer.toString(bloomStrength));
        p.setProperty("sky", Boolean.toString(sky));
        p.setProperty("water", Boolean.toString(water));
        p.setProperty("waving", Boolean.toString(waving));
        p.setProperty("taa", Boolean.toString(taa));
        p.setProperty("clouds", Boolean.toString(clouds));
        p.setProperty("volumetrics", Boolean.toString(volumetrics));
        p.setProperty("autoExposure", Boolean.toString(autoExposure));
        p.setProperty("exposure", Integer.toString(exposure));
        p.setProperty("rtShadows", Boolean.toString(rtShadows));
        p.setProperty("rtReflections", Boolean.toString(rtReflections));
        p.setProperty("rtAmbientOcclusion", Boolean.toString(rtAmbientOcclusion));
        File f = file();
        f.getParentFile().mkdirs();
        OutputStream out = null;
        try {
            out = new FileOutputStream(f);
            p.store(out, "metal189 rendering settings");
        } catch (IOException e) {
            Native.LOG.warn("metal189: cannot write {}: {}", f, e.toString());
        } finally {
            if (out != null) try { out.close(); } catch (IOException ignored) {}
        }
    }

    private static boolean bool(Properties p, String k, boolean def) {
        String v = p.getProperty(k);
        return v == null ? def : Boolean.parseBoolean(v.trim());
    }

    private static int integer(Properties p, String k, int def) {
        String v = p.getProperty(k);
        if (v == null) return def;
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    private static int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }

    /** The allowed value closest to v. */
    public static int pick(int v, int[] allowed) {
        int best = allowed[0];
        for (int a : allowed) if (Math.abs(a - v) < Math.abs(best - v)) best = a;
        return best;
    }

    /** The allowed value after v (wrapping). */
    public static int next(int v, int[] allowed) {
        for (int i = 0; i < allowed.length; i++) if (allowed[i] == v) return allowed[(i + 1) % allowed.length];
        return allowed[0];
    }
}
