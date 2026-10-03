package metal189.engine;

import java.io.IOException;

/** Java side of the native engine: lifetime and per-frame command stream. */
public final class Engine {
    private Engine() {}

    private static boolean initialized;
    private static boolean frameOpen;
    private static final long frameInfo = Mem.malloc(64);
    /** Command stream for the frame being recorded. */
    public static final CmdBuffer cmd = new CmdBuffer(8 << 20);
    /** Per-frame vertex arena (GPU-visible memory owned by native). */
    public static long arenaBase, arenaCapacity, arenaOffset;
    public static int arenaChunk;
    public static long frameIndex;

    public static void initialize() {
        if (initialized) return;
        Native.load();
        byte[] lib;
        try {
            lib = Native.readShaderLibrary();
        } catch (IOException e) {
            throw new RuntimeException("metal189: cannot read shader library", e);
        }
        long a = Mem.malloc(lib.length);
        try {
            for (int i = 0; i < lib.length; i++) Mem.U.putByte(a + i, lib[i]);
            if (Native.init(a, lib.length, 0) != 0) throw new RuntimeException("metal189: native engine init failed");
        } finally {
            Mem.free(a);
        }
        initialized = true;
        Native.LOG.info("Metal device: {}", Native.deviceName());
    }

    public static void beginFrame() {
        if (frameOpen) return;
        Native.beginFrame(frameInfo);
        arenaBase = Mem.getLong(frameInfo);
        arenaCapacity = Mem.getLong(frameInfo + 8);
        frameIndex = Mem.getLong(frameInfo + 16);
        arenaOffset = 0;
        arenaChunk = 0;
        cmd.reset();
        frameOpen = true;
    }

    /** Switches the frame to a fresh arena chunk of at least {@code minBytes}. */
    public static void growArena(int minBytes) {
        Native.arenaGrow(frameInfo, minBytes);
        arenaBase = Mem.getLong(frameInfo);
        arenaCapacity = Mem.getLong(frameInfo + 8);
        arenaChunk = (int) Mem.getLong(frameInfo + 24);
        arenaOffset = 0;
    }

    /**
     * Executes everything recorded so far and waits for the GPU, so a readback
     * sees the same pixels GL would have produced at this point.
     */
    public static void flushForReadback() {
        if (frameOpen && cmd.size() > 0) {
            Native.submitPartial(cmd.base(), cmd.size());
            cmd.reset();
        }
        Native.waitIdle();
    }

    public static void endFrame() {
        if (!frameOpen) beginFrame();
        Native.endFrame(cmd.base(), cmd.size());
        frameOpen = false;
    }

    public static void shutdown() {
        if (!initialized) return;
        Native.waitIdle();
    }
}
