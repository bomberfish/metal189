package metal189.gl;

import static org.lwjgl.opengl.GL11.*;

import java.nio.Buffer;
import metal189.engine.Mem;

/** Client vertex arrays, glDrawArrays and immediate mode (glBegin/glEnd). */
public final class Arrays {
    private Arrays() {}

    static final class Ptr {
        boolean enabled;
        int size = 4, type = GL_FLOAT, stride;
        long addr;      // client memory (when vbo == 0)
        int vbo;
        long offset;    // byte offset into vbo
    }

    static final Ptr vertex = new Ptr(), color = new Ptr(), normal = new Ptr();
    static final Ptr[] tex = new Ptr[GL.UNITS];
    public static int arrayBuffer; // GL_ARRAY_BUFFER binding

    static {
        for (int i = 0; i < tex.length; i++) tex[i] = new Ptr();
        normal.size = 3;
    }

    private static Ptr forState(int array) {
        switch (array) {
            case GL_VERTEX_ARRAY: return vertex;
            case GL_COLOR_ARRAY: return color;
            case GL_NORMAL_ARRAY: return normal;
            case GL_TEXTURE_COORD_ARRAY: return tex[GL.clientActiveUnit];
            default: return null;
        }
    }

    public static void enableClientState(int array, boolean on) {
        Ptr p = forState(array);
        if (p != null) p.enabled = on;
    }

    static void set(Ptr p, int size, int type, int stride, Buffer data) {
        p.size = size; p.type = type; p.stride = stride; p.vbo = 0;
        p.addr = data == null ? 0 : Mem.positionAddress(data);
    }

    static void set(Ptr p, int size, int type, int stride, long offset) {
        p.size = size; p.type = type; p.stride = stride; p.vbo = arrayBuffer; p.offset = offset;
        if (arrayBuffer == 0) p.addr = offset;
    }

    public static void vertexPointer(int size, int type, int stride, Buffer b) { set(vertex, size, type, stride, b); }
    public static void vertexPointer(int size, int type, int stride, long off) { set(vertex, size, type, stride, off); }
    public static void colorPointer(int size, int type, int stride, Buffer b) { set(color, size, type, stride, b); }
    public static void colorPointer(int size, int type, int stride, long off) { set(color, size, type, stride, off); }
    public static void texCoordPointer(int size, int type, int stride, Buffer b) { set(tex[GL.clientActiveUnit], size, type, stride, b); }
    public static void texCoordPointer(int size, int type, int stride, long off) { set(tex[GL.clientActiveUnit], size, type, stride, off); }
    public static void normalPointer(int type, int stride, Buffer b) { set(normal, 3, type, stride, b); }
    public static void normalPointer(int type, int stride, long off) { set(normal, 3, type, stride, off); }

    static int typeSize(int type) {
        switch (type) {
            case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
            case GL_SHORT: case GL_UNSIGNED_SHORT: return 2;
            case GL_DOUBLE: return 8;
            default: return 4;
        }
    }

    private static int stride(Ptr p) { return p.stride != 0 ? p.stride : p.size * typeSize(p.type); }

    // scratch for the attribute descriptor passed to Formats.register
    private static final int[] attrs = new int[5 * 6];

    /** glDrawArrays over whatever arrays are enabled. */
    public static void drawArrays(int mode, int first, int count) {
        if (!vertex.enabled || count <= 0) return;
        int vstride = stride(vertex);
        boolean fromVbo = vertex.vbo != 0;
        long base = fromVbo ? vertex.offset : vertex.addr;
        // Find the lowest attribute address so offsets are non-negative.
        Ptr[] enabled = new Ptr[6];
        int[] usage = new int[6];
        int n = 0;
        enabled[n] = vertex; usage[n++] = Formats.POS;
        if (color.enabled) { enabled[n] = color; usage[n++] = Formats.COLOR; }
        if (tex[0].enabled) { enabled[n] = tex[0]; usage[n++] = Formats.TEX0; }
        if (tex[1].enabled) { enabled[n] = tex[1]; usage[n++] = Formats.TEX1; }
        if (normal.enabled) { enabled[n] = normal; usage[n++] = Formats.NORMAL; }
        long min = base;
        boolean interleaved = true;
        for (int i = 0; i < n; i++) {
            Ptr p = enabled[i];
            long a = fromVbo ? p.offset : p.addr;
            if ((p.vbo != 0) != fromVbo || (fromVbo && p.vbo != vertex.vbo) || stride(p) != vstride) interleaved = false;
            if (a < min) min = a;
        }
        if (interleaved) {
            for (int i = 0; i < n; i++) {
                Ptr p = enabled[i];
                long a = fromVbo ? p.offset : p.addr;
                if (a - min >= vstride) interleaved = false;
            }
        }
        if (!interleaved) {
            drawGathered(mode, first, count, enabled, usage, n);
            return;
        }
        for (int i = 0; i < n; i++) {
            Ptr p = enabled[i];
            long a = fromVbo ? p.offset : p.addr;
            int k = i * 5;
            attrs[k] = usage[i];
            attrs[k + 1] = p.type;
            attrs[k + 2] = p.size;
            attrs[k + 3] = (int) (a - min);
            attrs[k + 4] = normalized(usage[i], p.type) ? 1 : 0;
        }
        int fmt = Formats.register(vstride, attrs, n);
        if (fromVbo) {
            int mesh = Buffers.meshFor(vertex.vbo);
            if (mesh != 0) Draw.mesh(mode, fmt, mesh, (int) (min + (long) first * vstride), count);
        } else {
            Draw.arrays(mode, fmt, min + (long) first * vstride, count, count * vstride);
        }
    }

    static boolean normalized(int usage, int type) {
        if (type == GL_FLOAT || type == GL_DOUBLE) return false;
        return usage == Formats.COLOR || usage == Formats.NORMAL;
    }

    /** Non-interleaved client arrays: repack into an immediate-format buffer. */
    private static void drawGathered(int mode, int first, int count, Ptr[] enabled, int[] usage, int n) {
        Immediate.begin(mode);
        for (int v = first; v < first + count; v++) {
            for (int i = 0; i < n; i++) {
                Ptr p = enabled[i];
                if (p.vbo != 0) continue; // mixed VBO/client data is not supported
                long a = p.addr + (long) v * stride(p);
                switch (usage[i]) {
                    case Formats.COLOR: Immediate.colorFromMemory(a, p.size, p.type); break;
                    case Formats.TEX0: Immediate.texFromMemory(0, a, p.size, p.type); break;
                    case Formats.TEX1: Immediate.texFromMemory(1, a, p.size, p.type); break;
                    case Formats.NORMAL: Immediate.normalFromMemory(a, p.type); break;
                    default: break;
                }
            }
            long a = vertex.addr + (long) v * stride(vertex);
            Immediate.vertexFromMemory(a, vertex.size, vertex.type);
        }
        Immediate.end();
    }
}
