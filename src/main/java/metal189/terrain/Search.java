package metal189.terrain;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import metal189.engine.Native;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.RenderGlobal;
import net.minecraft.client.renderer.chunk.CompiledChunk;
import net.minecraft.client.renderer.chunk.RenderChunk;
import net.minecraft.client.renderer.culling.ICamera;
import net.minecraft.entity.Entity;
import net.minecraft.util.BlockPos;
import net.minecraft.util.EnumFacing;
import net.minecraft.util.MathHelper;
import org.lwjgl.util.vector.Vector3f;

/**
 * The terrain visibility search (RenderGlobal.setupTerrain's flood fill), rewritten without
 * per-section allocation: vanilla makes an info object and an EnumSet for every section it
 * reaches and walks them through a linked list, tens of thousands per search at long render
 * distances, and searches again every frame the camera moves.
 *
 * Same rules as vanilla, so the same sections in the same order: a breadth-first flood from
 * the camera's section through the view frustum, never stepping back along a direction it
 * already took, through a section only between faces its visibility graph connects (caves
 * stay hidden), within the render distance square. Results go into renderInfos as vanilla's
 * own info objects (one kept per section), so the rest of the game sees nothing different.
 */
public final class Search {
    private Search() {}

    private static final boolean DISABLED = Boolean.getBoolean("metal189.vanillaSearch");
    private static final boolean DEBUG = Boolean.getBoolean("metal189.searchDebug");
    private static String debugOpen = "";
    private static final EnumFacing[] FACINGS = EnumFacing.values();
    private static final int[] OPPOSITE = new int[6];
    private static final int[] DX = new int[6], DY = new int[6], DZ = new int[6];

    static {
        for (EnumFacing f : FACINGS) {
            OPPOSITE[f.ordinal()] = f.getOpposite().ordinal();
            DX[f.ordinal()] = f.getFrontOffsetX();
            DY[f.ordinal()] = f.getFrontOffsetY();
            DZ[f.ordinal()] = f.getFrontOffsetZ();
        }
    }

    private static MethodHandle getter(Class<?> c, String... names) throws Exception {
        for (String n : names) {
            try {
                Field f = c.getDeclaredField(n);
                f.setAccessible(true);
                return MethodHandles.lookup().unreflectGetter(f);
            } catch (NoSuchFieldException ignored) {
            }
        }
        throw new NoSuchFieldException(c.getName() + "." + names[0]);
    }

    private static MethodHandle setter(Class<?> c, String... names) throws Exception {
        for (String n : names) {
            try {
                Field f = c.getDeclaredField(n);
                f.setAccessible(true);
                return MethodHandles.lookup().unreflectSetter(f);
            } catch (NoSuchFieldException ignored) {
            }
        }
        throw new NoSuchFieldException(c.getName() + "." + names[0]);
    }

    private static MethodHandle method(Class<?> c, Class<?>[] args, String... names) throws Exception {
        for (String n : names) {
            try {
                Method m = c.getDeclaredMethod(n, args);
                m.setAccessible(true);
                return MethodHandles.lookup().unreflect(m);
            } catch (NoSuchMethodException ignored) {
            }
        }
        throw new NoSuchMethodException(c.getName() + "." + names[0]);
    }

    private static final MethodHandle VIEW_FRUSTUM, RENDER_DISTANCE, SET_RENDER_INFOS, SET_DIRTY, VISIBLE_FACINGS, VIEW_VECTOR;
    private static final MethodHandle VF_CHUNKS, VF_X, VF_Y, VF_Z, NEW_INFO;
    private static final MethodHandle FR_HELPER, FR_X, FR_Y, FR_Z;
    private static final boolean READY;

