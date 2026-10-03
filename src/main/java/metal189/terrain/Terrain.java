package metal189.terrain;

import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.IdentityHashMap;
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

    private static final IdentityHashMap<RenderChunk, Integer> ids = new IdentityHashMap<RenderChunk, Integer>();
    private static int nextId = 1;
    private static int blockFormat;
    private static final int MAX_PER_RECORD = 8192;

    static int idFor(RenderChunk rc) {
        Integer id = ids.get(rc);
        if (id == null) {
            id = nextId++;
            ids.put(rc, id);
        }
        return id;
    }

    /** Head of ChunkRenderDispatcher.uploadChunk: uploads on the client thread, else lets vanilla queue it. */
    public static ListenableFuture<Object> upload(EnumWorldBlockLayer layer, WorldRenderer wr, RenderChunk rc, CompiledChunk cc) {
        if (!Minecraft.getMinecraft().isCallingFromMinecraftThread()) return null;
        int count = wr.getVertexCount();
        int stride = wr.getVertexFormat().getNextOffset();
        Native.sectionUpload(idFor(rc), layer.ordinal(), Mem.address(wr.getByteBuffer()), count * stride, count);
        wr.setTranslation(0.0, 0.0, 0.0);
        return Futures.immediateFuture(null);
    }

    /** Head of RenderChunk.deleteGlResources. */
    public static void delete(RenderChunk rc) {
        Integer id = ids.remove(rc);
        if (id != null) Native.sectionDelete(id);
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
