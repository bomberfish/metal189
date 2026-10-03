package metal189.world;

import metal189.engine.Cmd;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.gl.Draw;
import metal189.gl.GL;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.ActiveRenderInfo;
import net.minecraft.entity.Entity;
import net.minecraft.util.Vec3;
import net.minecraft.world.World;
import net.minecraftforge.client.MinecraftForgeClient;

/**
 * Marks the stages of EntityRenderer.renderWorldPass in the command stream
 * and records per-frame environment data, so the engine can route captured
 * draws into its own passes (shadows, G-buffer, forward translucents, ...).
 */
public final class Phases {
    private Phases() {}

    // Mirrors native/src/commands.h (Phase enum).
    public static final int UI = 0, WORLD_BEGIN = 1, SKY = 2, CLOUDS = 3, TERRAIN = 4, ENTITIES = 5, OUTLINE = 6,
            DESTROY = 7, LIT_PARTICLES = 8, PARTICLES = 9, WEATHER = 10, WORLD_BORDER = 11, ENTITIES_TRANSLUCENT = 12,
            RENDER_LAST = 13, HAND = 14, WORLD_END = 15, WORLD_BEGIN_AUX = 16;

    public static int current = UI;

    public static void begin(int phase) {
        current = phase;
        if (metal189.gl.Lists.compiling != null) return;
        Draw.flush();
        long p = Engine.cmd.begin(Cmd.PHASE, 2);
        Mem.putInt(p, phase);
    }

    public static void worldBegin() {
        Pipeline.ensureApplied();
        metal189.terrain.Terrain.drainPending();
        // Only the world render into Minecraft's own framebuffer is the main view; extra
        // renderWorldPass calls into other framebuffers (mods' picture-in-picture cameras,
        // mirrors) are recorded as auxiliary segments, which the engine draws with the
        // baseline renderer so they cannot disturb the main view's temporal history.
        begin(isMainTarget() ? WORLD_BEGIN : WORLD_BEGIN_AUX);
    }

    private static boolean isMainTarget() {
        Minecraft mc = Minecraft.getMinecraft();
        net.minecraft.client.shader.Framebuffer fb = mc.getFramebuffer();
        int main = fb != null && net.minecraft.client.renderer.OpenGlHelper.isFramebufferEnabled() ? fb.framebufferObject : 0;
        return metal189.gl.Targets.drawFbo == main;
    }
    public static void worldEnd() { begin(WORLD_END); begin(UI); }
    public static void sky() { begin(SKY); }
    public static void clouds() { begin(CLOUDS); }
    public static void outline() { begin(OUTLINE); }
    public static void destroy() { begin(DESTROY); }
    public static void litParticles() { begin(LIT_PARTICLES); }
    public static void particles() { begin(PARTICLES); }
    public static void weather() { begin(WEATHER); }
    public static void worldBorder() { begin(WORLD_BORDER); }
    public static void renderLast() { begin(RENDER_LAST); }
    public static void hand() { begin(HAND); }

    public static void entities() {
        begin(MinecraftForgeClient.getRenderPass() == 1 ? ENTITIES_TRANSLUCENT : ENTITIES);
    }

    /**
     * Before RenderGlobal.setupTerrain: the modelview is the camera transform
     * and the projection is the world projection. Records them with the
     * environment parameters the engine's own sky/lighting needs.
     */
    public static void terrain(float partialTicks) {
        begin(TERRAIN);
        Minecraft mc = Minecraft.getMinecraft();
        World w = mc.theWorld;
        Entity cam = mc.getRenderViewEntity();
        if (w == null || cam == null) return;
        double cx = cam.lastTickPosX + (cam.posX - cam.lastTickPosX) * partialTicks;
        double cy = cam.lastTickPosY + (cam.posY - cam.lastTickPosY) * partialTicks;
        double cz = cam.lastTickPosZ + (cam.posZ - cam.lastTickPosZ) * partialTicks;
        Vec3 sky = w.getSkyColor(cam, partialTicks);
        long p = Engine.cmd.begin(Cmd.ENV, 1 + 64);
        float[] mv = GL.modelview.array();
        int o = GL.modelview.top();
        for (int i = 0; i < 16; i++) Mem.putFloat(p + i * 4, mv[o + i]);
        float[] pr = GL.projection.array();
        int po = GL.projection.top();
        for (int i = 0; i < 16; i++) Mem.putFloat(p + 64 + i * 4, pr[po + i]);
        long q = p + 128;
        // camera position split into integer block + fraction for precision
        putPos(q, cx); putPos(q + 8, cy); putPos(q + 16, cz);
        q += 24;
        Mem.putFloat(q, partialTicks);
        Mem.putFloat(q + 4, w.getCelestialAngle(partialTicks));
        Mem.putFloat(q + 8, w.getSunBrightness(partialTicks));
        Mem.putFloat(q + 12, w.getStarBrightness(partialTicks));
        Mem.putFloat(q + 16, (float) sky.xCoord);
        Mem.putFloat(q + 20, (float) sky.yCoord);
        Mem.putFloat(q + 24, (float) sky.zCoord);
        Mem.putFloat(q + 28, w.getRainStrength(partialTicks));
        Mem.putFloat(q + 32, w.getThunderStrength(partialTicks));
        Mem.putInt(q + 36, w.getMoonPhase());
        Mem.putInt(q + 40, w.provider.getDimensionId());
        Mem.putInt(q + 44, (int) (w.getWorldTime() % 24000L));
        Mem.putFloat(q + 48, (float) ((w.getTotalWorldTime() % 1200000L) + partialTicks) / 20.0f);
        Mem.putInt(q + 52, cam.isInsideOfMaterial(net.minecraft.block.material.Material.water) ? 1
                : cam.isInsideOfMaterial(net.minecraft.block.material.Material.lava) ? 2 : 0);
        Mem.putFloat(q + 56, mc.gameSettings.renderDistanceChunks * 16f);
        Mem.putFloat(q + 60, ActiveRenderInfo.getRotationX());
        Mem.putInt(q + 64, handLight(mc));
        // 64 words total: 16 mv + 16 proj + 6 pos + 16 params + pad
    }

    /** Light level carried by the player (held light sources, or burning), like OptiFine's dynamic lights. */
    private static int handLight(Minecraft mc) {
        net.minecraft.entity.player.EntityPlayer p = mc.thePlayer;
        if (p == null) return 0;
        int level = p.isBurning() ? 15 : 0;
        net.minecraft.item.ItemStack held = p.getHeldItem();
        if (held != null && held.getItem() != null) {
            net.minecraft.item.Item item = held.getItem();
            if (item instanceof net.minecraft.item.ItemBlock) level = Math.max(level, ((net.minecraft.item.ItemBlock) item).getBlock().getLightValue());
            else if (item == net.minecraft.init.Items.lava_bucket) level = Math.max(level, 15);
            else if (item == net.minecraft.init.Items.blaze_rod) level = Math.max(level, 10);
            else if (item == net.minecraft.init.Items.glowstone_dust || item == net.minecraft.init.Items.blaze_powder
                    || item == net.minecraft.init.Items.magma_cream) level = Math.max(level, 8);
            else if (item == net.minecraft.init.Items.nether_star) level = Math.max(level, 12);
        }
        return level;
    }

    private static void putPos(long p, double v) {
        int i = (int) Math.floor(v);
        Mem.putInt(p, i);
        Mem.putFloat(p + 4, (float) (v - i));
    }
}
