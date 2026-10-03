package metal189.shim;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import metal189.gl.Buffers;

public final class GL15 {
    private GL15() {}
    public static int glGenBuffers() { return Buffers.gen(); }
    public static void glGenBuffers(IntBuffer out) { for (int i = out.position(); i < out.limit(); i++) out.put(i, Buffers.gen()); }
    public static void glDeleteBuffers(int b) { Buffers.delete(b); }
    public static void glBindBuffer(int target, int b) { Buffers.bind(target, b); }
    public static void glBufferData(int target, ByteBuffer d, int usage) { Buffers.data(target, d, usage); }
    public static void glBufferData(int target, FloatBuffer d, int usage) { Buffers.data(target, d, usage); }
    public static void glBufferData(int target, IntBuffer d, int usage) { Buffers.data(target, d, usage); }
    public static void glBufferData(int target, long size, int usage) { Buffers.data(target, size, usage); }
    // occlusion queries: always report "visible"
    public static int glGenQueries() { return 1; }
    public static void glBeginQuery(int t, int id) {}
    public static void glEndQuery(int t) {}
    public static int glGetQueryObjecti(int id, int p) { return 1; }
    public static void glDeleteQueries(int id) {}
}
