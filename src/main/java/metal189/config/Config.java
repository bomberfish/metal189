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
    public static boolean ssao = true;
    /** LWJGL's macOS Ctrl+left click = right click; off by default when mcmouser (which removes it) is installed. */
    public static boolean ctrlClickRightClick = !metal189.core.Compat.mcmouserInstalled();
    public static int exposure = 100;        // percent
    public static boolean rtShadows = false;
    public static boolean rtReflections = false;
    public static boolean rtAmbientOcclusion = false;
    public static boolean rtGlobalIllumination = false;
    /** Entities (and the first-person player) in ray-traced reflections, AO and GI. */
    public static boolean rtEntities = true;
    /** Shaders mode: the first-person player casts a shadow (and appears in ray tracing). */
    public static boolean playerShadow = true;

    // water (shaders mode)
    public static int waterStyle = 0;             // 0 smooth waves, 1 pixel waves, 2 vanilla texture
    public static int waterWaveStrength = 100;    // percent
    public static int waterWaveSize = 100;
    public static int waterWaveSpeed = 100;
    public static boolean waterCalmIndoors = true;
    public static int waterReflectivity = 4;      // reflectance facing the surface, percent (2 = physical)
    public static int waterSunReflection = 100;
    public static int waterRefraction = 100;
    public static int waterFoam = 100;
    public static int waterFoamWidth = 100;
    public static int waterClarity = 10;          // blocks until half the light is gone
    public static int waterColorR = 100, waterColorG = 100, waterColorB = 100;
    public static boolean waterBiomeTint = true;
    public static int underwaterVisibility = 40;  // blocks until the fog hides half the view
    public static boolean underwaterOverlay = true;  // vanilla's water texture over the screen (both renderers)

    public static final int[] SHADOW_RESOLUTIONS = {2048, 4096, 8192};
    public static final int[] SHADOW_DISTANCES = {64, 96, 112, 128, 160, 192};

    private static File file;

    public static File file() {
        if (file == null) file = new File(new File(Minecraft.getMinecraft().mcDataDir, "config"), "metal189.properties");
        return file;
    }

    public static void load() {
        Options.all();   // the registry records defaults before any value is loaded
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
        for (Options.Opt o : Options.all()) {
            String v = p.getProperty(o.key);
            if (v != null) o.parse(v);
        }
        Native.LOG.info("metal189: Ctrl+left click is a {} click (mcmouser installed: {})",
                ctrlClickRightClick ? "right" : "left", metal189.core.Compat.mcmouserInstalled());
        applyInput();
    }

    public static void save() {
        Properties p = new Properties();
        for (Options.Opt o : Options.all()) p.setProperty(o.key, o.format());
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

    /** Input options live in the platform layer and apply in both renderers. */
    public static void applyInput() {
        Native.setOption(5, ctrlClickRightClick ? 1 : 0);
    }

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
