package metal189.terrain;

import metal189.config.Config;
import net.minecraft.client.settings.GameSettings;
import net.minecraft.server.MinecraftServer;

/**
 * Render distance past vanilla's 32 chunks, and chunk loading that keeps up with it.
 * Patched in metal189.core.Patches: the integrated server's view radius clamp, the number of
 * chunk builder threads, and the chunks a singleplayer server sends per tick.
 */
public final class Limits {
    private Limits() {}

    /** The video settings slider's top end (vanilla: 32 with a 64-bit Java and 1 GB, else 16). */
    public static void apply() {
        GameSettings.Options.RENDER_DISTANCE.setValueMax(Math.max(16, Config.maxRenderDistance));
        GameSettings gs = net.minecraft.client.Minecraft.getMinecraft().gameSettings;
        if (gs != null && gs.renderDistanceChunks > Config.maxRenderDistance) gs.renderDistanceChunks = Config.maxRenderDistance;
    }

    /** PlayerManager.setPlayerViewRadius's upper clamp (vanilla 32). */
    public static int maxViewRadius() {
        return Math.max(32, Config.maxRenderDistance);
    }

    /** ChunkRenderDispatcher's builder threads (vanilla 2): half the cores, 2 to 6. */
    public static int builderThreads() {
        return Math.max(2, Math.min(6, Runtime.getRuntime().availableProcessors() / 2));
    }

    /** ChunkRenderDispatcher's build buffers (vanilla 5: three more than threads). */
    public static int builderBuffers() {
        return builderThreads() + 3;
    }

    /**
     * Chunk columns a player is sent per server tick (vanilla 10, 200 a second): a singleplayer
     * server sends over a local channel, so far render distances fill in proportionally faster.
     */
    public static int chunksPerTick() {
        MinecraftServer s = MinecraftServer.getServer();
        if (s == null || !s.isSinglePlayer()) return 10;
        return Math.max(10, Config.maxRenderDistance);
    }
}
