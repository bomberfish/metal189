package metal189.core;

import java.io.File;
import java.util.List;
import java.util.Map;
import net.minecraft.launchwrapper.Launch;
import net.minecraftforge.fml.relauncher.IFMLLoadingPlugin;

@IFMLLoadingPlugin.Name("metal189")
@IFMLLoadingPlugin.MCVersion("1.8.9")
@IFMLLoadingPlugin.SortingIndex(2000) // after FML's deobfuscation (names are SRG/MCP)
@IFMLLoadingPlugin.TransformerExclusions({"metal189."})
public class Metal189Plugin implements IFMLLoadingPlugin {
    @Override
    public String[] getASMTransformerClass() {
        Settings.conflict = detectConflict();
        if (Settings.conflict != null) {
            Metal189Transformer.LOG.error("metal189: {} is installed; metal189 stays disabled (it replaces OptiFine). "
                    + "Remove {} from the mods folder to use metal189.", Settings.conflict, Settings.conflict);
            if (metal189.test.TestDriver.active()) {
                // test runs keep the reference-mode background window (never steal focus)
                metal189.engine.Native.load();
                metal189.engine.Native.refModeInstall();
                return new String[] {"metal189.core.ReferenceTransformer"};
            }
            return new String[0];
        }
        if (Settings.DISABLED) {
            // Vanilla OpenGL rendering; only input and the test driver are hooked.
            if (metal189.test.TestDriver.active()) {
                metal189.engine.Native.load();
                metal189.engine.Native.refModeInstall();
                return new String[] {"metal189.core.ReferenceTransformer"};
            }
            return new String[0];
        }
        return new String[] {"metal189.core.Metal189Transformer"};
    }

    /** OptiFine patches the same renderer classes and drives GL itself; the two cannot run together. */
    @SuppressWarnings("unchecked")
    private static String detectConflict() {
        try {
            Object tweaks = Launch.blackboard == null ? null : Launch.blackboard.get("TweakClasses");
            if (tweaks instanceof List)
                for (Object t : (List<Object>) tweaks)
                    if (String.valueOf(t).toLowerCase().contains("optifine")) return "OptiFine";
            if (Launch.classLoader != null && Launch.classLoader.findResource("optifine/OptiFineForgeTweaker.class") != null) return "OptiFine";
            File mods = new File(Launch.minecraftHome != null ? Launch.minecraftHome : new File("."), "mods");
            File[] files = mods.listFiles();
            if (files != null)
                for (File f : files)
                    if (f.getName().toLowerCase().contains("optifine") && f.getName().toLowerCase().endsWith(".jar")) return "OptiFine";
        } catch (Throwable ignored) {
        }
        return null;
    }

    @Override
    public String getModContainerClass() { return null; }

    @Override
    public String getSetupClass() { return null; }

    @Override
    public void injectData(Map<String, Object> data) {
        Object dev = data.get("runtimeDeobfuscationEnabled");
        Names.obfuscated = dev instanceof Boolean && (Boolean) dev;
    }

    @Override
    public String getAccessTransformerClass() { return null; }
}
