package metal189.gl;

/**
 * A GL-style matrix stack (column-major float[16] entries). Operations
 * post-multiply the top matrix exactly like the fixed-function pipeline, in
 * single precision, so values read back through glGetFloat match GL.
 */
public final class MatrixStack {
    private final float[] stack;
    private final int capacity;
    private int depth; // index of the top entry
    /** Incremented on every change; lets consumers cache uploads. */
    public int version;
    private boolean identity = true;

    public MatrixStack(int capacity) {
        this.capacity = capacity;
        stack = new float[capacity * 16];
        loadIdentity();
    }

    public int top() { return depth * 16; }
    public float[] array() { return stack; }
    public boolean isIdentity() { return identity; }

    public void push() {
        if (depth + 1 >= capacity) return; // GL_STACK_OVERFLOW: ignored like GL
        System.arraycopy(stack, depth * 16, stack, (depth + 1) * 16, 16);
        depth++;
    }

    public void pop() {
        if (depth == 0) return; // GL_STACK_UNDERFLOW
        depth--;
        version++;
        identity = checkIdentity();
    }

    public void loadIdentity() {
        int o = depth * 16;
        for (int i = 0; i < 16; i++) stack[o + i] = (i % 5 == 0) ? 1f : 0f;
        identity = true;
        version++;
    }

    public void load(float[] m, int off) {
        System.arraycopy(m, off, stack, depth * 16, 16);
        identity = checkIdentity();
        version++;
    }

    public void get(float[] dst, int off) { System.arraycopy(stack, depth * 16, dst, off, 16); }

    /** top = top * m (m column-major) */
    public void mult(float[] m, int mo) {
        float[] s = stack;
        int o = depth * 16;
        float a00 = s[o], a01 = s[o + 4], a02 = s[o + 8], a03 = s[o + 12];
        float a10 = s[o + 1], a11 = s[o + 5], a12 = s[o + 9], a13 = s[o + 13];
        float a20 = s[o + 2], a21 = s[o + 6], a22 = s[o + 10], a23 = s[o + 14];
        float a30 = s[o + 3], a31 = s[o + 7], a32 = s[o + 11], a33 = s[o + 15];
        for (int c = 0; c < 4; c++) {
            float b0 = m[mo + c * 4], b1 = m[mo + c * 4 + 1], b2 = m[mo + c * 4 + 2], b3 = m[mo + c * 4 + 3];
            s[o + c * 4] = a00 * b0 + a01 * b1 + a02 * b2 + a03 * b3;
            s[o + c * 4 + 1] = a10 * b0 + a11 * b1 + a12 * b2 + a13 * b3;
            s[o + c * 4 + 2] = a20 * b0 + a21 * b1 + a22 * b2 + a23 * b3;
            s[o + c * 4 + 3] = a30 * b0 + a31 * b1 + a32 * b2 + a33 * b3;
        }
        identity = false;
        version++;
    }

    public void translate(float x, float y, float z) {
        float[] s = stack;
        int o = depth * 16;
        s[o + 12] += s[o] * x + s[o + 4] * y + s[o + 8] * z;
        s[o + 13] += s[o + 1] * x + s[o + 5] * y + s[o + 9] * z;
        s[o + 14] += s[o + 2] * x + s[o + 6] * y + s[o + 10] * z;
        s[o + 15] += s[o + 3] * x + s[o + 7] * y + s[o + 11] * z;
        identity = false;
        version++;
    }

    public void scale(float x, float y, float z) {
        float[] s = stack;
        int o = depth * 16;
        for (int i = 0; i < 4; i++) {
            s[o + i] *= x;
            s[o + 4 + i] *= y;
            s[o + 8 + i] *= z;
        }
        identity = false;
        version++;
    }

    private final float[] tmp = new float[16];

    /** glRotatef: angle in degrees around (x, y, z), normalised like GL. */
    public void rotate(float angle, float x, float y, float z) {
        float len = (float) Math.sqrt(x * x + y * y + z * z);
        if (len == 0f) return;
        if (len != 1f) { x /= len; y /= len; z /= len; }
        double rad = Math.toRadians(angle);
        float c = (float) Math.cos(rad), s = (float) Math.sin(rad), t = 1f - c;
        float[] r = tmp;
        r[0] = x * x * t + c;     r[4] = x * y * t - z * s; r[8] = x * z * t + y * s;  r[12] = 0;
        r[1] = y * x * t + z * s; r[5] = y * y * t + c;     r[9] = y * z * t - x * s;  r[13] = 0;
        r[2] = x * z * t - y * s; r[6] = y * z * t + x * s; r[10] = z * z * t + c;     r[14] = 0;
        r[3] = 0;                 r[7] = 0;                 r[11] = 0;                 r[15] = 1;
        mult(r, 0);
    }

    public void ortho(double l, double r, double b, double t, double n, double f) {
        float[] m = tmp;
        java.util.Arrays.fill(m, 0f);
        m[0] = (float) (2.0 / (r - l));
        m[5] = (float) (2.0 / (t - b));
        m[10] = (float) (-2.0 / (f - n));
        m[12] = (float) (-(r + l) / (r - l));
        m[13] = (float) (-(t + b) / (t - b));
        m[14] = (float) (-(f + n) / (f - n));
        m[15] = 1f;
        mult(m, 0);
    }

    public void frustum(double l, double r, double b, double t, double n, double f) {
        float[] m = tmp;
        java.util.Arrays.fill(m, 0f);
        m[0] = (float) (2 * n / (r - l));
        m[5] = (float) (2 * n / (t - b));
        m[8] = (float) ((r + l) / (r - l));
        m[9] = (float) ((t + b) / (t - b));
        m[10] = (float) (-(f + n) / (f - n));
        m[11] = -1f;
        m[14] = (float) (-2 * f * n / (f - n));
        mult(m, 0);
    }

    /** gluPerspective, computed like LWJGL's org.lwjgl.util.glu.Project. */
    public void perspective(float fovy, float aspect, float zNear, float zFar) {
        float radians = fovy / 2 * (float) Math.PI / 180; // float math, as LWJGL's GLU
        float deltaZ = zFar - zNear;
        float sine = (float) Math.sin(radians);
        if (deltaZ == 0 || sine == 0 || aspect == 0) return;
        float cotangent = (float) Math.cos(radians) / sine;
        float[] m = tmp;
        java.util.Arrays.fill(m, 0f);
        m[0] = cotangent / aspect;
        m[5] = cotangent;
        m[10] = -(zFar + zNear) / deltaZ;
        m[11] = -1;
        m[14] = -2 * zNear * zFar / deltaZ;
        m[15] = 0;
        mult(m, 0);
    }

    private boolean checkIdentity() {
        int o = depth * 16;
        for (int i = 0; i < 16; i++) if (stack[o + i] != ((i % 5 == 0) ? 1f : 0f)) return false;
        return true;
    }
}
