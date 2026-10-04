package metal189.world;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Set;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.chunk.RenderChunk;
import net.minecraft.entity.Entity;
import net.minecraft.util.BlockPos;
import net.minecraft.world.World;
import net.minecraftforge.client.MinecraftForgeClient;

/**
 * Cheaper section loops for RenderGlobal.renderEntities (patched in metal189.core.Patches).
 *
 * Vanilla walks every visible section twice per render pass: once looking up its chunk to
 * read the section's entity list, once reading its compiled tile entities. With thousands
 * of visible sections and few entities that is most of the frame's Java time. Here the
 * walks visit only the sections that have entities (found from the loaded entities) or tile
 * entities, in the same order, so vanilla's loop bodies see exactly what they would have
 * rendered. The lists are made once per frame (render pass 0) and reused by pass 1.
 */
public final class EntityCull {
    private EntityCull() {}

    /** RenderGlobal.ContainerLocalRenderInformation.renderChunk (package-private). */
    private static final MethodHandle RENDER_CHUNK;

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
            metal189.engine.Native.LOG.warn("metal189: render info layout not recognised; entity loops unchanged", e);
        }
        RENDER_CHUNK = h;
    }

    private static final List<Object> entityInfos = new ArrayList<Object>();
    private static final List<Object> tileInfos = new ArrayList<Object>();
    private static List<?> lastList;
    // section keys holding entities: open addressing, 0 = empty slot (keys are stored + 1)
    private static long[] keys = new long[256];

    private static long key(int sx, int sy, int sz) {
        return ((long) (sx & 0x3FFFFF) << 42 | (long) (sz & 0x3FFFFF) << 20 | (long) (sy & 0xFFFFF)) + 1;
    }

    private static int slot(long k, int mask) {
        long h = k * 0x9E3779B97F4A7C15L;
        return (int) (h >>> 40) & mask;
    }

    private static void rebuild(List<?> infos) {
        entityInfos.clear();
        tileInfos.clear();
        World world = Minecraft.getMinecraft().theWorld;
        List<Entity> entities = world != null ? world.loadedEntityList : Collections.<Entity>emptyList();
        int need = Integer.highestOneBit(Math.max(16, entities.size() * 2)) << 1;
        if (keys.length < need || keys.length > need * 8) keys = new long[need];
        else java.util.Arrays.fill(keys, 0L);
        int mask = keys.length - 1;
        int n = 0;
        for (int i = 0, s = entities.size(); i < s; i++) {
            Entity e = entities.get(i);
            if (!e.addedToChunk) continue;
            long k = key(e.chunkCoordX, e.chunkCoordY, e.chunkCoordZ);
            int j = slot(k, mask);
            while (keys[j] != 0 && keys[j] != k) j = (j + 1) & mask;
            if (keys[j] == 0) { keys[j] = k; n++; }
        }
        try {
            for (int i = 0, s = infos.size(); i < s; i++) {
                Object info = infos.get(i);
                RenderChunk rc = (RenderChunk) RENDER_CHUNK.invokeExact(info);
                if (!rc.getCompiledChunk().getTileEntities().isEmpty()) tileInfos.add(info);
                if (n == 0) continue;
                BlockPos p = rc.getPosition();
                long k = key(p.getX() >> 4, p.getY() >> 4, p.getZ() >> 4);
                int j = slot(k, mask);
                while (keys[j] != 0) {
                    if (keys[j] == k) { entityInfos.add(info); break; }
                    j = (j + 1) & mask;
                }
            }
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        lastList = infos;
    }

    /** The visible sections that may hold entities (replaces renderInfos.iterator()). */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public static Iterator entityInfos(List infos) {
        if (RENDER_CHUNK == null) return infos.iterator();
        if (infos != lastList || MinecraftForgeClient.getRenderPass() == 0) rebuild(infos);
        return entityInfos.iterator();
    }

    /** The visible sections with tile entities (replaces renderInfos.iterator()). */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public static Iterator tileEntityInfos(List infos) {
        if (RENDER_CHUNK == null) return infos.iterator();
        if (infos != lastList) rebuild(infos);
        return tileInfos.iterator();
    }

    /** setTileEntities.iterator(), without scanning an empty set's buckets. */
    @SuppressWarnings("rawtypes")
    public static Iterator setIterator(Set set) {
        return set.isEmpty() ? Collections.emptyIterator() : set.iterator();
    }
}
