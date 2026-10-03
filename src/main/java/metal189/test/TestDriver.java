package metal189.test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import metal189.engine.Native;
import net.minecraft.client.Minecraft;
import net.minecraft.world.WorldSettings;
import net.minecraft.world.WorldType;

/**
 * Scripted test runs (-Dmetal189.test=script-file or -Dmetal189.testScript="a;b;c").
 * Commands run between frames on the client thread:
 *   wait N | sleep SECONDS | waitWorld | capture PATH | key NAME | world NAME [SEED]
 *   cmd /command | look YAW PITCH | fps SECONDS LABEL | gui none | quit
 */
public final class TestDriver {
    private TestDriver() {}

    private static List<String> script;
    private static int pc;
    private static int waitFrames;
    private static long waitUntil;
    private static long fpsStart, fpsFrames, fpsEnd;
    private static String fpsLabel;
    private static boolean active;
    private static int frame;

    static {
        try {
            String inline = System.getProperty("metal189.testScript");
            String file = System.getProperty("metal189.test");
            if (inline != null) script = new ArrayList<String>(Arrays.asList(inline.split(";")));
            else if (file != null) script = Files.readAllLines(new File(file).toPath(), StandardCharsets.UTF_8);
            active = script != null;
        } catch (Exception e) {
            Native.LOG.error("metal189: cannot read test script", e);
        }
    }

    public static boolean active() { return active; }

    private static String pendingCapture;

    /** Reference mode: captures are taken from the GL framebuffer before the swap. */
    public static void beforeSwap() {
        if (pendingCapture == null) return;
        String path = pendingCapture;
        pendingCapture = null;
        boolean ok = Capture.glFramebuffer(path);
        Native.LOG.info("metal189-test capture {} -> {}", path, ok ? "ok" : "FAILED");
    }

    private static int hurtTicks;
    private static boolean leavingDimension;
    private static Pip pip;
    private static net.minecraft.server.MinecraftServer quitServer;
    private static int quitWait;
    private static float spinRate;
    private static int spinFrames;

    /** Called after every presented frame. */
    public static void onFrame() {
        if (!active) return;
        frame++;
        if (spinFrames > 0) {
            spinFrames--;
            Minecraft m = Minecraft.getMinecraft();
            if (m.thePlayer != null) {
                m.thePlayer.prevRotationYaw = m.thePlayer.rotationYaw;
                m.thePlayer.rotationYaw += spinRate;
            }
        }
        if (hurtTicks > 0) {
            Minecraft m = Minecraft.getMinecraft();
            if (m.theWorld != null) {
                for (Object o : m.theWorld.loadedEntityList) {
                    if (o instanceof net.minecraft.entity.EntityLivingBase && o != m.thePlayer) ((net.minecraft.entity.EntityLivingBase) o).hurtTime = hurtTicks;
                }
            }
        }
        if (fpsLabel != null) {
            fpsFrames++;
            long now = System.nanoTime();
            if (now >= fpsEnd) {
                double secs = (now - fpsStart) / 1e9;
                Native.LOG.info("metal189-test fps {} = {} ({} frames in {}s)", fpsLabel, String.format("%.1f", fpsFrames / secs), fpsFrames, String.format("%.2f", secs));
                fpsLabel = null;
            }
            return;
        }
        if (waitFrames > 0) { waitFrames--; return; }
        if (waitUntil != 0) {
            if (System.nanoTime() < waitUntil) return;
            waitUntil = 0;
        }
        while (pc < script.size()) {
            String line = script.get(pc++).trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            if (!run(line)) return;
        }
    }

