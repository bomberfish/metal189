package metal189.shim;

import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import metal189.gl.GL;

/** org.lwjgl.util.glu.GLU stand-in. Pure-math helpers delegate to LWJGL; matrix helpers use metal189 state. */
public final class GLU {
    private GLU() {}

    public static String gluErrorString(int error) { return org.lwjgl.util.glu.GLU.gluErrorString(error); }

    public static void gluPerspective(float fovy, float aspect, float zNear, float zFar) { GL.cur().perspective(fovy, aspect, zNear, zFar); }

    public static void gluOrtho2D(float l, float r, float b, float t) { GL.cur().ortho(l, r, b, t, -1, 1); }

    public static boolean gluUnProject(float wx, float wy, float wz, FloatBuffer model, FloatBuffer proj, IntBuffer vp, FloatBuffer out) {
        return org.lwjgl.util.glu.GLU.gluUnProject(wx, wy, wz, model, proj, vp, out);
    }

    public static boolean gluProject(float ox, float oy, float oz, FloatBuffer model, FloatBuffer proj, IntBuffer vp, FloatBuffer out) {
        return org.lwjgl.util.glu.GLU.gluProject(ox, oy, oz, model, proj, vp, out);
    }

    public static void gluLookAt(float ex, float ey, float ez, float cx, float cy, float cz, float ux, float uy, float uz) {
        float fx = cx - ex, fy = cy - ey, fz = cz - ez;
        float fl = (float) Math.sqrt(fx * fx + fy * fy + fz * fz);
        fx /= fl; fy /= fl; fz /= fl;
        float sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
        float sl = (float) Math.sqrt(sx * sx + sy * sy + sz * sz);
        sx /= sl; sy /= sl; sz /= sl;
        float vx = sy * fz - sz * fy, vy = sz * fx - sx * fz, vz = sx * fy - sy * fx;
        float[] m = {sx, vx, -fx, 0, sy, vy, -fy, 0, sz, vz, -fz, 0, 0, 0, 0, 1};
        GL.cur().mult(m, 0);
        GL.cur().translate(-ex, -ey, -ez);
    }
}
