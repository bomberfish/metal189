package metal189.gl;

import java.util.ArrayList;
import java.util.HashMap;
import metal189.engine.Mem;
import metal189.engine.Native;

/**
 * Display lists. While compiling, geometry is collected into one buffer that
 * becomes a single static native mesh; matrix and colour operations are
 * recorded and replayed in order on glCallList, so GL semantics are kept.
 */
public final class Lists {
    private Lists() {}

    static final int OP_DRAW = 0, OP_PUSH = 1, OP_POP = 2, OP_MULT = 3, OP_TRANSLATE = 4, OP_SCALE = 5,
            OP_ROTATE = 6, OP_COLOR = 7, OP_CALL = 8, OP_NORMAL = 9;

    public static final class DisplayList {
        final int id;
        int mesh;                       // native mesh id (0 = no geometry)
        final ArrayList<float[]> ops = new ArrayList<float[]>();
        // compile-time geometry staging
        long data;
        int size, cap;

        DisplayList(int id) { this.id = id; }

        void addDraw(int prim, int format, long src, int vertexCount, int bytes) {
            // Each sub-draw starts 16-byte aligned so it can be addressed by vertex index * stride.
            int start = (size + 15) & ~15;
            ensure(start + bytes);
            Mem.copy(src, data + start, bytes);
            size = start + bytes;
            ops.add(new float[] {OP_DRAW, prim, format, Float.intBitsToFloat(start), vertexCount});
        }

        void ensure(int need) {
            if (need <= cap) return;
            int ncap = Math.max(need, Math.max(4096, cap * 2));
            long nd = Mem.malloc(ncap);
            if (data != 0) { Mem.copy(data, nd, size); Mem.free(data); }
            data = nd;
            cap = ncap;
        }
    }

    private static final HashMap<Integer, DisplayList> lists = new HashMap<Integer, DisplayList>();
    private static int nextId = 1;
    public static DisplayList compiling;

    public static int gen(int range) {
        int first = nextId;
        nextId += Math.max(1, range);
        return first;
    }

    public static void delete(int first, int range) {
        for (int i = first; i < first + range; i++) {
            DisplayList l = lists.remove(i);
            if (l != null && l.mesh != 0) Native.meshDelete(l.mesh);
        }
    }

    public static boolean isList(int id) { return lists.containsKey(id); }

    public static void newList(int id, int mode) {
        DisplayList old = lists.remove(id);
        if (old != null && old.mesh != 0) Native.meshDelete(old.mesh);
        compiling = new DisplayList(id);
    }

    public static void endList() {
        DisplayList l = compiling;
        if (l == null) return;
        compiling = null;
        if (l.size > 0) l.mesh = Native.meshCreate(l.data, l.size);
        if (l.data != 0) { Mem.free(l.data); l.data = 0; l.cap = 0; }
        lists.put(l.id, l);
    }

    /** Records an op if compiling; returns true when the caller must not execute it now. */
    static boolean record(float... op) {
        if (compiling == null) return false;
        compiling.ops.add(op);
        return true;
    }

    public static void call(int id) {
        DisplayList l = lists.get(id);
        if (l == null) return;
        if (compiling != null) { compiling.ops.add(new float[] {OP_CALL, Float.intBitsToFloat(id)}); return; }
        MatrixStack mv = GL.modelview;
        for (int i = 0, n = l.ops.size(); i < n; i++) {
            float[] op = l.ops.get(i);
            switch ((int) op[0]) {
                case OP_DRAW: {
                    Draw.mesh((int) op[1], (int) op[2], l.mesh, Float.floatToRawIntBits(op[3]), (int) op[4]);
                    break;
                }
                case OP_PUSH: GL.cur().push(); break;
                case OP_POP: GL.cur().pop(); break;
                case OP_MULT: {
                    float[] m = new float[16];
                    System.arraycopy(op, 1, m, 0, 16);
                    if (op.length > 17) GL.cur().load(m, 0);
                    else GL.cur().mult(m, 0);
                    break;
                }
                case OP_TRANSLATE: GL.cur().translate(op[1], op[2], op[3]); break;
                case OP_SCALE: GL.cur().scale(op[1], op[2], op[3]); break;
                case OP_ROTATE: GL.cur().rotate(op[1], op[2], op[3], op[4]); break;
                case OP_COLOR: GL.color(op[1], op[2], op[3], op[4]); break;
                case OP_NORMAL: GL.normal(op[1], op[2], op[3]); break;
                case OP_CALL: call(Float.floatToRawIntBits(op[1])); break;
                default: break;
            }
        }
        if (mv != GL.modelview) throw new IllegalStateException();
    }
}