    /** @return true to continue with the next line in the same frame */
    private static boolean run(String line) {
        String[] a = line.split("\\s+");
        Minecraft mc = Minecraft.getMinecraft();
        if (!line.startsWith("cmd /summon")) Native.LOG.info("metal189-test [{}] {}", frame, line);
        switch (a[0]) {
            case "wait": waitFrames = Integer.parseInt(a[1]); return false;
            case "sleep": waitUntil = System.nanoTime() + (long) (Double.parseDouble(a[1]) * 1e9); return false;
            case "waitWorld":
                if (mc.theWorld == null || mc.thePlayer == null || mc.renderGlobal == null) { pc--; return false; }
                // scenes start alive in the overworld, whatever state an earlier run saved
                if (mc.thePlayer.getHealth() <= 0.0F || mc.thePlayer.isDead) {
                    mc.thePlayer.respawnPlayer();
                    mc.displayGuiScreen(null);
                    pc--;
                    return false;
                }
                if (mc.thePlayer.dimension != 0) {
                    if (!leavingDimension) {
                        leavingDimension = true;
                        run("dim 0");
                    }
                    pc--;
                    return false;
                }
                leavingDimension = false;
                return true;
            case "capture": {
                if (metal189.core.Settings.reference()) {
                    pendingCapture = a[1]; // taken from the next frame, before its swap
                    waitFrames = 1;
                    return false;
                }
                boolean ok = Capture.metalFramebuffer(a[1]);
                Native.LOG.info("metal189-test capture {} -> {}", a[1], ok ? "ok" : "FAILED");
                return true;
            }
            case "world": {
                long seed = a.length > 2 ? Long.parseLong(a[2]) : 1L;
                WorldType type = a.length > 3 && "flat".equals(a[3]) ? WorldType.FLAT : WorldType.DEFAULT;
                WorldSettings ws = new WorldSettings(seed, WorldSettings.GameType.CREATIVE, true, false, type);
                ws.enableCommands();
                mc.launchIntegratedServer(a[1], a[1], ws);
                return false;
            }
            case "cmd": {
                String c = line.substring(4).trim();
                final net.minecraft.server.MinecraftServer srv = net.minecraft.server.MinecraftServer.getServer();
                if (srv != null && mc.thePlayer != null) {
                    final String cmdText = c;
                    final net.minecraft.entity.player.EntityPlayerMP p = srv.getConfigurationManager().getPlayerByUsername(mc.thePlayer.getName());
                    if (p != null) {
                        srv.addScheduledTask(new Runnable() {
                            public void run() { srv.getCommandManager().executeCommand(p, cmdText); }
                        });
                        return true;
                    }
                }
                if (mc.thePlayer != null) mc.thePlayer.sendChatMessage(c);
                return true;
            }
            case "dim": {
                final int dim = Integer.parseInt(a[1]);
                final net.minecraft.server.MinecraftServer srv = net.minecraft.server.MinecraftServer.getServer();
                if (srv != null && mc.thePlayer != null) {
                    final String name = mc.thePlayer.getName();
                    srv.addScheduledTask(new Runnable() {
                        public void run() {
                            net.minecraft.entity.player.EntityPlayerMP p = srv.getConfigurationManager().getPlayerByUsername(name);
                            // no portal: vanilla's portal search NPEs when travelling without one
                            if (p != null) srv.getConfigurationManager().transferPlayerToDimension(p, dim, new NoPortal(srv.worldServerForDimension(dim), dim));
                        }
                    });
                }
                return true;
            }
            case "hurtall":
                hurtTicks = Integer.parseInt(a[1]);
                return true;
            case "summongrid": {
                // summongrid N SPACING Type1,Type2,...  -> NoAI mobs in a square grid in front of the player
                int n = Integer.parseInt(a[1]);
                double sp = Double.parseDouble(a[2]);
                String[] types = a[3].split(",");
                int side = (int) Math.ceil(Math.sqrt(n));
                double px = mc.thePlayer.posX, py = mc.thePlayer.posY, pz = mc.thePlayer.posZ;
                StringBuilder all = new StringBuilder();
                for (int i = 0; i < n; i++) {
                    double x = px + (i % side - side / 2) * sp, z = pz - 4 - (i / side) * sp;
                    String t = types[i % types.length];
                    run("cmd /summon " + t + " " + x + " " + py + " " + z + " {NoAI:1,Rotation:[" + (i * 37 % 360) + "f,0f]}");
                }
                return true;
            }
            case "spin": {
                // spin DEGREES_PER_FRAME FRAMES : rotate the camera continuously while measuring
                spinRate = Float.parseFloat(a[1]);
                spinFrames = Integer.parseInt(a[2]);
                return true;
            }
            case "look":
                if (mc.thePlayer != null) {
                    mc.thePlayer.rotationYaw = mc.thePlayer.prevRotationYaw = Float.parseFloat(a[1]);
                    mc.thePlayer.rotationPitch = mc.thePlayer.prevRotationPitch = Float.parseFloat(a[2]);
                }
                return true;
            case "gui":
                if ("none".equals(a[1])) mc.displayGuiScreen(null);
                else if ("inventory".equals(a[1]) && mc.thePlayer != null) mc.displayGuiScreen(new net.minecraft.client.gui.inventory.GuiContainerCreative(mc.thePlayer));
                else if ("survival".equals(a[1]) && mc.thePlayer != null) mc.displayGuiScreen(new net.minecraft.client.gui.inventory.GuiInventory(mc.thePlayer));
                else if ("options".equals(a[1])) mc.displayGuiScreen(new net.minecraft.client.gui.GuiOptions(null, mc.gameSettings));
                else if ("video".equals(a[1])) mc.displayGuiScreen(new net.minecraft.client.gui.GuiVideoSettings(null, mc.gameSettings));
                else if ("metal189".equals(a[1])) mc.displayGuiScreen(new metal189.gui.GuiMetal189(null));
                return true;
            case "f3":
                mc.gameSettings.showDebugInfo = !mc.gameSettings.showDebugInfo;
                return true;
            case "hidegui":
                mc.gameSettings.hideGUI = !mc.gameSettings.hideGUI;
                return true;
            case "slot":
                if (mc.thePlayer != null) mc.thePlayer.inventory.currentItem = Integer.parseInt(a[1]);
                return true;
            case "resourcepack": {
                // resourcepack NAME|none : select one pack and reload (options are not saved)
                net.minecraft.client.resources.ResourcePackRepository repo = mc.getResourcePackRepository();
                repo.updateRepositoryEntriesAll();
                java.util.List<net.minecraft.client.resources.ResourcePackRepository.Entry> sel =
                        new java.util.ArrayList<net.minecraft.client.resources.ResourcePackRepository.Entry>();
                for (net.minecraft.client.resources.ResourcePackRepository.Entry e : repo.getRepositoryEntriesAll())
                    if (e.getResourcePackName().equals(a[1])) sel.add(e);
                if (sel.isEmpty() && !"none".equals(a[1])) Native.LOG.warn("metal189-test: no resource pack {}", a[1]);
                repo.setRepositories(sel);
                mc.refreshResources();
                return true;
            }
            case "config": {
                // config FIELD VALUE : set a metal189.config.Config field and re-apply the pipeline
                try {
                    java.lang.reflect.Field f = metal189.config.Config.class.getField(a[1]);
                    if (f.getType() == boolean.class) f.setBoolean(null, Boolean.parseBoolean(a[2]));
                    else if (f.getType() == int.class) f.setInt(null, Integer.parseInt(a[2]));
                    metal189.world.Pipeline.apply();
                } catch (Exception ex) {
                    Native.LOG.warn("metal189-test: config {}: {}", a[1], ex.toString());
                }
                return true;
            }
            case "reload":
                // like F3+A
                if (mc.renderGlobal != null) mc.renderGlobal.loadRenderers();
                return true;
            case "pip":
                // pip on|off : like foidclient's remote view, render a second world pass into a
                // small framebuffer every frame and draw it in the corner
                if ("on".equals(a[1]) && pip == null) {
                    pip = new Pip();
                    net.minecraftforge.fml.common.FMLCommonHandler.instance().bus().register(pip);
                } else if ("off".equals(a[1]) && pip != null) {
                    net.minecraftforge.fml.common.FMLCommonHandler.instance().bus().unregister(pip);
                    pip = null;
                }
                return true;
            case "toggle":
                // same path as the toggle keybind (saves config/metal189.properties)
                metal189.world.Pipeline.toggle();
                return true;
            case "lightat": {
                // lightat X Y Z : client-side block/sky light values (renderer-independent state)
                if (mc.theWorld != null) {
                    net.minecraft.util.BlockPos bp = new net.minecraft.util.BlockPos(Integer.parseInt(a[1]), Integer.parseInt(a[2]), Integer.parseInt(a[3]));
                    Native.LOG.info("metal189-test lightat {}: block {} sky {}", bp,
                            mc.theWorld.getLightFor(net.minecraft.world.EnumSkyBlock.BLOCK, bp),
                            mc.theWorld.getLightFor(net.minecraft.world.EnumSkyBlock.SKY, bp));
                }
                return true;
            }
            case "info":
                if (mc.thePlayer != null) {
                    net.minecraft.entity.Entity v = mc.getRenderViewEntity();
                    Native.LOG.info("metal189-test info: player {} {} {} yaw {} pitch {} flying {} invisible {} view {} viewIsPlayer {} third {} {}",
                            mc.thePlayer.posX, mc.thePlayer.posY, mc.thePlayer.posZ, mc.thePlayer.rotationYaw, mc.thePlayer.rotationPitch,
                            mc.thePlayer.capabilities.isFlying, mc.thePlayer.isInvisible(), v, v == mc.thePlayer,
                            mc.gameSettings.thirdPersonView, mc.renderGlobal.getDebugInfoEntities());
                }
                return true;
            case "fly":
                // keep the camera where /tp put it (creative flight)
                if (mc.thePlayer != null) {
                    mc.thePlayer.capabilities.isFlying = !"off".equals(a.length > 1 ? a[1] : "on");
                    mc.thePlayer.sendPlayerAbilities();
                }
                return true;
            case "perspective":
                mc.gameSettings.thirdPersonView = Integer.parseInt(a[1]);
                return true;
            case "fps":
                fpsStart = System.nanoTime();
                fpsEnd = fpsStart + (long) (Double.parseDouble(a[1]) * 1e9);
                fpsFrames = 0;
                fpsLabel = a.length > 2 ? a[2] : "run";
                return false;
            case "quit": {
                // like Save and Quit to Title first, so the world is saved by the server thread
                // alone (vanilla races its shutdown hook against it when quitting in-world)
                net.minecraft.server.MinecraftServer srv = net.minecraft.server.MinecraftServer.getServer();
                if (mc.theWorld != null) {
                    quitServer = srv;
                    mc.theWorld.sendQuittingDisconnectingPacket();
                    mc.loadWorld(null);
                    mc.displayGuiScreen(new net.minecraft.client.gui.GuiMainMenu());
                    pc--;
                    return false;
                }
                if (quitServer != null && !quitServer.isServerStopped() && quitWait++ < 600) {
                    pc--;
                    return false;
                }
                mc.shutdown();
                return false;
            }
            case "screenshot": {
                // the F2 path (ScreenShotHelper reads the framebuffer through the GL layer)
                net.minecraft.util.IChatComponent msg = net.minecraft.util.ScreenShotHelper.saveScreenshot(
                        mc.mcDataDir, a.length > 1 ? a[1] : null, mc.displayWidth, mc.displayHeight, mc.getFramebuffer());
                Native.LOG.info("metal189-test screenshot: {}", msg == null ? "null" : msg.getUnformattedText());
                return true;
            }
            default:
                Native.LOG.warn("metal189-test: unknown command {}", line);
                return true;
        }
    }

