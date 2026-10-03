package metal189.world;

import java.awt.image.BufferedImage;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.util.Arrays;
import java.util.Map;
import javax.imageio.ImageIO;
import metal189.engine.Mem;
import metal189.engine.Native;
import metal189.gl.Textures;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.client.renderer.texture.TextureMap;
import net.minecraft.client.resources.IResource;
import net.minecraft.client.resources.IResourceManager;
import net.minecraft.util.ResourceLocation;

/**
 * LabPBR material atlases. After the block atlas is stitched, every sprite's
 * {@code _n} (normal xy, AO, height) and {@code _s} (smoothness, F0/metal,
 * porosity/SSS, emission) textures are looked up in the resource packs and
 * written to two atlases with the same layout, so the terrain shaders can sample
 * them with the colour atlas' coordinates. Nothing is built when no pack provides
 * material textures.
 */
public final class PbrAtlas {
    private PbrAtlas() {}

    private static int normalTex, specularTex;
    // texture formats for uploads (BGRA bytes from ARGB ints)
    private static final int GL_RGBA8 = 0x1908 /* GL_RGBA, as vanilla allocates */, GL_BGRA = 0x80E1, GL_UNSIGNED_INT_8_8_8_8_REV = 0x8367;
    private static final int FLAT_NORMAL = 0xFF8080FF;   // A height 1, R/G 0.5 (flat), B AO 1

    /** Tail of TextureMap.loadTextureAtlas. */
    public static void onStitched(TextureMap map) {
        try {
            Minecraft mc = Minecraft.getMinecraft();
            if (map != mc.getTextureMapBlocks() && mc.getTextureMapBlocks() != null) return;
            build(map, mc.getResourceManager());
        } catch (Throwable t) {
            Native.LOG.warn("metal189: PBR atlas build failed: {}", t.toString());
            release();
        }
    }

    public static boolean active() { return normalTex != 0; }

    @SuppressWarnings("unchecked")
    private static void build(TextureMap map, IResourceManager rm) throws Exception {
        release();
        int gl = map.getGlTextureId();
        int w = Textures.width(gl, 0), h = Textures.height(gl, 0);
        if (w <= 0 || h <= 0) return;
        Map<String, TextureAtlasSprite> sprites = (Map<String, TextureAtlasSprite>) field(TextureMap.class, map, "mapUploadedSprites", "field_94252_e");
        int levels = 1 + ((Integer) field(TextureMap.class, map, "mipmapLevels", "field_147636_j"));
        int[] nrm = new int[w * h];
        int[] spc = new int[w * h];
        Arrays.fill(nrm, FLAT_NORMAL);
        int found = 0;
        for (TextureAtlasSprite s : sprites.values()) {
            ResourceLocation base = new ResourceLocation(s.getIconName());
            String path = "textures/" + base.getResourcePath();
            BufferedImage n = load(rm, new ResourceLocation(base.getResourceDomain(), path + "_n.png"));
            BufferedImage sp = load(rm, new ResourceLocation(base.getResourceDomain(), path + "_s.png"));
            if (n == null && sp == null) continue;
            found++;
            int ox = s.getOriginX(), oy = s.getOriginY(), sw = s.getIconWidth(), sh = s.getIconHeight();
            if (n != null) blit(n, nrm, w, h, ox, oy, sw, sh);
            if (sp != null) blit(sp, spc, w, h, ox, oy, sw, sh);
        }
        if (found == 0) {
            Native.advSetPbr(0, 0);
            return;
        }
        normalTex = upload(nrm, w, h, levels);
        specularTex = upload(spc, w, h, levels);
        Native.advSetPbr(normalTex, specularTex);
        Native.LOG.info("metal189: PBR materials for {} sprites ({}x{} atlas, {} levels)", found, w, h, levels);
    }

    private static void release() {
        if (normalTex != 0) Textures.delete(normalTex);
        if (specularTex != 0) Textures.delete(specularTex);
        normalTex = specularTex = 0;
        Native.advSetPbr(0, 0);
    }

    private static Object field(Class<?> c, Object o, String mcp, String srg) throws Exception {
        Field f;
        try {
            f = c.getDeclaredField(srg);
        } catch (NoSuchFieldException e) {
            f = c.getDeclaredField(mcp);
        }
        f.setAccessible(true);
        return f.get(o);
    }

    private static BufferedImage load(IResourceManager rm, ResourceLocation loc) {
        InputStream in = null;
        try {
            IResource r = rm.getResource(loc);
            in = r.getInputStream();
            return ImageIO.read(in);
        } catch (Exception e) {
            return null;
        } finally {
            if (in != null) try { in.close(); } catch (Exception ignored) {}
        }
    }

    /** Copies frame 0 of img (nearest-scaled to the sprite size) into the atlas. */
    private static void blit(BufferedImage img, int[] atlas, int aw, int ah, int ox, int oy, int sw, int sh) {
        int iw = img.getWidth();
        int ih = Math.min(img.getHeight(), iw * sh / Math.max(sw, 1)); // animation strips: first frame
        if (iw <= 0 || ih <= 0) return;
        for (int y = 0; y < sh; y++) {
            int ty = oy + y;
            if (ty < 0 || ty >= ah) continue;
            int sy = y * ih / sh;
            for (int x = 0; x < sw; x++) {
                int tx = ox + x;
                if (tx < 0 || tx >= aw) continue;
                atlas[ty * aw + tx] = img.getRGB(x * iw / sw, sy);
            }
        }
    }

    private static int upload(int[] argb, int w, int h, int levels) {
        int id = Textures.gen();
        int[] cur = argb;
        int lw = w, lh = h;
        for (int level = 0; level < levels && lw > 0 && lh > 0; level++) {
            long buf = Mem.malloc((long) lw * lh * 4);
            for (int i = 0; i < lw * lh; i++) Mem.U.putInt(buf + i * 4L, cur[i]);
            Native.texImage(id, level, GL_RGBA8, lw, lh, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, buf, lw);
            Mem.free(buf);
            if (level + 1 < levels) {
                int nw = Math.max(1, lw / 2), nh = Math.max(1, lh / 2);
                cur = downsample(cur, lw, lh, nw, nh);
                lw = nw;
                lh = nh;
            }
        }
        return id;
    }

    /** 2x2 box filter per channel. */
    private static int[] downsample(int[] src, int w, int h, int nw, int nh) {
        int[] dst = new int[nw * nh];
        for (int y = 0; y < nh; y++)
            for (int x = 0; x < nw; x++) {
                int a = 0, r = 0, g = 0, b = 0;
                for (int dy = 0; dy < 2; dy++)
                    for (int dx = 0; dx < 2; dx++) {
                        int p = src[Math.min(h - 1, y * 2 + dy) * w + Math.min(w - 1, x * 2 + dx)];
                        a += p >>> 24; r += (p >> 16) & 255; g += (p >> 8) & 255; b += p & 255;
                    }
                dst[y * nw + x] = ((a / 4) << 24) | ((r / 4) << 16) | ((g / 4) << 8) | (b / 4);
            }
        return dst;
    }
}
