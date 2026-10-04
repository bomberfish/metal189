package metal189.terrain;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.util.List;
import metal189.engine.Mem;
import metal189.engine.Native;
import net.minecraft.client.renderer.chunk.RenderChunk;
import net.minecraft.util.BlockPos;

/**
 * A snapshot of RenderGlobal.renderInfos (the visible sections, nearest first), taken when
 * vanilla replaces that list: vanilla rebuilds it only when the camera moves or chunks
 * change, so everything derived from it is made once per change instead of once per frame
 * and layer. The engine gets the section ids and draws each layer from them.
 */
public final class Visible {
    private Visible() {}

    /** RenderGlobal.ContainerLocalRenderInformation.renderChunk (package-private). */
    static final MethodHandle RENDER_CHUNK;

    static {
        MethodHandle h = null;
        try {
            Class<?> c = Class.forName("net.minecraft.client.renderer.RenderGlobal$ContainerLocalRenderInformation");
            for (Field f : c.getDeclaredFields()) {
                if (f.getType() != RenderChunk.class) continue;
                f.setAccessible(true);
                h = MethodHandles.lookup().unreflectGetter(f).asType(MethodType.methodType(RenderChunk.class, Object.class));
            }
        } catch (Exception e) {
            Native.LOG.error("metal189: render info layout not recognised", e);
        }
        RENDER_CHUNK = h;
    }

    private static List<?> list;
    /** Changes with every new snapshot. */
    public static int generation;
    public static int count;
    public static Object[] infos = new Object[0];
    public static RenderChunk[] chunks = new RenderChunk[0];
    /** Section coordinates (blocks / 16), packed by {@link #key}. */
    public static long[] keys = new long[0];
    /** The sections' engine ids. */
    public static int[] ids = new int[0];

    // which sections (by engine id) hold tile entities, kept as they compile (any thread);
    // 0 unknown, 1 none, 2 some
    private static volatile byte[] tileById = new byte[4096];

    static void tileEntities(int id, boolean some) {
        byte[] t = tileById;
        if (id > 0 && id < t.length) t[id] = (byte) (some ? 2 : 1);
    }

    /** Whether visible entry i's section holds tile entities. */
    public static boolean hasTileEntities(int i) {
        int id = ids[i];
        byte[] t = tileById;
        if (id >= t.length) tileById = t = java.util.Arrays.copyOf(t, Math.max(id + 1, t.length * 2));
        byte v = t[id];
        if (v == 0) {
            v = (byte) (chunks[i].getCompiledChunk().getTileEntities().isEmpty() ? 1 : 2);   // compiled before it had an id
            t[id] = v;
        }
        return v == 2;
    }
    private static long idBuffer;
    private static int idCapacity;

    public static long key(int sx, int sy, int sz) {
        return ((long) (sx & 0x3FFFFF) << 42 | (long) (sz & 0x3FFFFF) << 20 | (long) (sy & 0xFFFFF)) + 1;
    }

    /** Takes a new snapshot if vanilla replaced the list (client thread; vanilla's own search). */
    public static void update(List<?> renderInfos) {
        if (renderInfos == list || RENDER_CHUNK == null) return;
        int n = renderInfos.size();
        RenderChunk[] rcs = new RenderChunk[n];
        try {
            for (int i = 0; i < n; i++) rcs[i] = (RenderChunk) RENDER_CHUNK.invokeExact((Object) renderInfos.get(i));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        Object[] in = renderInfos.toArray();
        long[] ks = new long[n];
        int[] ids = new int[n];
        for (int i = 0; i < n; i++) {
            BlockPos p = rcs[i].getPosition();
            ks[i] = key(p.getX() >> 4, p.getY() >> 4, p.getZ() >> 4);
            ids[i] = Terrain.idFor(rcs[i]);
        }
        publish(renderInfos, in, rcs, ks, ids, n);
    }

    /** A new visible list: renderInfos, and per entry its info object, section, key and engine id. */
    public static void publish(List<?> renderInfos, Object[] in, RenderChunk[] rcs, long[] ks, int[] ids, int n) {
        list = renderInfos;
        generation++;
        if (infos.length < n) {
            int cap = Math.max(n, infos.length * 2);
            infos = new Object[cap];
            chunks = new RenderChunk[cap];
            keys = new long[cap];
            Visible.ids = new int[cap];
        }
        if (idCapacity < n) {
            if (idBuffer != 0) Mem.free(idBuffer);
            idCapacity = Math.max(n, idCapacity * 2);
            idBuffer = Mem.malloc(idCapacity * 4L);
        }
        System.arraycopy(ids, 0, Visible.ids, 0, n);
        System.arraycopy(in, 0, infos, 0, n);
        System.arraycopy(rcs, 0, chunks, 0, n);
        System.arraycopy(ks, 0, keys, 0, n);
        Mem.U.copyMemory(ids, Mem.U.arrayBaseOffset(int[].class), null, idBuffer, n * 4L);
        for (int i = n; i < count; i++) { infos[i] = null; chunks[i] = null; }
        count = n;
        Native.terrainVisible(idBuffer, n);
        Lod.check(chunks, n);
    }
}
