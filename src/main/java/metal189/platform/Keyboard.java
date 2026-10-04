package metal189.platform;

import java.nio.ByteBuffer;
import org.lwjgl.LWJGLException;

/**
 * Replacement for org.lwjgl.input.Keyboard. Combines LWJGL 2.9.4's Keyboard,
 * MacOSXNativeKeyboard (key map, deferred-release repeat detection) and
 * EventQueue logic verbatim.
 */
public final class Keyboard {
    private Keyboard() {}

    public static final int KEYBOARD_SIZE = 256;
    public static final int EVENT_SIZE = 18;

    // ---- org.lwjgl.input.Keyboard ----
    static boolean created = metal189.core.Settings.reference();
    private static boolean repeat_enabled;
    private static final byte[] keyDownBuffer = new byte[KEYBOARD_SIZE];
    private static final ByteBuffer readBuffer = ByteBuffer.allocate(900);
    private static int ev_key, ev_character;
    private static boolean ev_state, ev_repeat;
    private static long ev_nanos;

    // ---- org.lwjgl.opengl.MacOSXNativeKeyboard ----
    private static final byte[] key_states = new byte[KEYBOARD_SIZE];
    private static final ByteBuffer queue = ByteBuffer.allocate(200 * EVENT_SIZE);
    private static final ByteBuffer event = ByteBuffer.allocate(EVENT_SIZE);
    private static boolean has_deferred_event;
    private static long deferred_nanos;
    private static int deferred_key_code, deferred_character;
    private static byte deferred_key_state;

    static {
        readBuffer.limit(0);
    }

    // ------------------------------------------------------------------
    // MacOSXNativeKeyboard

    static void keyPressed(int keyCode, char character, long nanos) { handleKey(keyCode, (byte) 1, character, nanos); }
    static void keyReleased(int keyCode, char character, long nanos) { handleKey(keyCode, (byte) 0, character, nanos); }

    /** A character typed without a key (iOS on-screen keyboards): KEY_NONE with the character, as LWJGL does for IME input. */
    static void charTyped(char character, long nanos) {
        flushDeferredEvent();
        event.clear();
        event.putInt(0).put((byte) 1).putInt(character).putLong(nanos).put((byte) 0);
        event.flip();
        if (queue.remaining() >= event.remaining()) queue.put(event);
    }

    private static void handleKey(int key_code, byte state, int character, long nanos) {
        if (character == 65535) character = 0;
        if (state == 1) {
            boolean repeat = false;
            if (has_deferred_event) {
                if (nanos == deferred_nanos && deferred_key_code == key_code) {
                    has_deferred_event = false;
                    repeat = true;
                } else {
                    flushDeferredEvent();
                }
            }
            putKeyEvent(key_code, state, character, nanos, repeat);
        } else {
            flushDeferredEvent();
            has_deferred_event = true;
            deferred_nanos = nanos;
            deferred_key_code = key_code;
            deferred_key_state = state;
            deferred_character = character;
        }
    }

    private static void flushDeferredEvent() {
        if (has_deferred_event) {
            putKeyEvent(deferred_key_code, deferred_key_state, deferred_character, deferred_nanos, false);
            has_deferred_event = false;
        }
    }

    private static void putKeyEvent(int key_code, byte state, int character, long nanos, boolean repeat) {
        int mapped = KeyMap.toLwjgl(key_code);
        if (mapped < 0) return; // LWJGL prints "Unrecognized keycode" and drops it
        if (key_states[mapped] == state) repeat = true;
        key_states[mapped] = state;
        event.clear();
        event.putInt(mapped).put(state).putInt(character & 0xFFFF).putLong(nanos).put(repeat ? (byte) 1 : 0);
        event.flip();
        if (queue.remaining() >= event.remaining()) queue.put(event);
    }

    private static void copyEvents(ByteBuffer dest) {
        flushDeferredEvent();
        queue.flip();
        int oldLimit = queue.limit();
        if (dest.remaining() < queue.remaining()) queue.limit(dest.remaining() + queue.position());
        dest.put(queue);
        queue.limit(oldLimit);
        queue.compact();
    }

    // ------------------------------------------------------------------
    // org.lwjgl.input.Keyboard

    public static void create() throws LWJGLException { created = true; }
    public static boolean isCreated() { return created; }
    public static void destroy() { created = false; }

    public static void poll() {
        if (!created) throw new IllegalStateException("Keyboard must be created before you can poll the device");
        flushDeferredEvent();
        System.arraycopy(key_states, 0, keyDownBuffer, 0, KEYBOARD_SIZE);
        readBuffer.compact();
        copyEvents(readBuffer);
        readBuffer.flip();
    }

    private static boolean readNext() {
        if (!readBuffer.hasRemaining()) return false;
        ev_key = readBuffer.getInt() & 0xFF;
        ev_state = readBuffer.get() != 0;
        ev_character = readBuffer.getInt();
        ev_nanos = readBuffer.getLong();
        ev_repeat = readBuffer.get() == 1;
        return true;
    }

    public static boolean next() {
        if (!created) throw new IllegalStateException("Keyboard must be created before you can read events");
        boolean result;
        while ((result = readNext()) && ev_repeat && !repeat_enabled) {
            // skip repeats
        }
        return result;
    }

    public static int getNumKeyboardEvents() {
        int old = readBuffer.position();
        int n = 0;
        int k = ev_key, c = ev_character; boolean s = ev_state, r = ev_repeat; long t = ev_nanos;
        while (readNext() && (!ev_repeat || repeat_enabled)) n++;
        readBuffer.position(old);
        ev_key = k; ev_character = c; ev_state = s; ev_repeat = r; ev_nanos = t;
        return n;
    }

    public static boolean isKeyDown(int key) {
        if (!created) throw new IllegalStateException("Keyboard must be created before you can query key state");
        return keyDownBuffer[key] != 0;
    }

    public static int getEventKey() { return ev_key; }
    public static char getEventCharacter() { return (char) ev_character; }
    public static boolean getEventKeyState() { return ev_state; }
    public static long getEventNanoseconds() { return ev_nanos; }
    public static boolean isRepeatEvent() { return ev_repeat; }
    public static void enableRepeatEvents(boolean enable) { repeat_enabled = enable; }
    public static boolean areRepeatEventsEnabled() { return repeat_enabled; }

    // Pure-Java name tables live in LWJGL's own class; no natives are involved.
    public static String getKeyName(int key) { return org.lwjgl.input.Keyboard.getKeyName(key); }
    public static int getKeyIndex(String name) { return org.lwjgl.input.Keyboard.getKeyIndex(name); }
    public static int getKeyCount() { return org.lwjgl.input.Keyboard.getKeyCount(); }
}
