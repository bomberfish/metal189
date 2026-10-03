package metal189.engine;

import java.lang.reflect.Field;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import sun.misc.Unsafe;

/** Raw native memory access. All addresses are plain longs. */
@SuppressWarnings("restriction")
public final class Mem {
    public static final Unsafe U;
    private static final long ADDRESS_OFFSET;
    private static final long CAPACITY_OFFSET;
    private static final Class<?> DIRECT_BB;

    static {
        try {
            Field f = Unsafe.class.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            U = (Unsafe) f.get(null);
            ADDRESS_OFFSET = U.objectFieldOffset(Buffer.class.getDeclaredField("address"));
            CAPACITY_OFFSET = U.objectFieldOffset(Buffer.class.getDeclaredField("capacity"));
            DIRECT_BB = ByteBuffer.allocateDirect(1).getClass();
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private Mem() {}

    /** Address of element 0 of a direct buffer (ignores position). */
    public static long address(Buffer b) {
        return U.getLong(b, ADDRESS_OFFSET);
    }

    /** Address of the buffer's current position, in bytes. */
    public static long positionAddress(Buffer b) {
        int shift = elementShift(b);
        return address(b) + ((long) b.position() << shift);
    }

    public static int elementShift(Buffer b) {
        if (b instanceof ByteBuffer) return 0;
        if (b instanceof java.nio.IntBuffer || b instanceof java.nio.FloatBuffer) return 2;
        if (b instanceof java.nio.ShortBuffer || b instanceof java.nio.CharBuffer) return 1;
        return 3; // long / double
    }

    /** Remaining bytes between position and limit. */
    public static long remainingBytes(Buffer b) {
        return (long) b.remaining() << elementShift(b);
    }

    public static long malloc(long size) {
        long a = U.allocateMemory(size);
        U.setMemory(a, size, (byte) 0);
        return a;
    }

    public static void free(long a) {
        if (a != 0) U.freeMemory(a);
    }

    /** Wraps native memory in a ByteBuffer without copying (no cleaner). */
    public static ByteBuffer wrap(long address, int capacity) {
        try {
            ByteBuffer bb = (ByteBuffer) U.allocateInstance(DIRECT_BB);
            U.putLong(bb, ADDRESS_OFFSET, address);
            U.putInt(bb, CAPACITY_OFFSET, capacity);
            bb.clear();
            return bb.order(ByteOrder.nativeOrder());
        } catch (InstantiationException e) {
            throw new RuntimeException(e);
        }
    }

    public static void copy(long src, long dst, long bytes) {
        U.copyMemory(src, dst, bytes);
    }

    public static void putInt(long a, int v) { U.putInt(a, v); }
    public static void putFloat(long a, float v) { U.putFloat(a, v); }
    public static int getInt(long a) { return U.getInt(a); }
    public static float getFloat(long a) { return U.getFloat(a); }
    public static long getLong(long a) { return U.getLong(a); }
}
