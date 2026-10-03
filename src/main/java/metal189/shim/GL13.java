package metal189.shim;

import metal189.gl.GL;

public final class GL13 {
    private GL13() {}
    public static void glActiveTexture(int t) { GL.activeTexture(t); }
    public static void glClientActiveTexture(int t) { GL.clientActiveTexture(t); }
    public static void glMultiTexCoord2f(int t, float s, float tt) { GL.multiTexCoord(t - 0x84C0, s, tt); }
    public static void glMultiTexCoord2d(int t, double s, double tt) { GL.multiTexCoord(t - 0x84C0, (float) s, (float) tt); }
}
