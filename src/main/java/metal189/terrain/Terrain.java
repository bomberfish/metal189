package metal189.terrain;

import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.List;
import metal189.capture.Tess;
import metal189.engine.Cmd;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.engine.Native;
import metal189.gl.Draw;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.GlStateManager;
import net.minecraft.client.renderer.WorldRenderer;
import net.minecraft.client.renderer.chunk.CompiledChunk;
import net.minecraft.client.renderer.chunk.RenderChunk;
import net.minecraft.client.renderer.vertex.DefaultVertexFormats;
import net.minecraft.util.BlockPos;
import net.minecraft.util.EnumWorldBlockLayer;

/**
 * Engine-owned chunk geometry. Vanilla still meshes sections (exact AO,
 * lighting, tinting); the results live in native per-section buffers and are
 * drawn by the engine one command per layer.
 */
public final class Terrain {
    private Terrain() {}

    private static int nextId = 1;
    /** RenderChunk.metal189$id: the engine's section id (0 = none yet). */
    private static final java.lang.invoke.MethodHandle ID_GET, ID_SET;

    static {
        java.lang.invoke.MethodHandle g = null, s = null;
        try {
            java.lang.invoke.MethodHandles.Lookup l = java.lang.invoke.MethodHandles.lookup();
            g = l.findGetter(RenderChunk.class, "metal189$id", int.class);
            s = l.findSetter(RenderChunk.class, "metal189$id", int.class);
        } catch (Exception e) {
            throw new IllegalStateException("metal189: RenderChunk not patched", e);
        }
        ID_GET = g;
        ID_SET = s;
    }

