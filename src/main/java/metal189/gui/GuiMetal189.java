package metal189.gui;

import java.io.IOException;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import metal189.config.Config;
import metal189.config.Options;
import metal189.config.Options.Opt;
import metal189.engine.Native;
import metal189.world.Pipeline;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiButton;
import net.minecraft.client.gui.GuiListExtended;
import net.minecraft.client.gui.GuiScreen;
import net.minecraft.client.resources.I18n;
import net.minecraftforge.fml.client.config.GuiSlider;

/**
 * metal189 rendering settings (opened from Video Settings, Options or the settings keybind).
 * The main page holds the shaders switch and links to one page per topic; every page is a
 * scrolling list of two-column rows built from {@link Options}. Hovering an option shows
 * its description. In a world there is no dirt background, so changes preview live.
 */
public class GuiMetal189 extends GuiScreen implements GuiSlider.ISlider {
    private static final int DONE = 200, RESET = 201;
    private static final String MAIN = "main";

    private final GuiScreen parent;
    private final String page;
    private OptionList list;
    private final Map<GuiButton, Opt> options = new IdentityHashMap<GuiButton, Opt>();
    private final Map<GuiButton, String> links = new IdentityHashMap<GuiButton, String>();
    private GuiButton profileButton;   // main page: cycles the quality profiles
    private GuiButton hovered;
    private long hoverStart;
    /** Tests: show this option's tooltip as if hovered (the test window never moves the pointer). */
    public static String testHover;

    public GuiMetal189(GuiScreen parent) { this(parent, MAIN); }

    public GuiMetal189(GuiScreen parent, String page) {
        this.parent = parent;
        this.page = page;
    }

    @Override
    public void initGui() {
        buttonList.clear();
        options.clear();
        links.clear();
        list = new OptionList(mc, width, height, 32, height - 46, 25);
        List<GuiButton> cells = new ArrayList<GuiButton>();
        int id = 0;
        for (Opt o : Options.page(page)) {
            GuiButton b = o.kind == Options.Kind.SLIDER
                    ? new GuiSlider(id++, 0, 0, 150, 20, name(o) + ": ", o.unit, o.min, o.max, o.get(), false, true, this)
                    : new GuiButton(id++, 0, 0, 150, 20, "");
            if (b instanceof GuiSlider) b.displayString = ((GuiSlider) b).dispString + shown(o, o.get());
            options.put(b, o);
            cells.add(b);
        }
        if (MAIN.equals(page)) {
            profileButton = new GuiButton(id++, 0, 0, 150, 20, "");   // next to the shaders switch
            cells.add(profileButton);
            if (cells.size() % 2 != 0) cells.add(null);
            for (String p : Options.PAGES) {
                GuiButton b = new GuiButton(id++, 0, 0, 150, 20, I18n.format("metal189.page." + p) + "...");
                links.put(b, p);
                cells.add(b);
            }
        }
        for (int i = 0; i < cells.size(); i += 2)
            list.rows.add(new Row(cells.get(i), i + 1 < cells.size() ? cells.get(i + 1) : null));
        if (MAIN.equals(page)) {
            buttonList.add(new GuiButton(DONE, width / 2 - 100, height - 27, 200, 20, I18n.format("gui.done")));
        } else {
            buttonList.add(new GuiButton(RESET, width / 2 - 155, height - 27, 150, 20, I18n.format("metal189.gui.reset")));
            buttonList.add(new GuiButton(DONE, width / 2 + 5, height - 27, 150, 20, I18n.format("gui.done")));
        }
        refresh();
    }

    private static String name(Opt o) { return I18n.format("metal189.opt." + o.key); }

    private static String value(Opt o) {
        if ("rtLighting".equals(o.key)) {
            // the level the individual settings add up to
            int l = Options.rtLightingLevel();
            return I18n.format(l < 0 ? "metal189.profile.custom" : "metal189.opt.rtLighting." + l);
        }
        int v = o.get();
        String named = "metal189.opt." + o.key + "." + v, label = I18n.format(named);
        if (!label.equals(named)) return label;   // options may name their values
        switch (o.kind) {
            case TOGGLE: return I18n.format(v != 0 ? "options.on" : "options.off");
            default: return shown(o, v);
        }
    }

