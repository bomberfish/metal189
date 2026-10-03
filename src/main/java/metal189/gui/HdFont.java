package metal189.gui;

import java.awt.image.BufferedImage;
import java.io.InputStream;
import java.lang.reflect.Field;
import metal189.engine.Native;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.FontRenderer;
import net.minecraft.client.renderer.texture.TextureUtil;
import net.minecraft.util.ResourceLocation;

/**
 * High-resolution font support, as OptiFine provides it. Vanilla measures each glyph by
 * scanning for the last column with any non-zero alpha, which breaks fonts whose
 * backgrounds are not fully transparent (Faithful's 512px font uses alpha 3 there):
 * every glyph measures the full cell and text spreads out. Widths are recomputed here
 * with OptiFine's alpha threshold at the texture's own resolution. Vanilla's font
 * (alpha 0 or 255 only) measures exactly as before.
 */
public final class HdFont {
    private HdFont() {}

    private static final int ALPHA_THRESHOLD = 16;
    private static Field charWidthField, locationField;

    /** Tail of FontRenderer.readFontTexture. */
    public static void afterReadFontTexture(FontRenderer fr) {
        try {
            if (charWidthField == null) {
                charWidthField = field("charWidth", "field_78286_d");
                locationField = field("locationFontTexture", "field_111273_g");
            }
            int[] widths = (int[]) charWidthField.get(fr);
            ResourceLocation loc = (ResourceLocation) locationField.get(fr);
            BufferedImage img;
            InputStream in = Minecraft.getMinecraft().getResourceManager().getResource(loc).getInputStream();
            try {
                img = TextureUtil.readBufferedImage(in);
            } finally {
                in.close();
            }
            measure(img, widths);
        } catch (Exception e) {
            Native.LOG.warn("metal189: font width fix skipped: {}", e.toString());
        }
    }

    /** Glyph widths in vanilla's 8-pixel-cell units, including vanilla's 1-unit gap. */
    static void measure(BufferedImage img, int[] widths) {
        int w = img.getWidth(), h = img.getHeight();
        int[] px = new int[w * h];
        img.getRGB(0, 0, w, h, px, 0, w);
        int cellW = w / 16, cellH = h / 16;
        float scale = 8.0f / cellW;
        // same formula as vanilla for every entry (vanilla's space special case is
        // overwritten by it too; renderChar/getCharWidth special-case ' ' themselves)
        for (int ch = 0; ch < 256; ch++) {
            int cx = ch % 16, cy = ch / 16;
            int col;
            for (col = cellW - 1; col >= 0; col--) {
                boolean empty = true;
                int x = cx * cellW + col;
                for (int row = 0; row < cellH && empty; row++)
                    if ((px[(cy * cellH + row) * w + x] >>> 24) > ALPHA_THRESHOLD) empty = false;
                if (!empty) break;
            }
            widths[ch] = (int) (0.5 + (col + 1) * scale) + 1;
        }
    }

    private static Field field(String mcp, String srg) throws NoSuchFieldException {
        Field f;
        try {
            f = FontRenderer.class.getDeclaredField(srg);
        } catch (NoSuchFieldException e) {
            f = FontRenderer.class.getDeclaredField(mcp);
        }
        f.setAccessible(true);
        return f;
    }
}
