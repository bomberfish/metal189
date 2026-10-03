package metal189.shim;

import metal189.gl.GL;

public final class ARBMultitexture {
    private ARBMultitexture() {}
    public static void glActiveTextureARB(int t) { GL.activeTexture(t); }
    public static void glClientActiveTextureARB(int t) { GL.clientActiveTexture(t); }
    public static void glMultiTexCoord2fARB(int t, float s, float tt) { GL.multiTexCoord(t - 0x84C0, s, tt); }
}