    // A number as shown: options whose unit starts with "/10" are kept in tenths ("/10 blocks": 2.5 blocks).
    private static String shown(Opt o, int v) {
        // a value can have its own name (metal189.opt.<key>.v<value>)
        String named = "metal189.opt." + o.key + ".v" + v;
        String s = I18n.format(named);
        if (!s.equals(named)) return s;
        if (o.unit.startsWith("/10")) return String.format(java.util.Locale.ROOT, "%.1f", v / 10f) + o.unit.substring(3);
        return v + o.unit;
    }

    private boolean available(Opt o) {
        if ((o.needs & Options.NEEDS_RT) != 0 && !Pipeline.rtSupported()) return false;
        return (o.needs & Options.NEEDS_SHADERS) == 0 || Config.shaders;
    }

    private void refresh() {
        if (profileButton != null) {
            int p = Options.currentProfile(Pipeline.rtAccelerated());
            profileButton.displayString = I18n.format("metal189.gui.profile") + ": "
                    + I18n.format("metal189.profile." + (p < 0 ? "custom" : Options.PROFILES[p]));
            profileButton.enabled = Config.shaders;
        }
        for (Map.Entry<GuiButton, Opt> e : options.entrySet()) {
            GuiButton b = e.getKey();
            Opt o = e.getValue();
            if (!(b instanceof GuiSlider)) {
                boolean noRt = (o.needs & Options.NEEDS_RT) != 0 && !Pipeline.rtSupported();
                b.displayString = name(o) + ": " + (noRt ? I18n.format("metal189.gui.unsupported") : value(o));
            }
            b.enabled = available(o);
        }
    }

    private void pressed(GuiButton b, boolean backwards) {
        if (!b.enabled) return;
        if (b == profileButton) {
            int n = Options.PROFILES.length, p = Options.currentProfile(Pipeline.rtAccelerated());
            p = p < 0 ? (backwards ? n - 1 : 0) : (p + (backwards ? n - 1 : 1)) % n;
            Options.applyProfile(p, Pipeline.rtAccelerated());
            Pipeline.apply();
            Config.save();
            refresh();
            return;
        }
        String link = links.get(b);
        if (link != null) {
            mc.displayGuiScreen(new GuiMetal189(this, link));
            return;
        }
        Opt o = options.get(b);
        if (o == null || b instanceof GuiSlider) return;
        if ("rtLighting".equals(o.key)) o.set(Math.max(0, Options.rtLightingLevel()));   // cycle from what is in effect
        o.cycle(backwards);
        changed(o);
        refresh();
    }

    private void changed(Opt o) {
        if ("ctrlClickRightClick".equals(o.key) || "maxRenderDistance".equals(o.key)) Config.applyInput();
        if ("rtLighting".equals(o.key)) Options.applyRtLighting(o.get());
        Pipeline.apply();
    }

    @Override
    protected void actionPerformed(GuiButton b) throws IOException {
        if (b.id == DONE) {
            Config.save();
            mc.displayGuiScreen(parent);
        } else if (b.id == RESET) {
            for (Opt o : Options.page(page)) o.set(Options.defaultValue(o, Pipeline.rtAccelerated()));
            Config.applyInput();
            Pipeline.apply();
            Config.save();
            initGui();
        }
    }

