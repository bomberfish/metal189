package metal189.gl;

import java.util.HashMap;
import java.util.Map;
import metal189.engine.Mem;
import metal189.engine.Native;

/**
 * Vertex layouts known to the native side. A layout is a stride plus a list
 * of attributes (usage, GL type, component count, byte offset, normalised).
 * The native vertex shader pulls attributes using this description.
 */
public final class Formats {
    private Formats() {}

    public static final int POS = 0, COLOR = 1, TEX0 = 2, TEX1 = 3, NORMAL = 4;

    private static final Map<String, Integer> ids = new HashMap<String, Integer>();
    private static int next = 1;
    private static final long scratch = Mem.malloc(256);

    /**
     * @param attrs flattened groups of {usage, glType, count, offset, normalized}
     */
    public static synchronized int register(int stride, int[] attrs, int n) {
        StringBuilder sb = new StringBuilder().append(stride);
        for (int i = 0; i < n * 5; i++) sb.append(',').append(attrs[i]);
        String key = sb.toString();
        Integer id = ids.get(key);
        if (id != null) return id;
        int nid = next++;
        for (int i = 0; i < n * 5; i++) Mem.putInt(scratch + i * 4L, attrs[i]);
        Native.formatRegister(nid, stride, scratch, n);
        ids.put(key, nid);
        return nid;
    }
}
