package metal189.platform;

import java.nio.ByteBuffer;
import metal189.core.Settings;
import metal189.engine.Native;
import org.lwjgl.LWJGLException;
import org.lwjgl.input.Cursor;

/**
 * Replacement for org.lwjgl.input.Mouse. Combines LWJGL 2.9.4's Mouse,
 * MacOSXNativeMouse and EventQueue logic verbatim (including truncation of
 * fractional deltas and the event-skip after grab changes) so aiming feels
 * identical to vanilla.
 */
public final class Mouse {
    private Mouse() {}

    // ---- org.lwjgl.input.Mouse ----
    static boolean created;
    private static boolean isGrabbed;
    private static int x, y, absolute_x, absolute_y, dx, dy, dwheel;
    private static int grab_x, grab_y;
    private static int event_x, event_y, last_event_raw_x, last_event_raw_y;
    private static int eventButton, event_dx, event_dy, event_dwheel;
    private static boolean eventState;
    private static long event_nanos;
    private static final int BUTTON_COUNT = 3;
    private static final byte[] buttons = new byte[BUTTON_COUNT];
    private static final int EVENT_SIZE = 22;
    private static final ByteBuffer readBuffer = ByteBuffer.allocate(1100);

    // ---- org.lwjgl.opengl.MacOSXNativeMouse ----
    private static boolean nGrabbed;
    private static float accum_dx, accum_dy;
    private static int accum_dz;
    private static float last_x, last_y;
    private static int skip_event;
    private static final byte[] nButtons = new byte[3];
    private static final ByteBuffer queue = ByteBuffer.allocate(200 * EVENT_SIZE); // EventQueue
    private static final ByteBuffer event = ByteBuffer.allocate(EVENT_SIZE);

    static {
        readBuffer.limit(0);
    }

    // ------------------------------------------------------------------
    // MacOSXNativeMouse (called from Input.drain in arrival order)

    static void nativeSetButton(int button, int state, long nanos) {
        if (button < 0 || button >= nButtons.length) return;
        nButtons[button] = (byte) state;
        putMouseEvent((byte) button, (byte) state, 0, nanos);
    }

    static void nativeMouseMoved(float mx, float my, float mdx, float mdy, float dz, long nanos) {
        if (skip_event > 0) {
            --skip_event;
            if (skip_event == 0) {
                last_x = mx;
                last_y = my;
            }
            return;
        }
        if (dz != 0.0f) {
            if (mdy == 0.0f) mdy = mdx;
            int wheel_amount = (int) (mdy * 120.0f);
            accum_dz += wheel_amount;
            putMouseEvent((byte) -1, (byte) 0, wheel_amount, nanos);
        } else if (nGrabbed) {
            if (mdx != 0.0f || mdy != 0.0f) {
                putMouseEventWithCoords((byte) -1, (byte) 0, (int) mdx, (int) (-mdy), 0, nanos);
                accum_dx += mdx;
                accum_dy += -mdy;
            }
        } else {
            float ddx = mx - last_x, ddy = my - last_y;
            accum_dx += ddx;
            accum_dy += -ddy;
            last_x = mx;
            last_y = my;
            putMouseEventWithCoords((byte) -1, (byte) 0, (int) mx, (int) my, 0, nanos);
        }
    }

    private static void putMouseEvent(byte button, byte state, int dz, long nanos) {
        if (nGrabbed) putMouseEventWithCoords(button, state, 0, 0, dz, nanos);
        else putMouseEventWithCoords(button, state, (int) last_x, (int) last_y, dz, nanos);
    }

    private static void putMouseEventWithCoords(byte button, byte state, int c1, int c2, int dz, long nanos) {
        event.clear();
        event.put(button).put(state).putInt(c1).putInt(c2).putInt(dz).putLong(nanos);
        event.flip();
        if (queue.remaining() >= event.remaining()) queue.put(event);
    }

    private static void nativePoll(int[] coords, byte[] out) {
        if (nGrabbed) {
            coords[0] = (int) accum_dx;
            coords[1] = (int) accum_dy;
        } else {
            coords[0] = (int) last_x;
            coords[1] = (int) last_y;
        }
        coords[2] = accum_dz;
        accum_dz = 0;
        accum_dx = accum_dy = 0f;
        System.arraycopy(nButtons, 0, out, 0, out.length);
    }

    private static void nativeSetGrabbed(boolean grab) {
        nGrabbed = grab;
        if (!Settings.NO_GRAB) Native.cursorGrab(grab);
        skip_event = 1;
        accum_dy = accum_dx = 0f;
    }

    private static void copyEvents(ByteBuffer dest) {
        queue.flip();
        int oldLimit = queue.limit();
        if (dest.remaining() < queue.remaining()) queue.limit(dest.remaining() + queue.position());
        dest.put(queue);
        queue.limit(oldLimit);
        queue.compact();
    }

    // ------------------------------------------------------------------
    // org.lwjgl.input.Mouse

