package metal189.shim;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import metal189.gl.Programs;

public final class GL20 {
    private GL20() {}
    public static int glCreateShader(int type) { return Programs.createShader(type); }
    public static void glShaderSource(int s, ByteBuffer src) { Programs.shaderSource(s, src); }
    public static void glShaderSource(int s, CharSequence src) { Programs.shaderSource(s, src); }
    public static void glCompileShader(int s) {}
    public static int glGetShaderi(int s, int p) { return Programs.getParameter(s, p); }
    public static String glGetShaderInfoLog(int s, int max) { return ""; }
    public static void glDeleteShader(int s) { Programs.delete(s); }
    public static int glCreateProgram() { return Programs.createProgram(); }
    public static void glAttachShader(int p, int s) { Programs.attach(p, s); }
    public static void glDetachShader(int p, int s) {}
    public static void glLinkProgram(int p) { Programs.link(p); }
    public static void glValidateProgram(int p) {}
    public static int glGetProgrami(int p, int n) { return Programs.getParameter(p, n); }
    public static String glGetProgramInfoLog(int p, int max) { return ""; }
    public static void glUseProgram(int p) { Programs.use(p); }
    public static void glDeleteProgram(int p) { Programs.delete(p); }
    public static int glGetUniformLocation(int p, CharSequence n) { return Programs.getUniformLocation(p, n); }
    public static int glGetAttribLocation(int p, CharSequence n) { return Programs.getAttribLocation(p, n); }
    public static void glBindAttribLocation(int p, int i, CharSequence n) {}
    public static void glUniform1i(int l, int v) {}
    public static void glUniform1f(int l, float v) {}
    public static void glUniform2f(int l, float a, float b) {}
    public static void glUniform3f(int l, float a, float b, float c) {}
    public static void glUniform4f(int l, float a, float b, float c, float d) {}
    public static void glUniform1(int l, FloatBuffer v) {}
    public static void glUniform2(int l, FloatBuffer v) {}
    public static void glUniform3(int l, FloatBuffer v) {}
    public static void glUniform4(int l, FloatBuffer v) {}
    public static void glUniform1(int l, IntBuffer v) {}
    public static void glUniform2(int l, IntBuffer v) {}
    public static void glUniform3(int l, IntBuffer v) {}
    public static void glUniform4(int l, IntBuffer v) {}
    public static void glUniformMatrix2(int l, boolean t, FloatBuffer v) {}
    public static void glUniformMatrix3(int l, boolean t, FloatBuffer v) {}
    public static void glUniformMatrix4(int l, boolean t, FloatBuffer v) {}
    public static void glEnableVertexAttribArray(int i) {}
    public static void glDisableVertexAttribArray(int i) {}
    public static void glVertexAttribPointer(int i, int size, int type, boolean norm, int stride, ByteBuffer b) {}
    public static void glVertexAttribPointer(int i, int size, int type, boolean norm, int stride, long off) {}
    public static void glDrawBuffers(int b) {}
    public static void glDrawBuffers(IntBuffer b) {}
    // separate front/back stencil state is applied to both faces
    public static void glStencilFuncSeparate(int face, int func, int ref, int mask) { metal189.gl.GL.stencilFunc(func, ref, mask); }
    public static void glStencilOpSeparate(int face, int sfail, int dpfail, int dppass) { metal189.gl.GL.stencilOp(sfail, dpfail, dppass); }
    public static void glStencilMaskSeparate(int face, int mask) { metal189.gl.GL.stencilMask(mask); }
}