    static {
        MethodHandle vf = null, rd = null, ri = null, dirty = null, facings = null, view = null, ch = null, cx = null, cy = null,
                cz = null, info = null;
        boolean ok = false;
        MethodHandle frh = null, frx = null, fry = null, frz = null;
        try {
            Class<?> fc = net.minecraft.client.renderer.culling.Frustum.class;
            frh = getter(fc, "clippingHelper", "field_78552_a");
            frx = getter(fc, "xPosition", "field_78550_b");
            fry = getter(fc, "yPosition", "field_78551_c");
            frz = getter(fc, "zPosition", "field_78549_d");
        } catch (Exception e) {
            Native.LOG.warn("metal189: Frustum layout not recognised; terrain search uses its box test", e);
        }
        FR_HELPER = frh;
        FR_X = frx;
        FR_Y = fry;
        FR_Z = frz;
        try {
            Class<?> vfc = Class.forName("net.minecraft.client.renderer.ViewFrustum");
            vf = getter(RenderGlobal.class, "viewFrustum", "field_175008_n");
            rd = getter(RenderGlobal.class, "renderDistanceChunks", "field_72739_F");
            ri = setter(RenderGlobal.class, "renderInfos", "field_72755_R");
            dirty = setter(RenderGlobal.class, "displayListEntitiesDirty", "field_147595_R");
            facings = method(RenderGlobal.class, new Class<?>[] {BlockPos.class}, "getVisibleFacings", "func_174978_c");
            view = method(RenderGlobal.class, new Class<?>[] {Entity.class, double.class}, "getViewVector", "func_174962_a");
            ch = getter(vfc, "renderChunks", "field_178164_f");
            cx = getter(vfc, "countChunksX", "field_178165_d");
            cy = getter(vfc, "countChunksY", "field_178168_c");
            cz = getter(vfc, "countChunksZ", "field_178166_e");
            Class<?> ic = Class.forName("net.minecraft.client.renderer.RenderGlobal$ContainerLocalRenderInformation");
            Constructor<?> k = ic.getDeclaredConstructor(RenderGlobal.class, RenderChunk.class, EnumFacing.class, int.class);
            k.setAccessible(true);
            info = MethodHandles.lookup().unreflectConstructor(k);
            ok = !DISABLED;
        } catch (Exception e) {
            Native.LOG.warn("metal189: RenderGlobal layout not recognised; vanilla terrain search kept", e);
        }
        VIEW_FRUSTUM = vf;
        RENDER_DISTANCE = rd;
        SET_RENDER_INFOS = ri;
        SET_DIRTY = dirty;
        VISIBLE_FACINGS = facings;
        VIEW_VECTOR = view;
        VF_CHUNKS = ch;
        VF_X = cx;
        VF_Y = cy;
        VF_Z = cz;
        NEW_INFO = info;
        READY = ok;
    }

    // per grid slot (ViewFrustum.renderChunks index)
    private static int[] stamp = new int[0];          // search id that reached the slot
    private static Object[] infoCache = new Object[0];
    private static RenderChunk[] infoChunk = new RenderChunk[0];
    private static CompiledChunk[] visCompiled = new CompiledChunk[0];
    private static long[] visMask = new long[0];      // bit (from * 6 + to): the section connects those faces
    private static int searchId;
    // the sections found, in order (handed to Visible)
    private static RenderChunk[] foundChunks = new RenderChunk[0];
    private static int found;
    // the flood's queue: slot, directions taken (mask), the face it entered through (-1: start)
    private static int[] qSlot = new int[0], qDirs = new int[0], qFrom = new int[0];

    // the camera section's visible faces (vanilla floods its blocks every search)
    private static long facingsKey = Long.MIN_VALUE;
    private static CompiledChunk facingsCompiled;
    private static Set<EnumFacing> facingsCached;

    private static long lastSearch;
    private static double lastX = Double.NaN, lastY, lastZ;
    private static float lastYaw, lastPitch;
    private static final long STILL_INTERVAL_NS = 50_000_000L;

