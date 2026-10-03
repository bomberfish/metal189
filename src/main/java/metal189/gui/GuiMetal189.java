package metal189.gui;

import java.io.IOException;
import metal189.config.Config;
import metal189.engine.Native;
import metal189.world.Pipeline;
import net.minecraft.client.gui.GuiButton;
import net.minecraft.client.gui.GuiScreen;
import net.minecraft.client.resources.I18n;
import net.minecraftforge.fml.client.config.GuiSlider;

/** metal189 rendering settings (opened from Video Settings or the settings keybind). */
public class GuiMetal189 extends GuiScreen implements GuiSlider.ISlider {
    private static final int SHADERS = 1, SHADOWS = 2, SHADOW_RES = 3, SHADOW_DIST = 4, BLOOM = 5, SKY = 6, WATER = 7,
            WAVING = 8, RT_SHADOWS = 9, RT_REFL = 10, EXPOSURE = 11, BLOOM_STRENGTH = 12, TAA = 13, CLOUDS = 14, VOLUMETRICS = 15,
            DONE = 200;

    private final GuiScreen parent;

    public GuiMetal189(GuiScreen parent) { this.parent = parent; }

    private int infoY;

    @Override
    public void initGui() {
        buttonList.clear();
        // compact rows so everything fits above Done at the smallest GUI size (240 px tall)
        int x0 = width / 2 - 155, x1 = width / 2 + 5;
        int y = Math.max(28, height / 6 - 12);
        buttonList.add(new GuiButton(SHADERS, width / 2 - 100, y, 200, 20, ""));
        y += 24;
        buttonList.add(new GuiButton(SHADOWS, x0, y, 150, 20, ""));
        buttonList.add(new GuiButton(SHADOW_RES, x1, y, 150, 20, ""));
        y += 22;
        buttonList.add(new GuiButton(SHADOW_DIST, x0, y, 150, 20, ""));
        buttonList.add(new GuiButton(BLOOM, x1, y, 150, 20, ""));
        y += 22;
        buttonList.add(new GuiButton(SKY, x0, y, 150, 20, ""));
        buttonList.add(new GuiButton(WATER, x1, y, 150, 20, ""));
        y += 22;
        buttonList.add(new GuiButton(WAVING, x0, y, 150, 20, ""));
        buttonList.add(new GuiSlider(BLOOM_STRENGTH, x1, y, 150, 20, I18n.format("metal189.gui.bloomStrength") + ": ", "%",
                0, 300, Config.bloomStrength, false, true, this));
        y += 22;
        buttonList.add(new GuiSlider(EXPOSURE, x0, y, 150, 20, I18n.format("metal189.gui.exposure") + ": ", "%",
                25, 400, Config.exposure, false, true, this));
        buttonList.add(new GuiButton(TAA, x1, y, 150, 20, ""));
        y += 22;
        buttonList.add(new GuiButton(CLOUDS, x0, y, 150, 20, ""));
        buttonList.add(new GuiButton(VOLUMETRICS, x1, y, 150, 20, ""));
        y += 26;
        buttonList.add(new GuiButton(RT_SHADOWS, x0, y, 150, 20, ""));
        buttonList.add(new GuiButton(RT_REFL, x1, y, 150, 20, ""));
        infoY = y + 24;
        buttonList.add(new GuiButton(DONE, width / 2 - 100, Math.max(infoY + 12, height - 27), 200, 20, I18n.format("gui.done")));
        refresh();
    }

    private static String onOff(boolean v) { return v ? I18n.format("options.on") : I18n.format("options.off"); }

