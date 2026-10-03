package metal189.core;

import java.io.File;
import net.minecraft.launchwrapper.Launch;

/** Detection of other mods whose behaviour metal189's own platform layer has to honour. */
public final class Compat {
    private Compat() {}

    private static Boolean mcmouser;

    /**
     * mcmouser patches LWJGL's macOS native library so Ctrl+left click stays a left click.
     * metal189 does not use LWJGL's native input, so it applies that behaviour itself.
     */
    public static boolean mcmouserInstalled() {
        if (mcmouser == null) {
            boolean found = false;
            try {
                found = Launch.classLoader != null && Launch.classLoader.findResource("me/virb3/mcmouser/CoreMod.class") != null;
                if (!found) {
                    File[] files = new File(Launch.minecraftHome != null ? Launch.minecraftHome : new File("."), "mods").listFiles();
                    if (files != null)
                        for (File f : files)
                            if (f.getName().toLowerCase().startsWith("mcmouser") && f.getName().endsWith(".jar")) found = true;
                }
            } catch (Throwable ignored) {
            }
            mcmouser = found;
        }
        return mcmouser;
    }
}
