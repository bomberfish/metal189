package metal189.gl;

import java.nio.Buffer;
import java.util.HashMap;
import metal189.engine.Mem;
import metal189.engine.Native;

/** GL buffer objects (VBOs), stored as native static meshes. */
public final class Buffers {
    private Buffers() {}

    private static final HashMap<Integer, int[]> buffers = new HashMap<Integer, int[]>(); // id -> {mesh, size}
    private static int nextId = 1;

    public static int gen() {
        int id = nextId++;
        buffers.put(id, new int[2]);
        return id;
    }

    public static void delete(int id) {
        int[] b = buffers.remove(id);
        if (b != null && b[0] != 0) Native.meshDelete(b[0]);
        if (Arrays.arrayBuffer == id) Arrays.arrayBuffer = 0;
    }

    public static void bind(int target, int id) {
        if (target == 0x8892 /* GL_ARRAY_BUFFER */) Arrays.arrayBuffer = id;
    }

    public static void data(int target, Buffer data, int usage) {
        if (target != 0x8892) return;
        int[] b = buffers.get(Arrays.arrayBuffer);
        if (b == null) return;
        if (b[0] != 0) { Native.meshDelete(b[0]); b[0] = 0; }
        if (data == null) return;
        int size = (int) Mem.remainingBytes(data);
        if (size > 0) b[0] = Native.meshCreate(Mem.positionAddress(data), size);
        b[1] = size;
    }

    public static void data(int target, long size, int usage) {
        int[] b = buffers.get(Arrays.arrayBuffer);
        if (b == null) return;
        if (b[0] != 0) { Native.meshDelete(b[0]); b[0] = 0; }
        b[1] = (int) size;
    }

    static int meshFor(int id) {
        int[] b = buffers.get(id);
        return b == null ? 0 : b[0];
    }
}