    /** Places the travelling entity without searching for or building a portal. */
    static final class NoPortal extends net.minecraft.world.Teleporter {
        NoPortal(net.minecraft.world.WorldServer w, int dim) {
            super(w);
            this.dim = dim;
        }

        private final int dim;

        @Override
        public void placeInPortal(net.minecraft.entity.Entity e, float yaw) {
            // the End: above the main island; elsewhere: same x/z at y 64. Players start flying
            if (dim == 1) e.setLocationAndAngles(0.5, 90.0, 0.5, e.rotationYaw, 0.0F);
            else e.setLocationAndAngles(e.posX, 64.0, e.posZ, e.rotationYaw, 0.0F);
            e.motionX = e.motionY = e.motionZ = 0.0;
            if (e instanceof net.minecraft.entity.player.EntityPlayerMP) {
                net.minecraft.entity.player.EntityPlayerMP p = (net.minecraft.entity.player.EntityPlayerMP) e;
                p.capabilities.isFlying = true;
                p.sendPlayerAbilities();
            }
        }

        @Override
        public boolean placeInExistingPortal(net.minecraft.entity.Entity e, float yaw) { return true; }

        @Override
        public boolean makePortal(net.minecraft.entity.Entity e) { return true; }

        @Override
        public void removeStalePortalLocations(long time) {}
    }

