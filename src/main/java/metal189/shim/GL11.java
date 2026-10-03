package metal189.shim;

import java.nio.ByteBuffer;
import java.nio.DoubleBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;
import metal189.gl.Arrays;
import metal189.gl.AttribStack;
import metal189.gl.GL;
import metal189.gl.Immediate;
import metal189.gl.Lists;
import metal189.gl.Matrices;
import metal189.gl.Query;
import metal189.gl.Textures;

/** Signature-compatible stand-in for org.lwjgl.opengl.GL11. */
public final class GL11 {
    private GL11() {}

    // ---- capabilities ----
    public static void glEnable(int cap) { GL.setCap(cap, true); }
    public static void glDisable(int cap) { GL.setCap(cap, false); }
    public static boolean glIsEnabled(int cap) { return GL.isEnabled(cap); }
    public static void glEnableClientState(int a) { Arrays.enableClientState(a, true); }
    public static void glDisableClientState(int a) { Arrays.enableClientState(a, false); }

    // ---- blend / depth / raster ----
    public static void glBlendFunc(int s, int d) { GL.blendFunc(s, d); }
    public static void glAlphaFunc(int f, float ref) { GL.alphaFunc(f, ref); }
    public static void glDepthFunc(int f) { GL.depthFunc(f); }
    public static void glDepthMask(boolean m) { GL.depthMask(m); }
    public static void glColorMask(boolean r, boolean g, boolean b, boolean a) { GL.colorMask(r, g, b, a); }
    public static void glCullFace(int m) { GL.cullFace(m); }
    public static void glFrontFace(int m) { GL.frontFace(m); }
    public static void glPolygonOffset(float f, float u) { GL.polygonOffset(f, u); }
    public static void glLineWidth(float w) { GL.lineWidth(w); }
    public static void glPointSize(float s) {}
    public static void glPolygonMode(int face, int mode) {}
    public static void glShadeModel(int m) { GL.shadeModel(m); }
    public static void glLogicOp(int op) { GL.logicOp(op); }
    public static void glHint(int target, int mode) {}
    public static void glLineStipple(int f, short p) {}
    public static void glStencilFunc(int f, int ref, int mask) {}
    public static void glStencilOp(int f, int zf, int zp) {}
    public static void glStencilMask(int m) {}
    public static void glClearStencil(int s) { GL.clearStencil = s; }

    // ---- fog / lighting ----
    public static void glFogi(int p, int v) { GL.fogi(p, v); }
    public static void glFogf(int p, float v) { GL.fogf(p, v); }
    public static void glFog(int p, FloatBuffer v) { GL.fogv(p, v); }
    public static void glLight(int l, int p, FloatBuffer v) { GL.light(l, p, v); }
    public static void glLightf(int l, int p, float v) {}
    public static void glLighti(int l, int p, int v) {}
    public static void glLightModel(int p, FloatBuffer v) { GL.lightModel(p, v); }
    public static void glLightModeli(int p, int v) {}
    public static void glLightModelf(int p, float v) {}
    public static void glColorMaterial(int face, int mode) { GL.colorMaterial(face, mode); }
    public static void glMaterial(int face, int p, FloatBuffer v) {}
    public static void glMaterialf(int face, int p, float v) {}

    // ---- current attributes ----
    public static void glColor4f(float r, float g, float b, float a) { GL.color(r, g, b, a); }
    public static void glColor3f(float r, float g, float b) { GL.color(r, g, b, 1f); }
    public static void glColor4d(double r, double g, double b, double a) { GL.color((float) r, (float) g, (float) b, (float) a); }
    public static void glColor3d(double r, double g, double b) { GL.color((float) r, (float) g, (float) b, 1f); }
    public static void glColor4ub(byte r, byte g, byte b, byte a) { GL.color((r & 255) / 255f, (g & 255) / 255f, (b & 255) / 255f, (a & 255) / 255f); }
    public static void glColor3ub(byte r, byte g, byte b) { GL.color((r & 255) / 255f, (g & 255) / 255f, (b & 255) / 255f, 1f); }
    public static void glColor4b(byte r, byte g, byte b, byte a) { GL.color(r / 127f, g / 127f, b / 127f, a / 127f); }
    public static void glNormal3f(float x, float y, float z) { GL.normal(x, y, z); }
    public static void glNormal3d(double x, double y, double z) { GL.normal((float) x, (float) y, (float) z); }
    public static void glNormal3b(byte x, byte y, byte z) { GL.normal(x / 127f, y / 127f, z / 127f); }
    public static void glNormal3i(int x, int y, int z) { GL.normal(x, y, z); }
    public static void glTexCoord2f(float s, float t) { GL.multiTexCoord(0, s, t); }
    public static void glTexCoord2d(double s, double t) { GL.multiTexCoord(0, (float) s, (float) t); }
    public static void glTexCoord2i(int s, int t) { GL.multiTexCoord(0, s, t); }
    public static void glTexCoord1f(float s) { GL.multiTexCoord(0, s, 0f); }