    @Override
    public void onChangeSliderValue(GuiSlider slider) {
        Opt o = options.get(slider);
        if (o == null) return;
        int v = o.sanitize(slider.getValueInt());
        // snap the knob to the option's step without re-entering updateSlider()
        slider.sliderValue = (v - slider.minValue) / (slider.maxValue - slider.minValue);
        slider.displayString = slider.dispString + shown(o, v);
        if (v != o.get()) {
            o.set(v);
            changed(o);
        }
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

    /** In a world the menu draws no dirt or dimming, so changes can be previewed live. */
    private boolean preview() { return mc.theWorld != null; }

    @Override
    public void drawScreen(int mouseX, int mouseY, float partialTicks) {
        if (preview()) {
            // only a light panel behind the option column keeps the text readable
            drawRect(width / 2 - 162, list.top(), width / 2 + 162, list.bottom(), 0x50000000);
            drawRect(0, 0, width, 30, 0x50000000);
            drawRect(0, list.bottom(), width, height, 0x50000000);
        } else {
            drawDefaultBackground();
        }
        list.drawScreen(mouseX, mouseY, partialTicks);
        String title = I18n.format("metal189.gui.title");
        if (!MAIN.equals(page)) title += " - " + I18n.format("metal189.page." + page);
        drawCenteredString(fontRendererObj, title, width / 2, 8, 0xFFFFFF);
        String dev = Native.deviceName() + (Pipeline.rtSupported() ? " - " + I18n.format("metal189.gui.rtAvailable") : "");
        drawCenteredString(fontRendererObj, dev, width / 2, 20, 0xA0A0A0);
        super.drawScreen(mouseX, mouseY, partialTicks);
        drawTooltip(mouseX, mouseY);
    }

    /** The hovered option's description, after a short delay (like vanilla's video settings tooltips in later versions). */
    private void drawTooltip(int mouseX, int mouseY) {
        GuiButton over = null;
        if (mouseY >= list.top() && mouseY < list.bottom())
            for (GuiButton b : options.keySet())
                if (b.visible && mouseX >= b.xPosition && mouseX < b.xPosition + b.width && mouseY >= b.yPosition
                        && mouseY < b.yPosition + b.height) over = b;
        if (testHover != null) {
            for (Map.Entry<GuiButton, Opt> e : options.entrySet())
                if (e.getValue().key.equals(testHover)) over = e.getKey();
            if (over != null) {
                mouseX = over.xPosition + over.width / 2;
                mouseY = over.yPosition + over.height / 2;
                hoverStart = 0;
                hovered = over;
            }
        }
        if (over != hovered) {
            hovered = over;
            hoverStart = System.currentTimeMillis();
        }
        if (mouseY >= list.top() && mouseY < list.bottom() && profileButton != null && profileButton.visible && mouseX >= profileButton.xPosition
                && mouseX < profileButton.xPosition + profileButton.width && mouseY >= profileButton.yPosition
                && mouseY < profileButton.yPosition + profileButton.height) {
            if (hovered != profileButton) { hovered = profileButton; hoverStart = System.currentTimeMillis(); }
            if (System.currentTimeMillis() - hoverStart >= 500)
                drawHoveringText(fontRendererObj.listFormattedStringToWidth(I18n.format("metal189.gui.profile.desc"), 220), mouseX, mouseY);
            return;
        }
        if (over == null || System.currentTimeMillis() - hoverStart < 500) return;
        String key = "metal189.opt." + options.get(over).key + ".desc";
        String text = I18n.format(key);
        if (text.equals(key)) return;   // no description
        List<String> lines = fontRendererObj.listFormattedStringToWidth(text, 220);
        drawHoveringText(lines, mouseX, mouseY);
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
            if (left != null) {
                left.xPosition = cx - 155;
                left.yPosition = y;
                left.drawButton(mc, mouseX, mouseY);
            }
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
                    pressed(b, mouseEvent == 1);
                    return true;
                }
            }
            return false;
        }

        @Override
        public void mouseReleased(int slotIndex, int x, int y, int mouseEvent, int relativeX, int relativeY) {
            if (left != null) left.mouseReleased(x, y);
            if (right != null) right.mouseReleased(x, y);
        }

        @Override
        public void setSelected(int a, int b, int c) {}
    }

    private final class OptionList extends GuiListExtended {
        final List<Row> rows = new ArrayList<Row>();

        OptionList(Minecraft mc, int width, int height, int top, int bottom, int slotHeight) {
            super(mc, width, height, top, bottom, slotHeight);
        }

        int top() { return top; }
        int bottom() { return bottom; }

        @Override
        protected void drawContainerBackground(net.minecraft.client.renderer.Tessellator t) {
            if (!preview()) super.drawContainerBackground(t);
        }

        @Override
        protected void overlayBackground(int startY, int endY, int startAlpha, int endAlpha) {
            if (!preview()) super.overlayBackground(startY, endY, startAlpha, endAlpha);
        }

        @Override
        protected void drawSelectionBox(int x, int y, int mouseX, int mouseY) {
            if (!preview()) {
                super.drawSelectionBox(x, y, mouseX, mouseY);
                return;
            }
            // without the dirt strips, rows scrolled out of the list area are clipped instead
            net.minecraft.client.gui.ScaledResolution sr = new net.minecraft.client.gui.ScaledResolution(mc);
            int f = sr.getScaleFactor();
            metal189.shim.GL11.glEnable(0x0C11);
            metal189.shim.GL11.glScissor(0, mc.displayHeight - bottom * f, mc.displayWidth, (bottom - top) * f);
            super.drawSelectionBox(x, y, mouseX, mouseY);
            metal189.shim.GL11.glDisable(0x0C11);
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