    private static final int[] coord = new int[3];

    public static void create() throws LWJGLException { created = true; }
    public static boolean isCreated() { return created; }
    public static void destroy() { created = false; }

    public static void poll() {
        if (!created) throw new IllegalStateException("Mouse must be created before you can poll it");
        nativePoll(coord, buttons);
        int c1 = coord[0], c2 = coord[1], w = coord[2];
        if (isGrabbed) {
            dx += c1; dy += c2; x += c1; y += c2; absolute_x += c1; absolute_y += c2;
        } else {
            dx = c1 - absolute_x;
            dy = c2 - absolute_y;
            absolute_x = x = c1;
            absolute_y = y = c2;
        }
        x = Math.min(Display.getWidth() - 1, Math.max(0, x));
        y = Math.min(Display.getHeight() - 1, Math.max(0, y));
        dwheel += w;
        readBuffer.compact();
        copyEvents(readBuffer);
        readBuffer.flip();
    }

    public static boolean next() {
        if (!created) throw new IllegalStateException("Mouse must be created before you can read events");
        if (!readBuffer.hasRemaining()) return false;
        eventButton = readBuffer.get();
        eventState = readBuffer.get() != 0;
        if (isGrabbed) {
            event_dx = readBuffer.getInt();
            event_dy = readBuffer.getInt();
            event_x += event_dx;
            event_y += event_dy;
            last_event_raw_x = event_x;
            last_event_raw_y = event_y;
        } else {
            int nx = readBuffer.getInt(), ny = readBuffer.getInt();
            event_dx = nx - last_event_raw_x;
            event_dy = ny - last_event_raw_y;
            event_x = nx;
            event_y = ny;
            last_event_raw_x = nx;
            last_event_raw_y = ny;
        }
        event_x = Math.min(Display.getWidth() - 1, Math.max(0, event_x));
        event_y = Math.min(Display.getHeight() - 1, Math.max(0, event_y));
        event_dwheel = readBuffer.getInt();
        event_nanos = readBuffer.getLong();
        return true;
    }

    public static void setGrabbed(boolean grab) {
        boolean grabbed = isGrabbed;
        isGrabbed = grab;
        if (!created) return;
        if (grab && !grabbed) {
            grab_x = x;
            grab_y = y;
        } else if (!grab && grabbed) {
            if (!Settings.NO_GRAB) Native.cursorSetPos(grab_x, grab_y);
        }
        nativeSetGrabbed(grab);
        poll();
        event_x = x;
        event_y = y;
        last_event_raw_x = x;
        last_event_raw_y = y;
        dwheel = dy = dx = 0;
        readBuffer.position(readBuffer.limit());
    }

    public static void setCursorPosition(int nx, int ny) {
        if (!created) throw new IllegalStateException("Mouse is not created");
        x = event_x = nx;
        y = event_y = ny;
        if (!isGrabbed) {
            if (!Settings.NO_GRAB) Native.cursorSetPos(x, y);
        } else {
            grab_x = nx;
            grab_y = ny;
        }
    }

    public static int getEventButton() { return eventButton; }
    public static boolean getEventButtonState() { return eventState; }
    public static int getEventDX() { return event_dx; }
    public static int getEventDY() { return event_dy; }
    public static int getEventX() { return event_x; }
    public static int getEventY() { return event_y; }
    public static int getEventDWheel() { return event_dwheel; }
    public static long getEventNanoseconds() { return event_nanos; }
    public static int getX() { return x; }
    public static int getY() { return y; }
    public static int getDX() { int r = dx; dx = 0; return r; }
    public static int getDY() { int r = dy; dy = 0; return r; }
    public static int getDWheel() { int r = dwheel; dwheel = 0; return r; }
    public static int getButtonCount() { return BUTTON_COUNT; }
    public static boolean hasWheel() { return true; }
    public static boolean isGrabbed() { return isGrabbed; }

    public static boolean isButtonDown(int button) {
        if (!created) throw new IllegalStateException("Mouse must be created before you can poll the button state");
        if (button >= BUTTON_COUNT || button < 0) return false;
        return buttons[button] == 1;
    }

    public static String getButtonName(int button) { return button >= 0 && button < 16 ? "BUTTON" + button : null; }

    public static int getButtonIndex(String name) {
        if (name != null && name.startsWith("BUTTON")) {
            try { return Integer.parseInt(name.substring(6)); } catch (NumberFormatException ignored) {}
        }
        return -1;
    }

    /** Tests on a shared desktop report the pointer as inside so the game never re-grabs it. */
    public static boolean isInsideWindow() { return Settings.NO_GRAB || Input.mouseInside; }

    public static boolean isClipMouseCoordinatesToWindow() { return true; }
    public static void setClipMouseCoordinatesToWindow(boolean clip) {}
    public static Cursor setNativeCursor(Cursor c) throws LWJGLException { return null; }
    public static Cursor getNativeCursor() { return null; }
    public static void updateCursor() {}
}
