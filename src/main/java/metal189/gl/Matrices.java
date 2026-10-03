package metal189.gl;

import java.nio.FloatBuffer;
import metal189.engine.Mem;

/** Matrix entry points that must also be recordable into display lists. */
public final class Matrices {
    private Matrices() {}

    public static final int LOAD_IDENTITY = 100, PUSH = Lists.OP_PUSH, POP = Lists.OP_POP, TRANSLATE = Lists.OP_TRANSLATE,
            SCALE = Lists.OP_SCALE, ROTATE = Lists.OP_ROTATE;

    private static final float[] tmp = new float[16];
    private static final FloatBuffer scratch = Mem.wrap(Mem.malloc(64), 64).asFloatBuffer();

    public static FloatBuffer scratch() { scratch.clear(); return scratch; }

    /** @return true if the op was recorded into a display list instead of executed */
    public static boolean record(int op, float... args) {
        if (Lists.compiling == null) return false;
        if (op == LOAD_IDENTITY) {
            // Rare inside lists; executing it at replay keeps semantics.
            float[] r = new float[18];
            r[0] = Lists.OP_MULT;
            for (int i = 0; i < 16; i++) r[1 + i] = (i % 5 == 0) ? 1f : 0f;
            r[17] = 1f; // flag: load rather than multiply
            Lists.compiling.ops.add(r);
            return true;
        }
        float[] r = new float[1 + args.length];
        r[0] = op;
        System.arraycopy(args, 0, r, 1, args.length);
        Lists.compiling.ops.add(r);
        return true;
    }

    public static void mult(FloatBuffer m) {
        int o = m.position();
        for (int i = 0; i < 16; i++) tmp[i] = m.get(o + i);
        if (Lists.compiling != null) {
            float[] r = new float[17];
            r[0] = Lists.OP_MULT;
            System.arraycopy(tmp, 0, r, 1, 16);
            Lists.compiling.ops.add(r);
            return;
        }
        GL.cur().mult(tmp, 0);
    }

    public static void load(FloatBuffer m) {
        int o = m.position();
        for (int i = 0; i < 16; i++) tmp[i] = m.get(o + i);
        GL.cur().load(tmp, 0);
    }
}
