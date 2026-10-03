package metal189.platform;

/** Frame limiter used by Display.sync (sleeps coarsely, then yields to the deadline). */
final class Sync {
    private Sync() {}

    private static long next;

    static void sync(int fps) {
        if (fps <= 0) return;
        long period = 1_000_000_000L / fps;
        long now = System.nanoTime();
        if (next == 0 || now - next > period * 4) next = now;
        next += period;
        long wait = next - now;
        if (wait <= 0) return;
        try {
            if (wait > 2_000_000L) Thread.sleep((wait - 1_500_000L) / 1_000_000L);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
        while (System.nanoTime() < next) Thread.yield();
    }
}
