package metal189.terrain;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import metal189.config.Config;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.chunk.RenderChunk;
import net.minecraft.util.BlockPos;

/**
 * Detail by distance for chunk meshes: sections beyond Config.leavesDetailDistance are
 * built with fast (opaque) leaves, nearer ones as the game's setting says (or as smart leaves,
 * Config.smartLeaves).
 *
 * Leaves read their graphics level from fields every block shares; the leaf classes are
 * patched (metal189.core.Patches) to pass those reads through {@link #leaves}, which answers
 * "fast" while this thread builds a far section and the field's own value otherwise. Each
 * RenderChunk remembers how it was built (a field added to it); visible sections that cross
 * the distance are rebuilt, with a margin so a section on the edge does not flip back and forth.
 */
public final class Lod {
    private Lod() {}

    /** While this thread builds a section: [0] past the detail distance, [1] smart leaves. */
    private static final ThreadLocal<boolean[]> FAR = new ThreadLocal<boolean[]>() {
        @Override protected boolean[] initialValue() { return new boolean[2]; }
    };

    // the camera (render position), updated each frame by the terrain pass
    private static volatile double camX, camY, camZ;

    /** RenderChunk.metal189$lod: 0 not built yet, else 1 built near / 2 built far, + 4 with smart leaves, + 8 rebuild queued. */
    private static final MethodHandle GET, SET;

    static {
        MethodHandle g = null, s = null;
        try {
            MethodHandles.Lookup l = MethodHandles.lookup();
            g = l.findGetter(RenderChunk.class, "metal189$lod", int.class);
            s = l.findSetter(RenderChunk.class, "metal189$lod", int.class);
        } catch (Exception e) {
            metal189.engine.Native.LOG.warn("metal189: RenderChunk not patched; leaves stay at the game's detail", e);
        }
        GET = g;
        SET = s;
    }

    /** Patched reads of BlockLeaves.isTransparent / BlockLeavesBase.fancyGraphics. */
    public static boolean leaves(boolean fancy) {
        return fancy && !FAR.get()[0];
    }

    /**
     * The read in BlockLeavesBase.shouldSideBeRendered (faces with a cullface: resource packs'
     * leaf models): false culls the faces between leaves. Smart leaves (like OptiFine's) keep
     * fancy leaves' cut-out look but drop those inner faces, most of a forest's overdraw.
     * Vanilla's model has no cullfaces; cullLeafFaces handles it.
     */
    public static boolean leavesSide(boolean fancy) {
        boolean[] f = FAR.get();
        return fancy && !f[0] && !f[1];
    }

    /** WorldRenderer.vertexCount (private). */
    private static final MethodHandle SET_VERTEX_COUNT;

    static {
        MethodHandle h = null;
        for (String name : new String[] {"vertexCount", "field_178997_d"}) {
            try {
                java.lang.reflect.Field f = net.minecraft.client.renderer.WorldRenderer.class.getDeclaredField(name);
                f.setAccessible(true);
                h = MethodHandles.lookup().unreflectSetter(f);
                break;
            } catch (Exception ignored) {
            }
        }
        SET_VERTEX_COUNT = h;
    }

    private static final net.minecraft.util.EnumFacing[] FACINGS = net.minecraft.util.EnumFacing.values();

