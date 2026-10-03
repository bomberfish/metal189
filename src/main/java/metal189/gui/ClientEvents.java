package metal189.gui;

import metal189.world.Pipeline;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiButton;
import net.minecraft.client.gui.GuiVideoSettings;
import net.minecraft.client.resources.I18n;
import net.minecraft.client.settings.KeyBinding;
import net.minecraft.util.ChatComponentText;
import net.minecraftforge.client.event.GuiScreenEvent;
import net.minecraftforge.fml.client.registry.ClientRegistry;
import net.minecraftforge.fml.common.eventhandler.SubscribeEvent;
import net.minecraftforge.fml.common.gameevent.InputEvent;

/** Settings entry points: a button in Video Settings and two keybinds. */
public final class ClientEvents {
    private static final int BUTTON_ID = 0x189;
    // LWJGL key codes: F6 toggles the advanced pipeline; the settings key is unbound by default
    private final KeyBinding toggle = new KeyBinding("key.metal189.toggle", 64, "key.categories.metal189");
    private final KeyBinding settings = new KeyBinding("key.metal189.settings", 0, "key.categories.metal189");

    public ClientEvents() {
        ClientRegistry.registerKeyBinding(toggle);
        ClientRegistry.registerKeyBinding(settings);
    }

    @SubscribeEvent
    public void onInitGui(GuiScreenEvent.InitGuiEvent.Post e) {
        if (e.gui instanceof GuiVideoSettings)
            e.buttonList.add(new GuiButton(BUTTON_ID, e.gui.width - 105, 5, 100, 20, I18n.format("metal189.gui.button")));
    }

    @SubscribeEvent
    public void onAction(GuiScreenEvent.ActionPerformedEvent.Pre e) {
        if (e.gui instanceof GuiVideoSettings && e.button.id == BUTTON_ID) {
            Minecraft.getMinecraft().gameSettings.saveOptions();
            Minecraft.getMinecraft().displayGuiScreen(new GuiMetal189(e.gui));
            e.setCanceled(true);
        }
    }

    @SubscribeEvent
    public void onKey(InputEvent.KeyInputEvent e) {
        Minecraft mc = Minecraft.getMinecraft();
        if (toggle.isPressed()) {
            Pipeline.toggle();
            if (mc.thePlayer != null)
                mc.thePlayer.addChatMessage(new ChatComponentText(I18n.format(Pipeline.advanced() ? "metal189.msg.on" : "metal189.msg.off")));
        }
        if (settings.isPressed()) mc.displayGuiScreen(new GuiMetal189(mc.currentScreen));
    }
}