    // ---- immediate mode ----
    public static void glBegin(int mode) { Immediate.begin(mode); }
    public static void glEnd() { Immediate.end(); }
    public static void glVertex3f(float x, float y, float z) { Immediate.vertex(x, y, z); }
    public static void glVertex2f(float x, float y) { Immediate.vertex(x, y, 0f); }
    public static void glVertex3d(double x, double y, double z) { Immediate.vertex((float) x, (float) y, (float) z); }
    public static void glVertex2d(double x, double y) { Immediate.vertex((float) x, (float) y, 0f); }
    public static void glVertex2i(int x, int y) { Immediate.vertex(x, y, 0f); }
    public static void glVertex3i(int x, int y, int z) { Immediate.vertex(x, y, z); }
    public static void glRectf(float x1, float y1, float x2, float y2) {
        Immediate.begin(0x0009); // GL_POLYGON
        Immediate.vertex(x1, y1, 0); Immediate.vertex(x2, y1, 0); Immediate.vertex(x2, y2, 0); Immediate.vertex(x1, y2, 0);
        Immediate.end();
    }
    public static void glRecti(int x1, int y1, int x2, int y2) { glRectf(x1, y1, x2, y2); }

    // ---- arrays ----
    public static void glVertexPointer(int size, int type, int stride, ByteBuffer b) { Arrays.vertexPointer(size, type, stride, b); }
    public static void glVertexPointer(int size, int stride, FloatBuffer b) { Arrays.vertexPointer(size, 0x1406, stride, b); }
    public static void glVertexPointer(int size, int stride, DoubleBuffer b) { Arrays.vertexPointer(size, 0x140A, stride, b); }
    public static void glVertexPointer(int size, int stride, IntBuffer b) { Arrays.vertexPointer(size, 0x1404, stride, b); }
    public static void glVertexPointer(int size, int stride, ShortBuffer b) { Arrays.vertexPointer(size, 0x1402, stride, b); }
    public static void glVertexPointer(int size, int type, int stride, long off) { Arrays.vertexPointer(size, type, stride, off); }
    public static void glColorPointer(int size, int type, int stride, ByteBuffer b) { Arrays.colorPointer(size, type, stride, b); }
    public static void glColorPointer(int size, boolean unsigned, int stride, ByteBuffer b) { Arrays.colorPointer(size, unsigned ? 0x1401 : 0x1400, stride, b); }
    public static void glColorPointer(int size, int stride, FloatBuffer b) { Arrays.colorPointer(size, 0x1406, stride, b); }
    public static void glColorPointer(int size, int type, int stride, long off) { Arrays.colorPointer(size, type, stride, off); }
    public static void glTexCoordPointer(int size, int type, int stride, ByteBuffer b) { Arrays.texCoordPointer(size, type, stride, b); }
    public static void glTexCoordPointer(int size, int stride, FloatBuffer b) { Arrays.texCoordPointer(size, 0x1406, stride, b); }
    public static void glTexCoordPointer(int size, int stride, ShortBuffer b) { Arrays.texCoordPointer(size, 0x1402, stride, b); }
    public static void glTexCoordPointer(int size, int type, int stride, long off) { Arrays.texCoordPointer(size, type, stride, off); }
    public static void glNormalPointer(int type, int stride, ByteBuffer b) { Arrays.normalPointer(type, stride, b); }
    public static void glNormalPointer(int stride, FloatBuffer b) { Arrays.normalPointer(0x1406, stride, b); }
    public static void glNormalPointer(int stride, ByteBuffer b) { Arrays.normalPointer(0x1400, stride, b); }
    public static void glNormalPointer(int type, int stride, long off) { Arrays.normalPointer(type, stride, off); }
    public static void glDrawArrays(int mode, int first, int count) { if (!metal189.gl.Programs.blocksDraw()) Arrays.drawArrays(mode, first, count); }

