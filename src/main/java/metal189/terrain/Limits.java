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

    private static int serverDistance;
    private static long serverStepAt;
    private static Object serverSeen;

    /**
     * The view distance a singleplayer server takes from the render distance (IntegratedServer.tick,
     * patched). A server generates every chunk in a newly covered radius at once, holding up its
     * tick (and a joining player): 64 chunks is ~16,600 chunks. Up to 32 this is vanilla; past it the
     * server starts at 16 chunks and widens by 2 at most every second, once the players have been sent
     * what it covers, so the world is playable while the far rings generate.
     */
    public static int serverViewDistance(int wanted) {
        MinecraftServer s = MinecraftServer.getServer();
        long now = System.nanoTime();
        if (s != serverSeen) {   // a new world: start over
            serverSeen = s;
            serverDistance = 0;
        }
        if (wanted <= 32) {
            serverDistance = wanted;
            return wanted;
        }
        if (serverDistance < 16 || serverDistance > wanted) {
            serverDistance = Math.min(wanted, 16);
            serverStepAt = now;
        } else if (serverDistance < wanted && now - serverStepAt >= 1_000_000_000L && caughtUp(s)) {
            serverDistance = Math.min(wanted, serverDistance + 2);
            serverStepAt = now;
        }
        return serverDistance;
    }

    /**
     * Whether every player has been sent the chunks the current distance covers, but for the
     * outer ring: a chunk is sent once populated, which needs its neighbours, so the edge waits
     * for the next ring.
     */
    private static boolean caughtUp(MinecraftServer s) {
        if (s == null || s.getConfigurationManager() == null) return true;
        int edge = 8 * (serverDistance + 1) + 64;
        for (net.minecraft.entity.player.EntityPlayerMP p : s.getConfigurationManager().playerEntityList)
            if (p.loadedChunks.size() > edge) return false;
        return true;
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