    private void refresh() {
        boolean rt = Pipeline.rtSupported();
        for (GuiButton b : buttonList) {
            switch (b.id) {
                case SHADERS: b.displayString = I18n.format("metal189.gui.shaders") + ": " + onOff(Config.shaders); break;
                case SHADOWS: b.displayString = I18n.format("metal189.gui.shadows") + ": " + onOff(Config.shadows); break;
                case SHADOW_RES: b.displayString = I18n.format("metal189.gui.shadowResolution") + ": " + Config.shadowResolution; break;
                case SHADOW_DIST: b.displayString = I18n.format("metal189.gui.shadowDistance") + ": " + Config.shadowDistance; break;
                case BLOOM: b.displayString = I18n.format("metal189.gui.bloom") + ": " + onOff(Config.bloom); break;
                case SKY: b.displayString = I18n.format("metal189.gui.sky") + ": " + onOff(Config.sky); break;
                case WATER: b.displayString = I18n.format("metal189.gui.water") + ": " + onOff(Config.water); break;
                case WAVING: b.displayString = I18n.format("metal189.gui.waving") + ": " + onOff(Config.waving); break;
                case TAA: b.displayString = I18n.format("metal189.gui.taa") + ": " + onOff(Config.taa); break;
                case CLOUDS: b.displayString = I18n.format("metal189.gui.clouds") + ": " + onOff(Config.clouds); break;
                case VOLUMETRICS: b.displayString = I18n.format("metal189.gui.volumetrics") + ": " + onOff(Config.volumetrics); break;
                case RT_SHADOWS:
                    b.enabled = rt;
                    b.displayString = I18n.format("metal189.gui.rtShadows") + ": " + (rt ? onOff(Config.rtShadows) : I18n.format("metal189.gui.unsupported"));
                    break;
                case RT_REFL:
                    b.enabled = rt;
                    b.displayString = I18n.format("metal189.gui.rtReflections") + ": " + (rt ? onOff(Config.rtReflections) : I18n.format("metal189.gui.unsupported"));
                    break;
                default: break;
            }
            if (b.id != SHADERS && b.id != DONE && b.id != RT_SHADOWS && b.id != RT_REFL) b.enabled = Config.shaders;
            if ((b.id == RT_SHADOWS || b.id == RT_REFL) && !Config.shaders) b.enabled = false;
        }
    }

    @Override
    protected void actionPerformed(GuiButton b) throws IOException {
        if (!b.enabled) return;
        switch (b.id) {
            case SHADERS: Config.shaders = !Config.shaders; break;
            case SHADOWS: Config.shadows = !Config.shadows; break;
            case SHADOW_RES: Config.shadowResolution = Config.next(Config.shadowResolution, Config.SHADOW_RESOLUTIONS); break;
            case SHADOW_DIST: Config.shadowDistance = Config.next(Config.shadowDistance, Config.SHADOW_DISTANCES); break;
            case BLOOM: Config.bloom = !Config.bloom; break;
            case SKY: Config.sky = !Config.sky; break;
            case WATER: Config.water = !Config.water; break;
            case WAVING: Config.waving = !Config.waving; break;
            case TAA: Config.taa = !Config.taa; break;
            case CLOUDS: Config.clouds = !Config.clouds; break;
            case VOLUMETRICS: Config.volumetrics = !Config.volumetrics; break;
            case RT_SHADOWS: Config.rtShadows = !Config.rtShadows; break;
            case RT_REFL: Config.rtReflections = !Config.rtReflections; break;
            case DONE:
                Config.save();
                mc.displayGuiScreen(parent);
                return;
            default: return;
        }
        Config.save();
        Pipeline.apply();
        refresh();
    }

    @Override
    public void onChangeSliderValue(GuiSlider slider) {
        if (slider.id == EXPOSURE) Config.exposure = slider.getValueInt();
        else if (slider.id == BLOOM_STRENGTH) Config.bloomStrength = slider.getValueInt();
        Pipeline.apply();
    }

    @Override
    public void onGuiClosed() { Config.save(); }

    @Override
    public void drawScreen(int mouseX, int mouseY, float partialTicks) {
        drawDefaultBackground();
        drawCenteredString(fontRendererObj, I18n.format("metal189.gui.title"), width / 2, Math.max(28, height / 6 - 12) - 16, 0xFFFFFF);
        String dev = Native.deviceName() + (Pipeline.rtSupported() ? " · " + I18n.format("metal189.gui.rtAvailable") : "");
        drawCenteredString(fontRendererObj, dev, width / 2, infoY, 0xA0A0A0);
        super.drawScreen(mouseX, mouseY, partialTicks);
    }
}