    // ---- display lists ----
    public static int glGenLists(int range) { return Lists.gen(range); }
    public static void glDeleteLists(int list, int range) { Lists.delete(list, range); }
    public static boolean glIsList(int list) { return Lists.isList(list); }
    public static void glNewList(int list, int mode) { Lists.newList(list, mode); }
    public static void glEndList() { Lists.endList(); }
    public static void glCallList(int list) { Lists.call(list); }

    // ---- matrices ----
    public static void glMatrixMode(int m) { GL.matrixMode(m); }
    public static void glLoadIdentity() { if (!Matrices.record(Matrices.LOAD_IDENTITY)) GL.cur().loadIdentity(); }
    public static void glPushMatrix() { if (!Matrices.record(Matrices.PUSH)) GL.cur().push(); }
    public static void glPopMatrix() { if (!Matrices.record(Matrices.POP)) GL.cur().pop(); }
    public static void glTranslatef(float x, float y, float z) { if (!Matrices.record(Matrices.TRANSLATE, x, y, z)) GL.cur().translate(x, y, z); }
    public static void glTranslated(double x, double y, double z) { glTranslatef((float) x, (float) y, (float) z); }
    public static void glScalef(float x, float y, float z) { if (!Matrices.record(Matrices.SCALE, x, y, z)) GL.cur().scale(x, y, z); }
    public static void glScaled(double x, double y, double z) { glScalef((float) x, (float) y, (float) z); }
    public static void glRotatef(float a, float x, float y, float z) { if (!Matrices.record(Matrices.ROTATE, a, x, y, z)) GL.cur().rotate(a, x, y, z); }
    public static void glRotated(double a, double x, double y, double z) { glRotatef((float) a, (float) x, (float) y, (float) z); }
    public static void glMultMatrix(FloatBuffer m) { Matrices.mult(m); }
    public static void glLoadMatrix(FloatBuffer m) { Matrices.load(m); }
    public static void glOrtho(double l, double r, double b, double t, double n, double f) { GL.cur().ortho(l, r, b, t, n, f); }
    public static void glFrustum(double l, double r, double b, double t, double n, double f) { GL.cur().frustum(l, r, b, t, n, f); }

