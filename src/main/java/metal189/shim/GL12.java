package metal189.shim;

/** org.lwjgl.opengl.GL12 stand-in (vanilla only uses its constants). */
public final class GL12 {
    private GL12() {}
    public static void glTexImage3D(int t, int l, int ifmt, int w, int h, int d, int b, int fmt, int type, java.nio.ByteBuffer p) {}
}