    /** Secondary world render into its own framebuffer (exercises auxiliary world segments). */
    public static final class Pip {
        private net.minecraft.client.shader.Framebuffer fb;
        private java.lang.reflect.Method pass;
        private boolean inside;

        @net.minecraftforge.fml.common.eventhandler.SubscribeEvent
        public void onRenderTick(net.minecraftforge.fml.common.gameevent.TickEvent.RenderTickEvent e) {
            Minecraft mc = Minecraft.getMinecraft();
            if (e.phase != net.minecraftforge.fml.common.gameevent.TickEvent.Phase.END || inside || mc.theWorld == null) return;
            int w = mc.displayWidth / 3, h = mc.displayHeight / 3;
            try {
                if (pass == null) {
                    for (java.lang.reflect.Method m : net.minecraft.client.renderer.EntityRenderer.class.getDeclaredMethods())
                        if ((m.getName().equals("renderWorldPass") || m.getName().equals("func_175068_a")) && m.getParameterTypes().length == 3) pass = m;
                    pass.setAccessible(true);
                }
                if (fb == null || fb.framebufferWidth != w || fb.framebufferHeight != h) {
                    if (fb != null) fb.deleteFramebuffer();
                    fb = new net.minecraft.client.shader.Framebuffer(w, h, true);
                }
                inside = true;
                int dw = mc.displayWidth, dh = mc.displayHeight;
                fb.bindFramebuffer(true);
                mc.displayWidth = w;
                mc.displayHeight = h;
                try {
                    pass.invoke(mc.entityRenderer, 2, e.renderTickTime, System.nanoTime() + 1000000L);
                } finally {
                    mc.displayWidth = dw;
                    mc.displayHeight = dh;
                    inside = false;
                }
                mc.getFramebuffer().bindFramebuffer(true);
                // draw the picture in the top-right corner
                net.minecraft.client.renderer.GlStateManager.matrixMode(org.lwjgl.opengl.GL11.GL_PROJECTION);
                net.minecraft.client.renderer.GlStateManager.loadIdentity();
                net.minecraft.client.renderer.GlStateManager.ortho(0, dw, dh, 0, 1000, 3000);
                net.minecraft.client.renderer.GlStateManager.matrixMode(org.lwjgl.opengl.GL11.GL_MODELVIEW);
                net.minecraft.client.renderer.GlStateManager.loadIdentity();
                net.minecraft.client.renderer.GlStateManager.translate(0, 0, -2000);
                net.minecraft.client.renderer.GlStateManager.disableDepth();
                net.minecraft.client.renderer.GlStateManager.disableLighting();
                net.minecraft.client.renderer.GlStateManager.disableFog();
                net.minecraft.client.renderer.GlStateManager.disableAlpha();
                net.minecraft.client.renderer.GlStateManager.disableBlend();
                net.minecraft.client.renderer.GlStateManager.enableTexture2D();
                net.minecraft.client.renderer.GlStateManager.color(1, 1, 1, 1);
                fb.bindFramebufferTexture();
                net.minecraft.client.renderer.Tessellator t = net.minecraft.client.renderer.Tessellator.getInstance();
                net.minecraft.client.renderer.WorldRenderer r = t.getWorldRenderer();
                double x0 = dw - w - 8, y0 = 8, x1 = dw - 8, y1 = 8 + h;
                r.begin(7, net.minecraft.client.renderer.vertex.DefaultVertexFormats.POSITION_TEX);
                r.pos(x0, y1, 0).tex(0, 0).endVertex();
                r.pos(x1, y1, 0).tex(1, 0).endVertex();
                r.pos(x1, y0, 0).tex(1, 1).endVertex();
                r.pos(x0, y0, 0).tex(0, 1).endVertex();
                t.draw();
                fb.unbindFramebufferTexture();
                net.minecraft.client.renderer.GlStateManager.enableDepth();
            } catch (Exception ex) {
                Native.LOG.warn("metal189-test pip: {}", ex.toString());
            }
        }
    }
}
