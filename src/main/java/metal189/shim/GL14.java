package metal189.shim;

import metal189.gl.GL;

public final class GL14 {
    private GL14() {}
    public static void glBlendFuncSeparate(int s, int d, int sa, int da) { GL.blendFuncSeparate(s, d, sa, da); }
    public static void glBlendEquation(int e) { GL.blendEquation(e); }
    public static void glBlendColor(float r, float g, float b, float a) {}
}
