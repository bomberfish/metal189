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

    /** Called after every presented frame. */
    public static void onFrame() {
        if (!active) return;
        frame++;
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
        Native.LOG.info("metal189-test [{}] {}", frame, line);
        switch (a[0]) {
            case "wait": waitFrames = Integer.parseInt(a[1]); return false;
            case "sleep": waitUntil = System.nanoTime() + (long) (Double.parseDouble(a[1]) * 1e9); return false;
            case "waitWorld":
                if (mc.theWorld == null || mc.thePlayer == null || mc.renderGlobal == null) { pc--; return false; }
                return true;
            case "capture": {
                if (metal189.core.Settings.DISABLED) {
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
                WorldSettings ws = new WorldSettings(seed, WorldSettings.GameType.CREATIVE, true, false, WorldType.DEFAULT);
                ws.enableCommands();
                mc.launchIntegratedServer(a[1], a[1], ws);
                return false;
            }
            case "cmd":
                if (mc.thePlayer != null) mc.thePlayer.sendChatMessage(line.substring(4).trim());
                return true;
            case "look":
                if (mc.thePlayer != null) {
                    mc.thePlayer.rotationYaw = mc.thePlayer.prevRotationYaw = Float.parseFloat(a[1]);
                    mc.thePlayer.rotationPitch = mc.thePlayer.prevRotationPitch = Float.parseFloat(a[2]);
                }
                return true;
            case "gui":
                if ("none".equals(a[1])) mc.displayGuiScreen(null);
                return true;
            case "fps":
                fpsStart = System.nanoTime();
                fpsEnd = fpsStart + (long) (Double.parseDouble(a[1]) * 1e9);
                fpsFrames = 0;
                fpsLabel = a.length > 2 ? a[2] : "run";
                return false;
            case "quit":
                mc.shutdown();
                return false;
            default:
                Native.LOG.warn("metal189-test: unknown command {}", line);
                return true;
        }
    }
}
