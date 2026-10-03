package metal189.shim;

import java.nio.ByteBuffer;
import metal189.gl.Buffers;

public final class ARBBufferObject {
    private ARBBufferObject() {}
    public static int glGenBuffersARB() { return Buffers.gen(); }
    public static void glDeleteBuffersARB(int b) { Buffers.delete(b); }
    public static void glBindBufferARB(int target, int b) { Buffers.bind(target, b); }
    public static void glBufferDataARB(int target, ByteBuffer d, int usage) { Buffers.data(target, d, usage); }
}
