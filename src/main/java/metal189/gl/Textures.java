package metal189.gl;

import static org.lwjgl.opengl.GL11.*;

import java.nio.Buffer;
import java.util.HashMap;
import metal189.engine.Mem;
import metal189.engine.Native;

/**
 * Texture objects. Storage lives natively (MTLTexture + sampler); the Java
 * side keeps level sizes and sampling parameters for queries and for pushing
 * sampler changes.
 */
public final class Textures {
    private Textures() {}

    static final class Tex {
        final int id;
        final int[] w = new int[16], h = new int[16];
        int internalFormat = GL_RGBA;
        int minFilter = GL_NEAREST_MIPMAP_LINEAR, magFilter = GL_LINEAR;
        int wrapS = GL_REPEAT, wrapT = GL_REPEAT;
        int maxLevel = 1000;
        float minLod = -1000f, maxLod = 1000f, aniso = 1f;
        boolean paramsDirty = true;

        Tex(int id) { this.id = id; }
    }

    private static final HashMap<Integer, Tex> textures = new HashMap<Integer, Tex>();
    private static int nextId = 1;
    // GL_PROXY_TEXTURE_2D query state
    private static int proxyW, proxyH;
    public static final int MAX_SIZE = 16384;

    public static int gen() {
        int id = nextId++;
        textures.put(id, new Tex(id));
        return id;
    }

    public static void delete(int id) {
        if (textures.remove(id) != null) Native.texDelete(id);
        for (int u = 0; u < GL.UNITS; u++) {
            if (GL.boundTex[u] == id) { GL.boundTex[u] = 0; GL.dirty |= GL.D_UNITS; }
        }
    }

    public static boolean isTexture(int id) { return textures.containsKey(id); }

    public static void bind(int target, int id) {
        if (target != GL_TEXTURE_2D) return;
        if (id != 0 && !textures.containsKey(id)) textures.put(id, new Tex(id)); // bind creates the name
        if (GL.boundTex[GL.activeUnit] != id) {
            GL.boundTex[GL.activeUnit] = id;
            GL.dirty |= GL.D_UNITS;
        }
    }

    private static Tex bound() {
        int id = GL.boundTex[GL.activeUnit];
        return id == 0 ? null : textures.get(id);
    }

    // ------------------------------------------------------------------

    public static void texImage2D(int target, int level, int internalFormat, int w, int h, int format, int type, Buffer data) {
        if (target == 0x8064 /* GL_PROXY_TEXTURE_2D */) {
            boolean ok = w <= MAX_SIZE && h <= MAX_SIZE;
            proxyW = ok ? w : 0;
            proxyH = ok ? h : 0;
            return;
        }
        Tex t = bound();
        if (t == null || level < 0 || level >= 16) return;
        t.internalFormat = internalFormat;
        t.w[level] = w;
        t.h[level] = h;
        pushParams(t);
        long addr = data == null ? 0 : Mem.positionAddress(data) + unpackOffset(w, format, type);
        Native.texImage(t.id, level, internalFormat, w, h, format, type, addr, rowLength(w));
    }

    public static void texSubImage2D(int target, int level, int x, int y, int w, int h, int format, int type, Buffer data) {
        Tex t = bound();
        if (t == null || data == null || w <= 0 || h <= 0) return;
        pushParams(t);
        long addr = Mem.positionAddress(data) + unpackOffset(w, format, type);
        Native.texSubImage(t.id, level, x, y, w, h, format, type, addr, rowLength(w));
    }

    public static void copyTexSubImage2D(int level, int xoff, int yoff, int x, int y, int w, int h) {
        Tex t = bound();
        if (t == null) return;
        Draw.flush();
        long p = metal189.engine.Engine.cmd.begin(metal189.engine.Cmd.COPY_TEX, 9);
        Mem.putInt(p, t.id);
        Mem.putInt(p + 4, level);
        Mem.putInt(p + 8, xoff);
        Mem.putInt(p + 12, yoff);
        Mem.putInt(p + 16, x);
        Mem.putInt(p + 20, y);
        Mem.putInt(p + 24, w);
        Mem.putInt(p + 28, h);
    }

    private static int rowLength(int w) { return GL.unpackRowLength > 0 ? GL.unpackRowLength : w; }

