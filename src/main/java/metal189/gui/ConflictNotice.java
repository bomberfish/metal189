package metal189.gui;

import net.minecraft.client.gui.GuiButton;
import net.minecraft.client.gui.GuiMainMenu;
import net.minecraft.client.gui.GuiScreen;
import net.minecraftforge.client.event.GuiOpenEvent;
import net.minecraftforge.fml.common.eventhandler.SubscribeEvent;

/** Tells the player once, on the main menu, why metal189 is inactive. */
public final class ConflictNotice {
    private final String mod;
    private boolean shown;

    public ConflictNotice(String mod) { this.mod = mod; }

    @SubscribeEvent
    public void onOpen(GuiOpenEvent e) {
        if (shown || !(e.gui instanceof GuiMainMenu)) return;
        shown = true;
        e.gui = new Screen(e.gui, mod);
    }

    private static final class Screen extends GuiScreen {
        private final GuiScreen next;
        private final String mod;

        Screen(GuiScreen next, String mod) {
            this.next = next;
            this.mod = mod;
        }

        @Override
        public void initGui() {
            buttonList.clear();
            buttonList.add(new GuiButton(0, width / 2 - 100, height / 2 + 40, 200, 20, "Continue"));
        }

        @Override
        protected void actionPerformed(GuiButton b) { mc.displayGuiScreen(next); }

        @Override
        public void drawScreen(int mouseX, int mouseY, float partialTicks) {
            drawDefaultBackground();
            drawCenteredString(fontRendererObj, "metal189 is disabled", width / 2, height / 2 - 40, 0xFF5555);
            drawCenteredString(fontRendererObj, mod + " is installed. metal189 replaces " + mod + ", so it stays off", width / 2, height / 2 - 20, 0xFFFFFF);
            drawCenteredString(fontRendererObj, "while both are present. Remove " + mod + " from the mods folder to use metal189.", width / 2, height / 2 - 8, 0xFFFFFF);
            drawCenteredString(fontRendererObj, "The game is running with vanilla OpenGL rendering.", width / 2, height / 2 + 12, 0xA0A0A0);
            super.drawScreen(mouseX, mouseY, partialTicks);
        }
    }
}