    /**
     * Patched into setupTerrain at its "search again?" test (the value of
     * displayListEntitiesDirty there): runs this search when vanilla would run its own and
     * returns false so vanilla's is skipped. With the camera still, searches that chunk
     * updates ask for are limited to one per 50 ms (new sections appear at most that much later).
     */
    public static boolean run(boolean dirty, RenderGlobal rg, Entity viewEntity, double partialTicks, ICamera camera,
                              int frameCount, boolean playerSpectator) {
        if (!dirty) return false;
        long now = System.nanoTime();
        boolean moved = viewEntity.posX != lastX || viewEntity.posY != lastY || viewEntity.posZ != lastZ
                || viewEntity.rotationYaw != lastYaw || viewEntity.rotationPitch != lastPitch;
        if (!moved && now - lastSearch < STILL_INTERVAL_NS) return false;
        lastX = viewEntity.posX;
        lastY = viewEntity.posY;
        lastZ = viewEntity.posZ;
        lastYaw = viewEntity.rotationYaw;
        lastPitch = viewEntity.rotationPitch;
        lastSearch = now;
        if (!READY) return true;
        try {
            SET_DIRTY.invoke(rg, false);
            List<Object> infos = new ArrayList<Object>(Math.max(256, Visible.count + 64));
            found = 0;
            search(rg, viewEntity, partialTicks, camera, playerSpectator, infos);
            SET_RENDER_INFOS.invoke(rg, infos);
            Visible.publish(infos, foundChunks, found);
            if (DEBUG) Native.LOG.info("search: {} sections, frustum {}, open {}", found, fallback == null ? "planes" : "camera", debugOpen);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        return false;
    }

    private static void search(RenderGlobal rg, Entity viewEntity, double partialTicks, ICamera camera, boolean playerSpectator,
                               List<Object> out) throws Throwable {
        Object vf = VIEW_FRUSTUM.invoke(rg);
        RenderChunk[] grid = (RenderChunk[]) VF_CHUNKS.invoke(vf);
        int cx = (int) VF_X.invoke(vf), cy = (int) VF_Y.invoke(vf), cz = (int) VF_Z.invoke(vf);
        int renderDistance = (int) RENDER_DISTANCE.invoke(rg);
        int n = grid.length;
        if (stamp.length != n) {
            stamp = new int[n];
            infoCache = new Object[n];
            infoChunk = new RenderChunk[n];
            visCompiled = new CompiledChunk[n];
            visMask = new long[n];
            qSlot = new int[n];
            qDirs = new int[n];
            qFrom = new int[n];
        }
        loadFrustum(camera);
        int id = ++searchId;
        if (id == 0) { java.util.Arrays.fill(stamp, 0); id = searchId = 1; }

        double d3 = viewEntity.lastTickPosX + (viewEntity.posX - viewEntity.lastTickPosX) * partialTicks;
        double d4 = viewEntity.lastTickPosY + (viewEntity.posY - viewEntity.lastTickPosY) * partialTicks;
        double d5 = viewEntity.lastTickPosZ + (viewEntity.posZ - viewEntity.lastTickPosZ) * partialTicks;
        BlockPos eye = new BlockPos(d3, d4 + (double) viewEntity.getEyeHeight(), d5);
        // the section-aligned camera position the render distance is measured from
        int px = MathHelper.floor_double(d3 / 16.0) * 16, pz = MathHelper.floor_double(d5 / 16.0) * 16;
        int limit = renderDistance * 16;
        boolean occlusion = Minecraft.getMinecraft().renderChunksMany;

        int head = 0, tail = 0;
        int start = slot(eye.getX(), eye.getY(), eye.getZ(), cx, cy, cz);
        if (start >= 0) {
            Set<EnumFacing> open = visibleFacings(rg, eye, grid[start]);
            if (DEBUG) debugOpen = open.toString();
            if (open.size() == 1) {
                Vector3f v = (Vector3f) VIEW_VECTOR.invoke(rg, viewEntity, partialTicks);
                open.remove(EnumFacing.getFacingFromVector(v.x, v.y, v.z).getOpposite());
            }
            if (open.isEmpty() && !playerSpectator) {
                out.add(info(rg, start, grid[start]));
                return;
            }
            if (playerSpectator && Minecraft.getMinecraft().theWorld.getBlockState(eye).getBlock().isOpaqueCube()) occlusion = false;
            stamp[start] = id;
            qSlot[tail] = start;
            qDirs[tail] = 0;
            qFrom[tail] = -1;
            tail++;
        } else {
            // above or below the world: start from the top or bottom layer of sections in view
            int y = eye.getY() > 0 ? 248 : 8;
            for (int j = -renderDistance; j <= renderDistance; ++j) {
                for (int k = -renderDistance; k <= renderDistance; ++k) {
                    int s = slot((j << 4) + 8, y, (k << 4) + 8, cx, cy, cz);
                    if (s < 0 || stamp[s] == id) continue;
                    RenderChunk rc = grid[s];
                    if (rc == null || !inFrustum(rc)) continue;
                    stamp[s] = id;
                    qSlot[tail] = s;
                    qDirs[tail] = 0;
                    qFrom[tail] = -1;
                    tail++;
                }
            }
        }

        while (head < tail) {
            int s = qSlot[head], dirs = qDirs[head], from = qFrom[head];
            head++;
            RenderChunk rc = grid[s];
            out.add(info(rg, s, rc));
            long vis = (occlusion && from >= 0) ? visibility(s, rc) : -1L;
            BlockPos p = rc.getPosition();
            int x = p.getX(), y = p.getY(), z = p.getZ();
            for (int f = 0; f < 6; f++) {
                if (occlusion && (dirs & (1 << OPPOSITE[f])) != 0) continue;
                // entered through face `from` (the opposite of the step taken), leaving through f
                if (occlusion && from >= 0 && (vis & (1L << (OPPOSITE[from] * 6 + f))) == 0) continue;
                int nx = x + DX[f] * 16, ny = y + DY[f] * 16, nz = z + DZ[f] * 16;
                if (Math.abs(px - nx) > limit || ny < 0 || ny >= 256 || Math.abs(pz - nz) > limit) continue;
                int t = slot(nx, ny, nz, cx, cy, cz);
                if (t < 0 || stamp[t] == id) continue;
                RenderChunk nb = grid[t];
                if (nb == null) continue;
                stamp[t] = id;   // vanilla marks the section reached before testing the frustum
                if (!inFrustum(nb)) continue;
                qSlot[tail] = t;
                qDirs[tail] = dirs | (1 << f);
                qFrom[tail] = f;
                tail++;
            }
        }
    }

    // the search's view frustum: vanilla's planes and camera offset (Frustum / ClippingHelper)
    private static final float[][] planes = new float[6][4];
    private static double fx, fy, fz;
    private static ICamera fallback;   // a camera that is not vanilla's Frustum

    private static void loadFrustum(ICamera camera) throws Throwable {
        fallback = camera;
        if (FR_HELPER == null || camera.getClass() != net.minecraft.client.renderer.culling.Frustum.class) return;
        net.minecraft.client.renderer.culling.ClippingHelper h = (net.minecraft.client.renderer.culling.ClippingHelper) FR_HELPER.invoke(camera);
        for (int i = 0; i < 6; i++) System.arraycopy(h.frustum[i], 0, planes[i], 0, 4);
        fx = (double) FR_X.invoke(camera);
        fy = (double) FR_Y.invoke(camera);
        fz = (double) FR_Z.invoke(camera);
        fallback = null;
    }

    /**
     * ClippingHelper.isBoxInFrustum for a section's box: vanilla tests the eight corners
     * against each plane; the corner furthest along the plane's normal is one of them and the
     * largest, with the same arithmetic, so testing it alone gives the same answer.
     */
    private static boolean inFrustum(RenderChunk rc) {
        net.minecraft.util.AxisAlignedBB b = rc.boundingBox;
        if (fallback != null) return fallback.isBoundingBoxInFrustum(b);
        double x0 = b.minX - fx, y0 = b.minY - fy, z0 = b.minZ - fz, x1 = b.maxX - fx, y1 = b.maxY - fy, z1 = b.maxZ - fz;
        for (int j = 0; j < 6; j++) {
            float[] p = planes[j];
            double d = (double) p[0] * (p[0] > 0 ? x1 : x0) + (double) p[1] * (p[1] > 0 ? y1 : y0)
                    + (double) p[2] * (p[2] > 0 ? z1 : z0) + (double) p[3];
            if (!(d > 0.0)) return false;
        }
        return true;
    }

    /** ViewFrustum.getRenderChunk's index for a block position, or -1. */
    private static int slot(int bx, int by, int bz, int cx, int cy, int cz) {
        int i = MathHelper.bucketInt(bx, 16), j = MathHelper.bucketInt(by, 16), k = MathHelper.bucketInt(bz, 16);
        if (j < 0 || j >= cy) return -1;
        if ((i %= cx) < 0) i += cx;
        if ((k %= cz) < 0) k += cz;
        return (k * cy + j) * cx + i;
    }

    private static Object info(RenderGlobal rg, int s, RenderChunk rc) throws Throwable {
        if (found == foundChunks.length) foundChunks = java.util.Arrays.copyOf(foundChunks, Math.max(1024, found * 2));
        foundChunks[found++] = rc;
        Object o = infoCache[s];
        if (o == null || infoChunk[s] != rc) {
            o = NEW_INFO.invoke(rg, rc, (EnumFacing) null, 0);
            infoCache[s] = o;
            infoChunk[s] = rc;
        }
        return o;
    }

    /** The section's face-to-face connections (vanilla's CompiledChunk.isVisible), cached per compiled chunk. */
    private static long visibility(int s, RenderChunk rc) {
        CompiledChunk cc = rc.getCompiledChunk();
        if (visCompiled[s] == cc) return visMask[s];
        long m = 0;
        for (int a = 0; a < 6; a++)
            for (int b = 0; b < 6; b++)
                if (cc.isVisible(FACINGS[a], FACINGS[b])) m |= 1L << (a * 6 + b);
        visCompiled[s] = cc;
        visMask[s] = m;
        return m;
    }

    /** RenderGlobal.getVisibleFacings, kept while the camera block and its section's build stay the same. */
    @SuppressWarnings("unchecked")
    private static Set<EnumFacing> visibleFacings(RenderGlobal rg, BlockPos eye, RenderChunk rc) throws Throwable {
        long key = eye.toLong();
        CompiledChunk cc = rc != null ? rc.getCompiledChunk() : null;
        if (key != facingsKey || cc != facingsCompiled || facingsCached == null) {
            facingsCached = (Set<EnumFacing>) VISIBLE_FACINGS.invoke(rg, eye);
            facingsKey = key;
            facingsCompiled = cc;
        }
        return java.util.EnumSet.copyOf(facingsCached.isEmpty() ? java.util.EnumSet.noneOf(EnumFacing.class) : facingsCached);
    }
}