    private static long unpackOffset(int w, int format, int type) {
        if (GL.unpackSkipPixels == 0 && GL.unpackSkipRows == 0) return 0;
        int bpp = bytesPerPixel(format, type);
        return ((long) GL.unpackSkipRows * rowLength(w) + GL.unpackSkipPixels) * bpp;
    }

    static int bytesPerPixel(int format, int type) {
        int comps;
        switch (format) {
            case GL_RGBA: case 0x80E1 /* BGRA */: comps = 4; break;
            case GL_RGB: case 0x80E0 /* BGR */: comps = 3; break;
            case GL_LUMINANCE_ALPHA: comps = 2; break;
            default: comps = 1;
        }
        switch (type) {
            case 0x8367: /* UNSIGNED_INT_8_8_8_8_REV */ case 0x8035: /* UNSIGNED_INT_8_8_8_8 */ return 4;
            case GL_UNSIGNED_SHORT: case GL_SHORT: return comps * 2;
            case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: return comps * 4;
            default: return comps;
        }
    }

    // ------------------------------------------------------------------

    public static void parameteri(int target, int pname, int v) {
        Tex t = bound();
        if (t == null) return;
        switch (pname) {
            case GL_TEXTURE_MIN_FILTER: t.minFilter = v; break;
            case GL_TEXTURE_MAG_FILTER: t.magFilter = v; break;
            case GL_TEXTURE_WRAP_S: t.wrapS = v; break;
            case GL_TEXTURE_WRAP_T: t.wrapT = v; break;
            case 0x813D /* GL_TEXTURE_MAX_LEVEL */: t.maxLevel = v; break;
            case 0x813A /* GL_TEXTURE_MIN_LOD */: t.minLod = v; break;
            case 0x813B /* GL_TEXTURE_MAX_LOD */: t.maxLod = v; break;
            case 0x84FE /* GL_TEXTURE_MAX_ANISOTROPY_EXT */: t.aniso = v; break;
            default: return;
        }
        t.paramsDirty = true;
        pushParams(t);
    }

    public static void parameterf(int target, int pname, float v) {
        Tex t = bound();
        if (t == null) return;
        switch (pname) {
            case 0x813A: t.minLod = v; break;
            case 0x813B: t.maxLod = v; break;
            case 0x84FE: t.aniso = v; break;
            case 0x8501 /* GL_TEXTURE_LOD_BIAS */: return;
            default: parameteri(target, pname, (int) v); return;
        }
        t.paramsDirty = true;
        pushParams(t);
    }

    private static void pushParams(Tex t) {
        if (!t.paramsDirty) return;
        t.paramsDirty = false;
        Native.texParams(t.id, t.minFilter, t.magFilter, t.wrapS, t.wrapT, t.maxLevel, t.minLod, t.maxLod, t.aniso);
    }

    public static int getLevelParameteri(int target, int level, int pname) {
        if (target == 0x8064) {
            if (pname == GL_TEXTURE_WIDTH) return proxyW;
            if (pname == GL_TEXTURE_HEIGHT) return proxyH;
            return 0;
        }
        Tex t = bound();
        if (t == null || level < 0 || level >= 16) return 0;
        switch (pname) {
            case GL_TEXTURE_WIDTH: return t.w[level];
            case GL_TEXTURE_HEIGHT: return t.h[level];
            case GL_TEXTURE_INTERNAL_FORMAT: return t.internalFormat;
            default: return 0;
        }
    }

    public static int getParameteri(int pname) {
        Tex t = bound();
        if (t == null) return 0;
        switch (pname) {
            case GL_TEXTURE_MIN_FILTER: return t.minFilter;
            case GL_TEXTURE_MAG_FILTER: return t.magFilter;
            case GL_TEXTURE_WRAP_S: return t.wrapS;
            case GL_TEXTURE_WRAP_T: return t.wrapT;
            case 0x813D: return t.maxLevel;
            default: return 0;
        }
    }

    public static void getTexImage(int level, int format, int type, Buffer out) {
        Tex t = bound();
        if (t == null || out == null) return;
        metal189.engine.Engine.flushForReadback();
        Native.texGetImage(t.id, level, format, type, Mem.positionAddress(out), (int) Mem.remainingBytes(out));
    }
}
