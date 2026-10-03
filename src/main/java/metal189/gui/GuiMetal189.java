package metal189.gui;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import metal189.config.Config;
import metal189.engine.Native;
import metal189.world.Pipeline;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiButton;
import net.minecraft.client.gui.GuiListExtended;
import net.minecraft.client.gui.GuiScreen;
import net.minecraft.client.resources.I18n;
import net.minecraftforge.fml.client.config.GuiSlider;

/**
 * metal189 rendering settings (opened from Video Settings or the settings keybind):
 * a scrolling list of two-option rows, like vanilla's video settings.
 */
public class GuiMetal189 extends GuiScreen implements GuiSlider.ISlider {
    private enum Opt {
        SHADERS, TAA, SHADOWS, SHADOW_RES, SHADOW_DIST, BLOOM, SKY, WATER, WAVING, BLOOM_STRENGTH, CLOUDS, VOLUMETRICS,
        AUTO_EXP, EXPOSURE, SSAO, RT_SHADOWS, RT_REFL, RT_AO, RT_GI
    }

    private static final Opt[][] ROWS = {
        {Opt.SHADERS, Opt.TAA},
        {Opt.SHADOWS, Opt.SHADOW_RES},
        {Opt.SHADOW_DIST, Opt.BLOOM},
        {Opt.SKY, Opt.WATER},
        {Opt.CLOUDS, Opt.VOLUMETRICS},
        {Opt.WAVING, Opt.BLOOM_STRENGTH},
        {Opt.AUTO_EXP, Opt.EXPOSURE},
        {Opt.SSAO, null},
        {Opt.RT_SHADOWS, Opt.RT_REFL},
        {Opt.RT_AO, Opt.RT_GI},
    };
    private static final int DONE = 200;

    private final GuiScreen parent;
    private OptionList list;
    private final List<GuiButton> optionButtons = new ArrayList<GuiButton>();

    public GuiMetal189(GuiScreen parent) { this.parent = parent; }

    @Override
    public void initGui() {
        buttonList.clear();
        optionButtons.clear();
        list = new OptionList(mc, width, height, 32, height - 46, 25);
        for (Opt[] row : ROWS) list.rows.add(new Row(make(row[0]), row[1] == null ? null : make(row[1])));
        buttonList.add(new GuiButton(DONE, width / 2 - 100, height - 27, 200, 20, I18n.format("gui.done")));
        refresh();
    }

    private GuiButton make(Opt o) {
        GuiButton b;
        if (o == Opt.EXPOSURE)
            b = new GuiSlider(o.ordinal(), 0, 0, 150, 20, I18n.format("metal189.gui.exposure") + ": ", "%", 25, 400, Config.exposure, false, true, this);
        else if (o == Opt.BLOOM_STRENGTH)
            b = new GuiSlider(o.ordinal(), 0, 0, 150, 20, I18n.format("metal189.gui.bloomStrength") + ": ", "%", 0, 300, Config.bloomStrength, false, true, this);
        else
            b = new GuiButton(o.ordinal(), 0, 0, 150, 20, "");
        optionButtons.add(b);
        return b;
    }

    private static String onOff(boolean v) { return v ? I18n.format("options.on") : I18n.format("options.off"); }

    private static boolean isRt(Opt o) { return o == Opt.RT_SHADOWS || o == Opt.RT_REFL || o == Opt.RT_AO || o == Opt.RT_GI; }

    private void refresh() {
        boolean rt = Pipeline.rtSupported();
        for (GuiButton b : optionButtons) {
            Opt o = Opt.values()[b.id];
            String unsupported = I18n.format("metal189.gui.unsupported");
            switch (o) {
                case SHADERS: b.displayString = label("shaders", onOff(Config.shaders)); break;
                case TAA: b.displayString = label("taa", onOff(Config.taa)); break;
                case SHADOWS: b.displayString = label("shadows", onOff(Config.shadows)); break;
                case SHADOW_RES: b.displayString = label("shadowResolution", Integer.toString(Config.shadowResolution)); break;
                case SHADOW_DIST: b.displayString = label("shadowDistance", Integer.toString(Config.shadowDistance)); break;
                case BLOOM: b.displayString = label("bloom", onOff(Config.bloom)); break;
                case SKY: b.displayString = label("sky", onOff(Config.sky)); break;
                case WATER: b.displayString = label("water", onOff(Config.water)); break;
                case WAVING: b.displayString = label("waving", onOff(Config.waving)); break;
                case CLOUDS: b.displayString = label("clouds", onOff(Config.clouds)); break;
                case VOLUMETRICS: b.displayString = label("volumetrics", onOff(Config.volumetrics)); break;
                case AUTO_EXP: b.displayString = label("autoExposure", onOff(Config.autoExposure)); break;
                case SSAO: b.displayString = label("ssao", onOff(Config.ssao)); break;
                case RT_SHADOWS: b.displayString = label("rtShadows", rt ? onOff(Config.rtShadows) : unsupported); break;
                case RT_REFL: b.displayString = label("rtReflections", rt ? onOff(Config.rtReflections) : unsupported); break;
                case RT_AO: b.displayString = label("rtAO", rt ? onOff(Config.rtAmbientOcclusion) : unsupported); break;
                case RT_GI: b.displayString = label("rtGI", rt ? onOff(Config.rtGlobalIllumination) : unsupported); break;
                default: break;   // sliders draw their own label
            }
            b.enabled = o == Opt.SHADERS || (Config.shaders && (!isRt(o) || rt));
        }
    }

