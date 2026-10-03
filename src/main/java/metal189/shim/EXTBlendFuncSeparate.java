package metal189.shim;

import metal189.gl.GL;

public final class EXTBlendFuncSeparate {
    private EXTBlendFuncSeparate() {}
    public static void glBlendFuncSeparateEXT(int s, int d, int sa, int da) { GL.blendFuncSeparate(s, d, sa, da); }
}