    private static int idOf(RenderChunk rc) {
        try {
            return (int) ID_GET.invokeExact(rc);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }
    private static int blockFormat;
    private static final int MAX_PER_RECORD = 8192;

    static int idFor(RenderChunk rc) {
        int id = idOf(rc);
        if (id == 0) {
            id = nextId++;
            try {
                ID_SET.invokeExact(rc, id);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
        return id;
    }

    /** Head of ChunkRenderDispatcher.uploadChunk: uploads on the client thread, else lets vanilla queue it. */
    public static ListenableFuture<Object> upload(EnumWorldBlockLayer layer, WorldRenderer wr, RenderChunk rc, CompiledChunk cc) {
        if (!Minecraft.getMinecraft().isCallingFromMinecraftThread()) return null;
        // A translucency re-sort with nothing to sort (no saved sort state) still "uploads" its
        // worker's buffer, which holds whatever chunk that worker built last: vanilla never
        // draws it, but the engine keeps every section's data for shadows and ray tracing, so
        // such an upload is dropped and the section keeps its own data (layers that really
        // became empty are cleared by compiled()).
        if (wr.getVertexFormat() == null) return Futures.immediateFuture(null);
        if (layer == EnumWorldBlockLayer.TRANSLUCENT && (cc == null || cc.getState() == null)) return Futures.immediateFuture(null);
        int count = wr.getVertexCount();
        int stride = wr.getVertexFormat().getNextOffset();
        BlockPos pos = rc.getPosition();
        Native.sectionUpload(idFor(rc), layer.ordinal(), Mem.address(wr.getByteBuffer()), count * stride, count,
            pos.getX(), pos.getY(), pos.getZ());
        wr.setTranslation(0.0, 0.0, 0.0);
        return Futures.immediateFuture(null);
    }

    private static final ThreadLocal<int[]> blockStart = new ThreadLocal<int[]>() {
        @Override protected int[] initialValue() { return new int[1]; }
    };

    /** Head of BlockRendererDispatcher.renderBlock. */
    public static void beginBlock(WorldRenderer wr) {
        blockStart.get()[0] = wr.getVertexCount();
    }

    // which blocks of the section being rebuilt on this thread are opaque cubes (coloured block
    // light must not pass solid rock, whose buried faces the vertex data does not show)
    private static final ThreadLocal<long[]> solid = new ThreadLocal<long[]>();
    private static final java.util.concurrent.ConcurrentHashMap<RenderChunk, long[]> solidMasks =
            new java.util.concurrent.ConcurrentHashMap<RenderChunk, long[]>();

    /** Head of RenderChunk.rebuildChunk (chunk worker or client thread). */
    public static void beginRebuild(RenderChunk rc) {
        long[] m = new long[66];   // 64: opaque cubes; [64] != 0: some block gives light; [65] != 0: tinted translucents
        solid.set(m);
        solidMasks.put(rc, m);
        Lod.beginRebuild(rc);
    }

    /** End of RenderChunk.rebuildChunk. */
    public static void endRebuild(RenderChunk rc) {
        Lod.endRebuild();
    }

    /**
     * Before BlockRendererDispatcher.renderBlock returns: stamps the block state
     * id into the unused high bytes of the lightmap shorts of the vertices the
     * block produced (light values never exceed 240). The id survives vanilla's
     * translucent re-sorting because it lives in the vertex itself. Also records
     * opaque cubes, buried ones (no vertices) included.
     */
    public static void endBlock(WorldRenderer wr, net.minecraft.block.state.IBlockState state, BlockPos pos,
                                net.minecraft.world.IBlockAccess world) {
        long[] m = solid.get();
        if (m != null) {
            if (state.getBlock().isOpaqueCube()) {
                int i = ((pos.getY() & 15) << 8) | ((pos.getZ() & 15) << 4) | (pos.getX() & 15);
                m[i >> 6] |= 1L << (i & 63);
            }
            if (state.getBlock().getLightValue() > 0) m[64] = 1;
            // stained glass, ice, slime, portals: what colours shadows (water has its own map)
            if (state.getBlock().getBlockLayer() == EnumWorldBlockLayer.TRANSLUCENT
                    && state.getBlock().getMaterial() != net.minecraft.block.material.Material.water) m[65] = 1;
        }
        int start = blockStart.get()[0];
        int end = wr.getVertexCount();
        if (end <= start || wr.getVertexFormat() != DefaultVertexFormats.BLOCK) return;
        if (state.getBlock() instanceof net.minecraft.block.BlockLeavesBase) {
            end = Lod.cullLeafFaces(wr, start, end, pos, world);
            if (end <= start) return;
        }
        int id = net.minecraft.block.Block.getStateId(state);
        byte lo = (byte) id, hi = (byte) (id >>> 8);
        long base = Mem.address(wr.getByteBuffer());
        for (int v = start; v < end; v++) {
            long a = base + v * 28L + 24;
            Mem.U.putByte(a + 1, lo);
            Mem.U.putByte(a + 3, hi);
        }
    }

    /** Head of RenderChunk.setPosition: the old geometry no longer describes the world there. */
    public static void moved(RenderChunk rc) {
        int id = idOf(rc);
        Search.compiledChanged(id, CompiledChunk.DUMMY);   // setPosition resets the build
        if (id != 0) Native.sectionDelete(id);
    }

    private static final java.util.concurrent.ConcurrentLinkedQueue<Object[]> pendingCompiled = new java.util.concurrent.ConcurrentLinkedQueue<Object[]>();
    private static final EnumWorldBlockLayer[] LAYERS = EnumWorldBlockLayer.values();

    /**
     * Head of RenderChunk.setCompiledChunk: vanilla only uploads non-empty layers, so
     * layers that became empty are cleared here (the engine's shadow and ray tracing
     * passes read every resident section, not only the visible ones). May run on a
     * chunk worker thread, in which case the clear is applied on the client thread.
     */
    public static void compiled(RenderChunk rc, CompiledChunk cc) {
        if (cc == null) return;
        Search.compiledChanged(idOf(rc), cc);   // at once, as vanilla's search would see it
        if (!Minecraft.getMinecraft().isCallingFromMinecraftThread()) {
            pendingCompiled.add(new Object[] {rc, cc});
            return;
        }
        int id = idOf(rc);
        if (id == 0) return;
        compiledGeneration++;
        BlockPos pos = rc.getPosition();
        for (EnumWorldBlockLayer layer : LAYERS) {
            if (cc.isLayerEmpty(layer)) Native.sectionUpload(id, layer.ordinal(), 0L, 0, 0, pos.getX(), pos.getY(), pos.getZ());
        }
        long[] m = solidMasks.remove(rc);
        if (m != null) {
            long a = Mem.malloc(512);
            for (int i = 0; i < 64; i++) Mem.U.putLong(a + i * 8L, m[i]);
            Native.sectionSolid(id, a, m[64] != 0, m[65] != 0);
            Mem.free(a);
        }
    }

    /** Applies compiled-chunk notifications queued by worker threads (client thread). */
    public static void drainPending() {
        Object[] e;
        while ((e = pendingCompiled.poll()) != null) {
            RenderChunk rc = (RenderChunk) e[0];
            if (rc.getCompiledChunk() == e[1]) compiled(rc, (CompiledChunk) e[1]);
        }
    }

    /** Head of RenderChunk.deleteGlResources. */
    public static void delete(RenderChunk rc) {
        solidMasks.remove(rc);
        int id = idOf(rc);
        Search.compiledChanged(id, CompiledChunk.DUMMY);
        if (id != 0) Native.sectionDelete(id);
    }

    /** Changes whenever some section's compiled chunk does (tile entity lists may change). */
    public static int compiledGeneration;

    /**
     * Replaces both renderInfos.size() reads of RenderGlobal.renderBlockLayer's section loop:
     * vanilla's loop then adds nothing to the container, and the layer is drawn from the
     * visible-section snapshot instead (Visible, TerrainContainer.renderChunkLayer).
     */
    @SuppressWarnings("rawtypes")
    public static int layerLoopSize(List renderInfos) {
        Visible.update(renderInfos);
        return 0;
    }

    /** One TERRAIN record drawing the visible sections that have this layer (the engine filters and offsets them). */
    static void renderVisible(EnumWorldBlockLayer layer, double vx, double vy, double vz) {
        Lod.camera(vx, vy, vz);
        if (Visible.count == 0) return;
        if (blockFormat == 0) blockFormat = Tess.formatId(DefaultVertexFormats.BLOCK);
        Draw.flush();
        long p = Engine.cmd.begin(Cmd.TERRAIN, 1 + 3 + 6);   // header, layer, format, -1, camera (3 doubles)
        Mem.putInt(p, layer.ordinal());
        Mem.putInt(p + 4, blockFormat);
        Mem.putInt(p + 8, -1);
        Mem.U.putDouble(p + 12, vx);
        Mem.U.putDouble(p + 20, vy);
        Mem.U.putDouble(p + 28, vz);
        GlStateManager.resetColor();
    }

    /**
     * Replaces ChunkRenderContainer.renderChunkLayer: one TERRAIN record with
     * the visible sections in vanilla order and their camera-relative offsets
     * (computed exactly like ChunkRenderContainer.preRenderChunk).
     */
    static void renderLayer(List<RenderChunk> chunks, EnumWorldBlockLayer layer, double vx, double vy, double vz) {
        int total = chunks.size();
        if (total > 0) {
            if (blockFormat == 0) blockFormat = Tess.formatId(DefaultVertexFormats.BLOCK);
            Draw.flush();
        }
        // Records are limited to 65535 words, so large view distances use several.
        for (int start = 0; start < total; start += MAX_PER_RECORD) {
            int n = Math.min(MAX_PER_RECORD, total - start);
            long p = Engine.cmd.begin(Cmd.TERRAIN, 4 + n * 4);
            Mem.putInt(p, layer.ordinal());
            Mem.putInt(p + 4, blockFormat);
            Mem.putInt(p + 8, n);
            long q = p + 12;
            for (int i = start; i < start + n; i++) {
                RenderChunk rc = chunks.get(i);
                BlockPos pos = rc.getPosition();
                Mem.putInt(q, idFor(rc));
                Mem.putFloat(q + 4, (float) ((double) pos.getX() - vx));
                Mem.putFloat(q + 8, (float) ((double) pos.getY() - vy));
                Mem.putFloat(q + 12, (float) ((double) pos.getZ() - vz));
                q += 16;
            }
        }
        GlStateManager.resetColor();
        chunks.clear();
    }
}