    // ---- textures ----
    public static int glGenTextures() { return Textures.gen(); }
    public static void glGenTextures(IntBuffer out) { for (int i = out.position(); i < out.limit(); i++) out.put(i, Textures.gen()); }
    public static void glDeleteTextures(int t) { Textures.delete(t); }
    public static void glDeleteTextures(IntBuffer b) { for (int i = b.position(); i < b.limit(); i++) Textures.delete(b.get(i)); }
    public static boolean glIsTexture(int t) { return Textures.isTexture(t); }
    public static void glBindTexture(int target, int t) { Textures.bind(target, t); }
    public static void glTexParameteri(int target, int p, int v) { Textures.parameteri(target, p, v); }
    public static void glTexParameterf(int target, int p, float v) { Textures.parameterf(target, p, v); }
    public static void glTexParameter(int target, int p, IntBuffer v) { Textures.parameteri(target, p, v.get(v.position())); }
    public static void glTexParameter(int target, int p, FloatBuffer v) { Textures.parameterf(target, p, v.get(v.position())); }
    public static int glGetTexParameteri(int target, int p) { return Textures.getParameteri(p); }
    public static int glGetTexLevelParameteri(int target, int level, int p) { return Textures.getLevelParameteri(target, level, p); }
    public static void glTexImage2D(int t, int l, int ifmt, int w, int h, int border, int fmt, int type, ByteBuffer d) { Textures.texImage2D(t, l, ifmt, w, h, fmt, type, d); }
    public static void glTexImage2D(int t, int l, int ifmt, int w, int h, int border, int fmt, int type, IntBuffer d) { Textures.texImage2D(t, l, ifmt, w, h, fmt, type, d); }
    public static void glTexImage2D(int t, int l, int ifmt, int w, int h, int border, int fmt, int type, FloatBuffer d) { Textures.texImage2D(t, l, ifmt, w, h, fmt, type, d); }
    public static void glTexImage2D(int t, int l, int ifmt, int w, int h, int border, int fmt, int type, ShortBuffer d) { Textures.texImage2D(t, l, ifmt, w, h, fmt, type, d); }
    public static void glTexSubImage2D(int t, int l, int x, int y, int w, int h, int fmt, int type, ByteBuffer d) { Textures.texSubImage2D(t, l, x, y, w, h, fmt, type, d); }
    public static void glTexSubImage2D(int t, int l, int x, int y, int w, int h, int fmt, int type, IntBuffer d) { Textures.texSubImage2D(t, l, x, y, w, h, fmt, type, d); }
    public static void glTexSubImage2D(int t, int l, int x, int y, int w, int h, int fmt, int type, FloatBuffer d) { Textures.texSubImage2D(t, l, x, y, w, h, fmt, type, d); }
    public static void glCopyTexSubImage2D(int t, int l, int xo, int yo, int x, int y, int w, int h) { Textures.copyTexSubImage2D(l, xo, yo, x, y, w, h); }
    public static void glGetTexImage(int t, int l, int fmt, int type, IntBuffer out) { Textures.getTexImage(l, fmt, type, out); }
    public static void glGetTexImage(int t, int l, int fmt, int type, ByteBuffer out) { Textures.getTexImage(l, fmt, type, out); }
    public static void glTexEnvi(int t, int p, int v) { GL.texEnvi(t, p, v); }
    public static void glTexEnvf(int t, int p, float v) { GL.texEnvf(t, p, v); }
    public static void glTexEnv(int t, int p, FloatBuffer v) { GL.texEnvv(t, p, v); }
    public static void glTexGeni(int c, int p, int v) { GL.texGeni(c, p, v); }
    public static void glTexGen(int c, int p, FloatBuffer v) { GL.texGenv(c, p, v); }
    public static void glPixelStorei(int p, int v) { Query.pixelStore(p, v); }
    public static void glPixelStoref(int p, float v) { Query.pixelStore(p, (int) v); }

    // ---- framebuffer ----
    public static void glViewport(int x, int y, int w, int h) { GL.viewport(x, y, w, h); }
    public static void glScissor(int x, int y, int w, int h) { GL.scissor(x, y, w, h); }
    public static void glClear(int mask) { Query.clear(mask); }
    public static void glClearColor(float r, float g, float b, float a) { GL.clearR = r; GL.clearG = g; GL.clearB = b; GL.clearA = a; }
    public static void glClearDepth(double d) { GL.clearDepth = d; }
    public static void glReadPixels(int x, int y, int w, int h, int fmt, int type, IntBuffer out) { Query.readPixels(x, y, w, h, fmt, type, out); }
    public static void glReadPixels(int x, int y, int w, int h, int fmt, int type, ByteBuffer out) { Query.readPixels(x, y, w, h, fmt, type, out); }
    public static void glReadPixels(int x, int y, int w, int h, int fmt, int type, FloatBuffer out) { Query.readPixels(x, y, w, h, fmt, type, out); }
    public static void glDrawBuffer(int b) {}
    public static void glReadBuffer(int b) {}

    // ---- state queries ----
    public static int glGetError() { return 0; }
    public static String glGetString(int name) { return Query.getString(name); }
    public static int glGetInteger(int p) { return Query.getInteger(p); }
    public static void glGetInteger(int p, IntBuffer out) { Query.getInteger(p, out); }
    public static float glGetFloat(int p) { FloatBuffer b = Matrices.scratch(); Query.getFloat(p, b); return b.get(0); }
    public static void glGetFloat(int p, FloatBuffer out) { Query.getFloat(p, out); }
    public static boolean glGetBoolean(int p) { return GL.isEnabled(p) || Query.getInteger(p) != 0; }
    public static void glGetBoolean(int p, ByteBuffer out) { out.put(out.position(), (byte) (glGetBoolean(p) ? 1 : 0)); }
    public static void glPushAttrib(int mask) { AttribStack.push(mask); }
    public static void glPopAttrib() { AttribStack.pop(); }
    public static void glPushClientAttrib(int mask) {}
    public static void glPopClientAttrib() {}
    public static void glFlush() {}
    public static void glFinish() {}
}
