package metal189.platform;

import metal189.engine.Mem;
import metal189.engine.Native;

/**
 * Drains native window/input events. In LWJGL 2 these callbacks run on the
 * AppKit thread as they arrive; here they are replayed in order at poll time,
 * which yields the same state at every Display.update().
 */
final class Input {
    private Input() {}

    static final int EV_KEY = 1, EV_MOUSE_BUTTON = 2, EV_MOUSE_MOVE = 3, EV_FOCUS = 5, EV_RESIZE = 6,
            EV_CLOSE = 7, EV_MOUSE_INSIDE = 8, EV_SCALE = 10;
    private static final int EVENT_SIZE = 40, BATCH = 512;
    private static final long buf = Mem.malloc((long) EVENT_SIZE * BATCH);
    static boolean mouseInside;

    static void drain() {
        while (true) {
            int n = Native.pollEvents(buf, BATCH);
            for (int i = 0; i < n; i++) {
                long e = buf + (long) i * EVENT_SIZE;
                int type = Mem.getInt(e), a = Mem.getInt(e + 4), b = Mem.getInt(e + 8), c = Mem.getInt(e + 12);
                float f0 = Mem.getFloat(e + 16), f1 = Mem.getFloat(e + 20), f2 = Mem.getFloat(e + 24), f3 = Mem.getFloat(e + 28);
                long t = Mem.getLong(e + 32);
                switch (type) {
                    case EV_KEY:
                        if (c != 0) Keyboard.keyPressed(a, (char) b, t);
                        else Keyboard.keyReleased(a, (char) b, t);
                        break;
                    case EV_MOUSE_BUTTON:
                        Mouse.nativeSetButton(a, c, t);
                        break;
                    case EV_MOUSE_MOVE:
                        Mouse.nativeMouseMoved(f0, f1, f2, f3, c, t);
                        break;
                    case EV_MOUSE_INSIDE:
                        mouseInside = a != 0;
                        break;
                    default:
                        break;
                }
            }
            if (n < BATCH) break;
        }
    }

    /** Display.processMessages(): native update, then LWJGL's pollDevices(). */
    static void poll() {
        drain();
        if (Mouse.created) Mouse.poll();
        if (Keyboard.created) Keyboard.poll();
    }
}
