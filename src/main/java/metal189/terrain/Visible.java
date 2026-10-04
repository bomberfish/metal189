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
        publish(renderInfos, rcs, n);
    }

    /** A new visible list: renderInfos and its sections (in order). */
    public static void publish(List<?> renderInfos, RenderChunk[] rcs, int n) {
        list = renderInfos;
        generation++;
        if (infos.length < n) {
            int cap = Math.max(n, infos.length * 2);
            infos = new Object[cap];
            chunks = new RenderChunk[cap];
            keys = new long[cap];
        }
        if (idCapacity < n) {
            if (idBuffer != 0) Mem.free(idBuffer);
            idCapacity = Math.max(n, idCapacity * 2);
            idBuffer = Mem.malloc(idCapacity * 4L);
        }
        for (int i = 0; i < n; i++) {
            RenderChunk rc = rcs[i];
            infos[i] = renderInfos.get(i);
            chunks[i] = rc;
            BlockPos p = rc.getPosition();
            keys[i] = key(p.getX() >> 4, p.getY() >> 4, p.getZ() >> 4);
            Mem.putInt(idBuffer + i * 4L, Terrain.idFor(rc));
        }
        for (int i = n; i < count; i++) { infos[i] = null; chunks[i] = null; }
        count = n;
        Native.terrainVisible(idBuffer, n);
        Lod.check(chunks, n);
    }
}
