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
import metal189.terrain.Visible;
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

    private static final List<Object> entityInfos = new ArrayList<Object>();
    private static final List<Object> tileInfos = new ArrayList<Object>();
    private static int tileGeneration = -1, tileCompiled = -1;
    // section keys holding entities: open addressing, 0 = empty slot (Visible.key is never 0)
    private static long[] keys = new long[256];

    private static int slot(long k, int mask) {
        long h = k * 0x9E3779B97F4A7C15L;
        return (int) (h >>> 40) & mask;
    }

    private static void findEntities() {
        entityInfos.clear();
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
            long k = Visible.key(e.chunkCoordX, e.chunkCoordY, e.chunkCoordZ);
            int j = slot(k, mask);
            while (keys[j] != 0 && keys[j] != k) j = (j + 1) & mask;
            if (keys[j] == 0) { keys[j] = k; n++; }
        }
        if (n == 0) return;
        long[] vk = Visible.keys;
        Object[] vi = Visible.infos;
        for (int i = 0, c = Visible.count; i < c; i++) {
            long k = vk[i];
            int j = slot(k, mask);
            while (keys[j] != 0) {
                if (keys[j] == k) { entityInfos.add(vi[i]); break; }
                j = (j + 1) & mask;
            }
        }
    }

    private static void findTileEntities() {
        if (tileGeneration == Visible.generation && tileCompiled == metal189.terrain.Terrain.compiledGeneration) return;
        tileGeneration = Visible.generation;
        tileCompiled = metal189.terrain.Terrain.compiledGeneration;
        tileInfos.clear();
        Object[] vi = Visible.infos;
        for (int i = 0, c = Visible.count; i < c; i++)
            if (Visible.hasTileEntities(i)) tileInfos.add(vi[i]);
    }

    /** The visible sections that may hold entities (replaces renderInfos.iterator()). */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public static Iterator entityInfos(List infos) {
        metal189.terrain.Visible.update(infos);
        if (MinecraftForgeClient.getRenderPass() == 0 || lastPass1Generation != Visible.generation) findEntities();
        lastPass1Generation = Visible.generation;
        return entityInfos.iterator();
    }

    private static int lastPass1Generation = -1;

    /** The visible sections with tile entities (replaces renderInfos.iterator()). */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public static Iterator tileEntityInfos(List infos) {
        metal189.terrain.Visible.update(infos);
        findTileEntities();
        return tileInfos.iterator();
    }

    /** setTileEntities.iterator(), without scanning an empty set's buckets. */
    @SuppressWarnings("rawtypes")
    public static Iterator setIterator(Set set) {
        return set.isEmpty() ? Collections.emptyIterator() : set.iterator();
    }
}
