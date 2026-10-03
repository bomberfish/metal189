package metal189.core;

import java.util.Map;
import net.minecraftforge.fml.relauncher.IFMLLoadingPlugin;

@IFMLLoadingPlugin.Name("metal189")
@IFMLLoadingPlugin.MCVersion("1.8.9")
@IFMLLoadingPlugin.SortingIndex(2000) // after FML's deobfuscation (names are SRG/MCP)
@IFMLLoadingPlugin.TransformerExclusions({"metal189."})
public class Metal189Plugin implements IFMLLoadingPlugin {
    @Override
    public String[] getASMTransformerClass() {
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