    /**
     * Vanilla's leaves model marks no face as culled by its neighbour, so every leaf block
     * meshes all six faces, even against stone or other leaves (in fast mode too). Run after a
     * leaf block is meshed into vertices [start, end): a face on the block's boundary is
     * dropped when the neighbour is an opaque cube (it can only be seen from inside that block;
     * fast leaves count) or, with smart leaves, other leaves. Returns the new end.
     */
    static int cullLeafFaces(net.minecraft.client.renderer.WorldRenderer wr, int start, int end, BlockPos pos,
                             net.minecraft.world.IBlockAccess world) {
        if (SET_VERTEX_COUNT == null || world == null || (end - start) % 4 != 0 || end != wr.getVertexCount()) return end;
        boolean smartNow = FAR.get()[1] && !FAR.get()[0] && Minecraft.getMinecraft().gameSettings.fancyGraphics;
        // which of the six faces to drop (bit per EnumFacing index), decided lazily
        int decided = 0, drop = 0;
        long base = metal189.engine.Mem.address(wr.getByteBuffer());
        float bx = pos.getX() & 15, by = pos.getY() & 15, bz = pos.getZ() & 15;
        int out = start;
        for (int q = start; q < end; q += 4) {
            long a = base + q * 28L;
            int face = boundaryFace(a, bx, by, bz);
            boolean keep = true;
            if (face >= 0) {
                if ((decided & (1 << face)) == 0) {
                    decided |= 1 << face;
                    net.minecraft.block.Block n = world.getBlockState(pos.offset(FACINGS[face])).getBlock();
                    if (n.isOpaqueCube() || (smartNow && n instanceof net.minecraft.block.BlockLeavesBase)) drop |= 1 << face;
                }
                keep = (drop & (1 << face)) == 0;
            }
            if (keep) {
                if (out != q) metal189.engine.Mem.U.copyMemory(a, base + out * 28L, 4 * 28L);
                out += 4;
            }
        }
        if (out != end) {
            try {
                SET_VERTEX_COUNT.invokeExact(wr, out);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
        return out;
    }

    /** The EnumFacing index of the block face a quad lies on (all four corners), or -1. */
    private static int boundaryFace(long a, float bx, float by, float bz) {
        sun.misc.Unsafe u = metal189.engine.Mem.U;
        float x0 = u.getFloat(a), y0 = u.getFloat(a + 4), z0 = u.getFloat(a + 8);
        boolean sx = true, sy = true, sz = true;
        for (int v = 1; v < 4; v++) {
            long p = a + v * 28L;
            sx &= Math.abs(u.getFloat(p) - x0) < 1e-4f;
            sy &= Math.abs(u.getFloat(p + 4) - y0) < 1e-4f;
            sz &= Math.abs(u.getFloat(p + 8) - z0) < 1e-4f;
        }
        final float e = 1e-4f;
        if (sy && Math.abs(y0 - by) < e) return 0;        // DOWN
        if (sy && Math.abs(y0 - by - 1) < e) return 1;    // UP
        if (sz && Math.abs(z0 - bz) < e) return 2;        // NORTH
        if (sz && Math.abs(z0 - bz - 1) < e) return 3;    // SOUTH
        if (sx && Math.abs(x0 - bx) < e) return 4;        // WEST
        if (sx && Math.abs(x0 - bx - 1) < e) return 5;    // EAST
        return -1;
    }

    private static double dist2(RenderChunk rc) {
        BlockPos p = rc.getPosition();
        double dx = p.getX() + 8 - camX, dy = p.getY() + 8 - camY, dz = p.getZ() + 8 - camZ;
        return dx * dx + dy * dy + dz * dz;
    }

    private static double limit() {
        return Config.leavesDetailDistance * 16.0;
    }

    /** Start of a section build (any thread): picks this build's detail and records it. */
    static void beginRebuild(RenderChunk rc) {
        boolean far = false;
        double d = limit();
        if (d > 0 && Minecraft.getMinecraft().gameSettings.fancyGraphics) far = dist2(rc) > d * d;
        boolean smart = Config.smartLeaves;
        boolean[] f = FAR.get();
        f[0] = far;
        f[1] = smart;
        if (SET != null) {
            try {
                SET.invokeExact(rc, (far ? 2 : 1) | (smart ? 4 : 0));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /** End of a section build. */
    static void endRebuild() {
        boolean[] f = FAR.get();
        f[0] = f[1] = false;
    }

    static void camera(double vx, double vy, double vz) {
        camX = vx;
        camY = vy;
        camZ = vz;
    }

    /** With each new visible-section snapshot (client thread): queues sections built at the wrong detail. */
    private static double checkedX = Double.NaN, checkedY, checkedZ;
    private static long checkedAt;
    private static int checkedSettings = -1;

    static void check(RenderChunk[] visible, int n) {
        if (GET == null) return;
        // sections are built at the detail their distance asks for then, so the distance only
        // needs re-checking as the camera moves on (or settings change), not per frame
        int settings = Config.leavesDetailDistance * 4 + (Config.smartLeaves ? 2 : 0)
                + (Minecraft.getMinecraft().gameSettings.fancyGraphics ? 1 : 0);
        long now = System.nanoTime();
        double mx = camX - checkedX, my = camY - checkedY, mz = camZ - checkedZ;
        if (settings == checkedSettings && mx * mx + my * my + mz * mz < 16.0 && now - checkedAt < 500_000_000L) return;
        checkedSettings = settings;
        checkedX = camX;
        checkedY = camY;
        checkedZ = camZ;
        checkedAt = now;
        double d = limit();
        boolean fancy = Minecraft.getMinecraft().gameSettings.fancyGraphics;
        boolean smart = Config.smartLeaves;
        double margin = 12.0;
        double nearIn = (d - margin) * (d - margin), farOut = (d + margin) * (d + margin);
        int requested = 0;
        try {
            for (int i = 0; i < n; i++) {
                RenderChunk rc = visible[i];
                int built = (int) GET.invokeExact(rc);
                if (built == 0 || (built & 8) != 0 || rc.isNeedsUpdate()) continue;
                boolean builtFar = (built & 3) == 2, wantFar;
                if (d <= 0 || !fancy) wantFar = false;
                else {
                    double r2 = dist2(rc);
                    wantFar = builtFar ? r2 > nearIn : r2 > farOut;
                }
                if (wantFar != builtFar || (fancy && smart != ((built & 4) != 0))) {
                    // queued: not asked again before a worker starts it (and records how it builds)
                    rc.setNeedsUpdate(true);
                    SET.invokeExact(rc, built | 8);
                    requested++;
                }
            }
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        if (DEBUG && requested > 0) metal189.engine.Native.LOG.info("lod: {} rebuilds requested", requested);
    }

    private static final boolean DEBUG = Boolean.getBoolean("metal189.lodDebug");
}
