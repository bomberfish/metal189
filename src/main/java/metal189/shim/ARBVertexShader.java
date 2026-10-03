package metal189.shim;

import metal189.gl.Programs;

public final class ARBVertexShader {
    private ARBVertexShader() {}
    public static int glGetAttribLocationARB(int p, CharSequence n) { return Programs.getAttribLocation(p, n); }
}
