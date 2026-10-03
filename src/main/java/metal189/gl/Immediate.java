package metal189.gl;

import static org.lwjgl.opengl.GL11.*;

import metal189.engine.Mem;

/**
 * glBegin/glEnd. Vertices are captured with the current attributes in a fixed
 * full-precision layout: pos 3f, tex0 2f, colour 4f, normal 3f, tex1 2f (56 bytes).
 */
public final class Immediate {
    private Immediate() {}

    static final int STRIDE = 56;
    private static long buf = Mem.malloc(STRIDE * 4096L);
    private static int cap = 4096;
    private static int count;
    private static int mode = -1;
    private static int format;

    static int format() {
        if (format == 0) {
            int[] a = {
                Formats.POS, GL_FLOAT, 3, 0, 0,
                Formats.TEX0, GL_FLOAT, 2, 12, 0,
                Formats.COLOR, GL_FLOAT, 4, 20, 0,
                Formats.NORMAL, GL_FLOAT, 3, 36, 0,
                Formats.TEX1, GL_FLOAT, 2, 48, 0,
            };
            format = Formats.register(STRIDE, a, 5);
        }
        return format;
    }

    public static boolean active() { return mode >= 0; }

    public static void begin(int m) {
        mode = m;
        count = 0;
    }

    public static void end() {
        if (mode < 0) return;
        int m = mode;
        mode = -1;
        if (count > 0) Draw.arrays(m, format(), buf, count, count * STRIDE);
        count = 0;
    }

    public static void vertex(float x, float y, float z) {
        if (count == cap) {
            long nb = Mem.malloc((long) STRIDE * cap * 2);
            Mem.copy(buf, nb, (long) STRIDE * cap);
            Mem.free(buf);
            buf = nb;
            cap *= 2;
        }
        long p = buf + (long) count * STRIDE;
        Mem.putFloat(p, x);
        Mem.putFloat(p + 4, y);
        Mem.putFloat(p + 8, z);
        float[] t0 = GL.texCoord[0];
        Mem.putFloat(p + 12, t0[0]);
        Mem.putFloat(p + 16, t0[1]);
        Mem.putFloat(p + 20, GL.colR);
        Mem.putFloat(p + 24, GL.colG);
        Mem.putFloat(p + 28, GL.colB);
        Mem.putFloat(p + 32, GL.colA);
        Mem.putFloat(p + 36, GL.nrmX);
        Mem.putFloat(p + 40, GL.nrmY);
        Mem.putFloat(p + 44, GL.nrmZ);
        float[] t1 = GL.texCoord[1];
        Mem.putFloat(p + 48, t1[0]);
        Mem.putFloat(p + 52, t1[1]);
        count++;
    }

    // ---- helpers for gathering client arrays ----
    static float read(long a, int type, int i) {
        switch (type) {
            case GL_FLOAT: return Mem.getFloat(a + i * 4L);
            case GL_DOUBLE: return (float) Mem.U.getDouble(a + i * 8L);
            case GL_SHORT: return Mem.U.getShort(a + i * 2L);
            case GL_UNSIGNED_SHORT: return Mem.U.getShort(a + i * 2L) & 0xFFFF;
            case GL_BYTE: return Mem.U.getByte(a + i);
            case GL_UNSIGNED_BYTE: return Mem.U.getByte(a + i) & 0xFF;
            case GL_INT: return Mem.getInt(a + i * 4L);
            default: return 0;
        }
    }

    static void vertexFromMemory(long a, int size, int type) {
        vertex(read(a, type, 0), size > 1 ? read(a, type, 1) : 0, size > 2 ? read(a, type, 2) : 0);
    }

    static void colorFromMemory(long a, int size, int type) {
        float s = type == GL_UNSIGNED_BYTE ? 1f / 255f : type == GL_BYTE ? 1f / 127f : 1f;
        GL.colR = read(a, type, 0) * s;
        GL.colG = read(a, type, 1) * s;
        GL.colB = read(a, type, 2) * s;
        GL.colA = size > 3 ? read(a, type, 3) * s : 1f;
    }

    static void texFromMemory(int unit, long a, int size, int type) {
        float[] t = GL.texCoord[unit];
        t[0] = read(a, type, 0);
        t[1] = size > 1 ? read(a, type, 1) : 0;
    }

    static void normalFromMemory(long a, int type) {
        float s = type == GL_BYTE ? 1f / 127f : 1f;
        GL.nrmX = read(a, type, 0) * s;
        GL.nrmY = read(a, type, 1) * s;
        GL.nrmZ = read(a, type, 2) * s;
    }
}