    private static String label(String key, String value) { return I18n.format("metal189.gui." + key) + ": " + value; }

    private void pressed(GuiButton b) {
        if (!b.enabled || b instanceof GuiSlider) return;
        switch (Opt.values()[b.id]) {
            case SHADERS: Config.shaders = !Config.shaders; break;
            case TAA: Config.taa = !Config.taa; break;
            case SHADOWS: Config.shadows = !Config.shadows; break;
            case SHADOW_RES: Config.shadowResolution = Config.next(Config.shadowResolution, Config.SHADOW_RESOLUTIONS); break;
            case SHADOW_DIST: Config.shadowDistance = Config.next(Config.shadowDistance, Config.SHADOW_DISTANCES); break;
            case BLOOM: Config.bloom = !Config.bloom; break;
            case SKY: Config.sky = !Config.sky; break;
            case WATER: Config.water = !Config.water; break;
            case WAVING: Config.waving = !Config.waving; break;
            case CLOUDS: Config.clouds = !Config.clouds; break;
            case VOLUMETRICS: Config.volumetrics = !Config.volumetrics; break;
            case AUTO_EXP: Config.autoExposure = !Config.autoExposure; break;
            case SSAO: Config.ssao = !Config.ssao; break;
            case RT_SHADOWS: Config.rtShadows = !Config.rtShadows; break;
            case RT_REFL: Config.rtReflections = !Config.rtReflections; break;
            case RT_AO: Config.rtAmbientOcclusion = !Config.rtAmbientOcclusion; break;
            case RT_GI: Config.rtGlobalIllumination = !Config.rtGlobalIllumination; break;
            default: return;
        }
        Config.save();
        Pipeline.apply();
        refresh();
    }

    @Override
    protected void actionPerformed(GuiButton b) throws IOException {
        if (b.id == DONE) {
            Config.save();
            mc.displayGuiScreen(parent);
        }
    }

    @Override
    public void onChangeSliderValue(GuiSlider slider) {
        Opt o = Opt.values()[slider.id];
        if (o == Opt.EXPOSURE) Config.exposure = slider.getValueInt();
        else if (o == Opt.BLOOM_STRENGTH) Config.bloomStrength = slider.getValueInt();
        Pipeline.apply();
    }

    @Override
    public void handleMouseInput() throws IOException {
        super.handleMouseInput();
        list.handleMouseInput();
    }

    @Override
    protected void mouseClicked(int mouseX, int mouseY, int button) throws IOException {
        super.mouseClicked(mouseX, mouseY, button);
        list.mouseClicked(mouseX, mouseY, button);
    }

    @Override
    protected void mouseReleased(int mouseX, int mouseY, int state) {
        super.mouseReleased(mouseX, mouseY, state);
        list.mouseReleased(mouseX, mouseY, state);
    }

    @Override
    public void onGuiClosed() { Config.save(); }

    @Override
    public void drawScreen(int mouseX, int mouseY, float partialTicks) {
        drawDefaultBackground();
        list.drawScreen(mouseX, mouseY, partialTicks);
        drawCenteredString(fontRendererObj, I18n.format("metal189.gui.title"), width / 2, 8, 0xFFFFFF);
        String dev = Native.deviceName() + (Pipeline.rtSupported() ? " - " + I18n.format("metal189.gui.rtAvailable") : "");
        drawCenteredString(fontRendererObj, dev, width / 2, 20, 0xA0A0A0);
        super.drawScreen(mouseX, mouseY, partialTicks);
    }

    private final class Row implements GuiListExtended.IGuiListEntry {
        final GuiButton left, right;

        Row(GuiButton left, GuiButton right) {
            this.left = left;
            this.right = right;
        }

        @Override
        public void drawEntry(int slotIndex, int x, int y, int listWidth, int slotHeight, int mouseX, int mouseY, boolean isSelected) {
            int cx = width / 2;
            left.xPosition = cx - 155;
            left.yPosition = y;
            left.drawButton(mc, mouseX, mouseY);
            if (right != null) {
                right.xPosition = cx + 5;
                right.yPosition = y;
                right.drawButton(mc, mouseX, mouseY);
            }
        }

        @Override
        public boolean mousePressed(int slotIndex, int mouseX, int mouseY, int mouseEvent, int relativeX, int relativeY) {
            for (GuiButton b : new GuiButton[] {left, right}) {
                if (b != null && b.mousePressed(mc, mouseX, mouseY)) {
                    b.playPressSound(mc.getSoundHandler());
                    pressed(b);
                    return true;
                }
            }
            return false;
        }

        @Override
        public void mouseReleased(int slotIndex, int x, int y, int mouseEvent, int relativeX, int relativeY) {
            left.mouseReleased(x, y);
            if (right != null) right.mouseReleased(x, y);
        }

        @Override
        public void setSelected(int a, int b, int c) {}
    }

    private static final class OptionList extends GuiListExtended {
        final List<Row> rows = new ArrayList<Row>();

        OptionList(Minecraft mc, int width, int height, int top, int bottom, int slotHeight) {
            super(mc, width, height, top, bottom, slotHeight);
        }

        @Override
        public IGuiListEntry getListEntry(int index) { return rows.get(index); }

        @Override
        protected int getSize() { return rows.size(); }

        @Override
        protected int getScrollBarX() { return width / 2 + 160; }

        @Override
        public int getListWidth() { return 320; }
    }
}
