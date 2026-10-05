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

/** Settings entry points (a button in Video Settings and two keybinds), and vanilla overlays the settings can hide. */
public final class ClientEvents {
    private static final int BUTTON_ID = 0x189;
    // LWJGL key codes: K toggles the advanced pipeline (as in Iris; F6 belongs to 1.8.9's stream
    // keys); the settings key is unbound by default
    private final KeyBinding toggle = new KeyBinding("key.metal189.toggle", 37, "key.categories.metal189");
    private final KeyBinding settings = new KeyBinding("key.metal189.settings", 0, "key.categories.metal189");

    public ClientEvents() {
        ClientRegistry.registerKeyBinding(toggle);
        ClientRegistry.registerKeyBinding(settings);
    }

    private static final int SUPER_SECRET_ID = 8675309, DONE_ID = 200;

    @SubscribeEvent
    public void onInitGui(GuiScreenEvent.InitGuiEvent.Post e) {
        String label = I18n.format("metal189.gui.button");
        if (e.gui instanceof GuiVideoSettings) {
            // bottom row becomes [Rendering...] [Done], where OptiFine users look for Shaders...
            for (GuiButton b : e.buttonList) {
                if (b.id == DONE_ID) {
                    b.xPosition = e.gui.width / 2 + 5;
                    b.width = 150;
                }
            }
            e.buttonList.add(new GuiButton(BUTTON_ID, e.gui.width / 2 - 155, e.gui.height - 27, 150, 20, label));
        } else if (e.gui instanceof net.minecraft.client.gui.GuiOptions) {
            // "Super Secret Settings" cycles GLSL post effects, which metal189 does not run;
            // its slot in the main Options screen becomes Rendering...
            for (int i = 0; i < e.buttonList.size(); i++) {
                GuiButton b = e.buttonList.get(i);
                if (b.id == SUPER_SECRET_ID) {
                    e.buttonList.set(i, new GuiButton(BUTTON_ID, b.xPosition, b.yPosition, b.width, b.height, label));
                    break;
                }
            }
        }
    }

    @SubscribeEvent
    public void onAction(GuiScreenEvent.ActionPerformedEvent.Pre e) {
        if ((e.gui instanceof GuiVideoSettings || e.gui instanceof net.minecraft.client.gui.GuiOptions) && e.button.id == BUTTON_ID) {
            Minecraft.getMinecraft().gameSettings.saveOptions();
            Minecraft.getMinecraft().displayGuiScreen(new GuiMetal189(e.gui));
            e.setCanceled(true);
        }
    }

    /** Vanilla's wavy screen overlay while the head is under water, if the user turned it off. */
    @SubscribeEvent
    public void onBlockOverlay(net.minecraftforge.client.event.RenderBlockOverlayEvent e) {
        if (e.overlayType == net.minecraftforge.client.event.RenderBlockOverlayEvent.OverlayType.WATER
                && !metal189.config.Config.underwaterOverlay) e.setCanceled(true);
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
