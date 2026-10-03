package metal189.shim;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import metal189.gl.Programs;

public final class ARBShaderObjects {
    private ARBShaderObjects() {}
    public static int glCreateShaderObjectARB(int type) { return Programs.createShader(type); }
    public static void glShaderSourceARB(int s, ByteBuffer src) { Programs.shaderSource(s, src); }
    public static void glShaderSourceARB(int s, CharSequence src) { Programs.shaderSource(s, src); }
    public static void glCompileShaderARB(int s) {}
    public static int glCreateProgramObjectARB() { return Programs.createProgram(); }
    public static void glAttachObjectARB(int p, int s) { Programs.attach(p, s); }
    public static void glLinkProgramARB(int p) { Programs.link(p); }
    public static void glUseProgramObjectARB(int p) { Programs.use(p); }
    public static void glDeleteObjectARB(int o) { Programs.delete(o); }
    public static int glGetObjectParameteriARB(int o, int p) { return Programs.getParameter(o, p); }
    public static String glGetInfoLogARB(int o, int max) { return ""; }
    public static int glGetUniformLocationARB(int p, CharSequence n) { return Programs.getUniformLocation(p, n); }
    public static void glUniform1iARB(int l, int v) {}
    public static void glUniform1fARB(int l, float v) {}
    public static void glUniform1ARB(int l, FloatBuffer v) {}
    public static void glUniform2ARB(int l, FloatBuffer v) {}
    public static void glUniform3ARB(int l, FloatBuffer v) {}
    public static void glUniform4ARB(int l, FloatBuffer v) {}
    public static void glUniform1ARB(int l, IntBuffer v) {}
    public static void glUniform2ARB(int l, IntBuffer v) {}
    public static void glUniform3ARB(int l, IntBuffer v) {}
    public static void glUniform4ARB(int l, IntBuffer v) {}
    public static void glUniformMatrix2ARB(int l, boolean t, FloatBuffer v) {}
    public static void glUniformMatrix3ARB(int l, boolean t, FloatBuffer v) {}
    public static void glUniformMatrix4ARB(int l, boolean t, FloatBuffer v) {}
}
