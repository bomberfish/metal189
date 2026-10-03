package metal189.shim;

import metal189.gl.GL;

/** org.lwjgl.util.glu.Project stand-in (LWJGL's version calls real GL). */
public final class Project {
    private Project() {}
    public static void gluPerspective(float fovy, float aspect, float zNear, float zFar) { GL.cur().perspective(fovy, aspect, zNear, zFar); }
    public static void gluLookAt(float ex, float ey, float ez, float cx, float cy, float cz, float ux, float uy, float uz) { GLU.gluLookAt(ex, ey, ez, cx, cy, cz, ux, uy, uz); }
    public static void gluPickMatrix(float x, float y, float dx, float dy, java.nio.IntBuffer vp) {}
    public static boolean gluUnProject(float wx, float wy, float wz, java.nio.FloatBuffer model, java.nio.FloatBuffer proj, java.nio.IntBuffer vp, java.nio.FloatBuffer out) {
        return GLU.gluUnProject(wx, wy, wz, model, proj, vp, out);
    }
    public static boolean gluProject(float ox, float oy, float oz, java.nio.FloatBuffer model, java.nio.FloatBuffer proj, java.nio.IntBuffer vp, java.nio.FloatBuffer out) {
        return GLU.gluProject(ox, oy, oz, model, proj, vp, out);
    }
}
