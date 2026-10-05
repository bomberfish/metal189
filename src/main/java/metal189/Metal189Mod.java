package metal189;

import metal189.config.Config;
import metal189.gui.ClientEvents;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.common.FMLCommonHandler;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.common.event.FMLInitializationEvent;

@Mod(modid = "metal189", name = "metal189", version = "0.2.0-pre", clientSideOnly = true, acceptedMinecraftVersions = "[1.8.9]")
public class Metal189Mod {
    @Mod.EventHandler
    public void init(FMLInitializationEvent e) {
        if (metal189.core.Settings.conflict != null) {
            MinecraftForge.EVENT_BUS.register(new metal189.gui.ConflictNotice(metal189.core.Settings.conflict));
            return;
        }
        if (metal189.core.Settings.DISABLED) return;
        Config.load();
        ClientEvents events = new ClientEvents();
        MinecraftForge.EVENT_BUS.register(events);
        FMLCommonHandler.instance().bus().register(events);
    }
}
