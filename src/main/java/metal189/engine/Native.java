package metal189.engine;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import org.apache.commons.io.IOUtils;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/** JNI entry points into libmetal189.dylib. */
public final class Native {
    public static final Logger LOG = LogManager.getLogger("metal189");

    private Native() {}

    private static boolean loaded;

    /** Loads the dylib (from -Dmetal189.nativeDir or the mod jar) and binds natives. */
    public static synchronized void load() {
        if (loaded) return;
        File lib = locate("libmetal189.dylib");
        System.load(lib.getAbsolutePath());
        register();
        loaded = true;
        LOG.info("Loaded native library from {}", lib);
    }

    /** Reads the compiled shader library bytes. */
    public static byte[] readShaderLibrary() throws IOException {
        String dir = System.getProperty("metal189.nativeDir");
        if (dir != null) {
            File f = new File(dir, "metal189.metallib");
            InputStream in = new java.io.FileInputStream(f);
            try { return IOUtils.toByteArray(in); } finally { in.close(); }
        }
        InputStream in = Native.class.getResourceAsStream("/natives/metal189.metallib");
        if (in == null) throw new IOException("metal189.metallib missing from jar");
        try { return IOUtils.toByteArray(in); } finally { in.close(); }
    }

    private static File locate(String name) {
        String dir = System.getProperty("metal189.nativeDir");
        if (dir != null) return new File(dir, name);
        try {
            InputStream in = Native.class.getResourceAsStream("/natives/" + name);
            if (in == null) throw new IllegalStateException(name + " missing from jar");
            byte[] data;
            try { data = IOUtils.toByteArray(in); } finally { in.close(); }
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            StringBuilder sb = new StringBuilder();
            for (byte b : md.digest(data)) sb.append(String.format("%02x", b));
            File cache = new File(System.getProperty("user.home"), "Library/Caches/metal189/" + sb.substring(0, 16));
            File out = new File(cache, name);
            if (!out.isFile() || out.length() != data.length) {
                cache.mkdirs();
                File tmp = new File(cache, name + ".tmp");
                OutputStream os = new FileOutputStream(tmp);
                try { os.write(data); } finally { os.close(); }
                if (!tmp.renameTo(out)) throw new IOException("rename failed: " + out);
            }
            return out;
        } catch (Exception e) {
            throw new RuntimeException("Unable to extract " + name, e);
        }
    }

    private static native void register();

    // ---- engine ----
    public static native int init(long metallib, long metallibSize, int flags);
    public static native String deviceName();
    public static native void beginFrame(long infoAddr);
    public static native void endFrame(long cmds, int len);
    public static native void waitIdle();
    public static native void submitPartial(long cmds, int len);
    public static native void arenaGrow(long infoAddr, int minBytes);

    // ---- resources ----
    public static native void formatRegister(int id, int stride, long attrs, int count);
    public static native void texImage(int id, int level, int internalFormat, int w, int h, int format, int type, long data, int rowLength);
    public static native void texSubImage(int id, int level, int x, int y, int w, int h, int format, int type, long data, int rowLength);
    public static native void texParams(int id, int minFilter, int magFilter, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float aniso);
    public static native void texDelete(int id);
    public static native void texGetImage(int id, int level, int format, int type, long dst, int size);
    public static native void readPixels(int fbo, int x, int y, int w, int h, int format, int type, long dst, int size);
    public static native int meshCreate(long data, int size);
    public static native void meshDelete(int id);
    public static native void renderbufferStorage(int id, int internalFormat, int w, int h);
    public static native boolean capture(int which, String path);
    public static native void refModeInstall();
    public static native void setOption(int key, int value);
    public static native void sectionUpload(int id, int layer, long data, int bytes, int vertexCount, int x, int y, int z);
    public static native void sectionDelete(int id);
    public static native void advSetEnabled(boolean on);
    public static native void advSetFeatures(int flags);
    public static native void advSetTables(long materials, long emissions);
    public static native boolean rtSupported();

    // ---- window / input ----
    public static native boolean windowCreate(int w, int h, String title, int flags);
    public static native void windowDestroy();
    public static native void windowSetTitle(String title);
    public static native void windowSetResizable(boolean resizable);
    public static native void windowSetSize(int w, int h);
    public static native void windowSetFullscreen(boolean fullscreen);
    public static native void windowSetVSync(boolean vsync);
    public static native int pollEvents(long addr, int max);
    public static native void windowInfo(long addr);
    public static native void cursorGrab(boolean grab);
    public static native void cursorSetPos(int x, int y);
    public static native void desktopMode(long addr);
}
