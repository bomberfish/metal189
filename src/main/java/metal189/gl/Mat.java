package metal189.gl;

/** Column-major 4x4 helpers. */
public final class Mat {
    private Mat() {}

    /** dst = inverse(m[o..o+16]); returns false (and identity) if singular. */
    public static boolean invert(float[] m, int o, float[] dst) {
        float a0 = m[o] * m[o + 5] - m[o + 1] * m[o + 4];
        float a1 = m[o] * m[o + 6] - m[o + 2] * m[o + 4];
        float a2 = m[o] * m[o + 7] - m[o + 3] * m[o + 4];
        float a3 = m[o + 1] * m[o + 6] - m[o + 2] * m[o + 5];
        float a4 = m[o + 1] * m[o + 7] - m[o + 3] * m[o + 5];
        float a5 = m[o + 2] * m[o + 7] - m[o + 3] * m[o + 6];
        float b0 = m[o + 8] * m[o + 13] - m[o + 9] * m[o + 12];
        float b1 = m[o + 8] * m[o + 14] - m[o + 10] * m[o + 12];
        float b2 = m[o + 8] * m[o + 15] - m[o + 11] * m[o + 12];
        float b3 = m[o + 9] * m[o + 14] - m[o + 10] * m[o + 13];
        float b4 = m[o + 9] * m[o + 15] - m[o + 11] * m[o + 13];
        float b5 = m[o + 10] * m[o + 15] - m[o + 11] * m[o + 14];
        float det = a0 * b5 - a1 * b4 + a2 * b3 + a3 * b2 - a4 * b1 + a5 * b0;
        if (det == 0f) {
            for (int i = 0; i < 16; i++) dst[i] = (i % 5 == 0) ? 1f : 0f;
            return false;
        }
        float inv = 1f / det;
        dst[0] = (m[o + 5] * b5 - m[o + 6] * b4 + m[o + 7] * b3) * inv;
        dst[1] = (-m[o + 1] * b5 + m[o + 2] * b4 - m[o + 3] * b3) * inv;
        dst[2] = (m[o + 13] * a5 - m[o + 14] * a4 + m[o + 15] * a3) * inv;
        dst[3] = (-m[o + 9] * a5 + m[o + 10] * a4 - m[o + 11] * a3) * inv;
        dst[4] = (-m[o + 4] * b5 + m[o + 6] * b2 - m[o + 7] * b1) * inv;
        dst[5] = (m[o] * b5 - m[o + 2] * b2 + m[o + 3] * b1) * inv;
        dst[6] = (-m[o + 12] * a5 + m[o + 14] * a2 - m[o + 15] * a1) * inv;
        dst[7] = (m[o + 8] * a5 - m[o + 10] * a2 + m[o + 11] * a1) * inv;
        dst[8] = (m[o + 4] * b4 - m[o + 5] * b2 + m[o + 7] * b0) * inv;
        dst[9] = (-m[o] * b4 + m[o + 1] * b2 - m[o + 3] * b0) * inv;
        dst[10] = (m[o + 12] * a4 - m[o + 13] * a2 + m[o + 15] * a0) * inv;
        dst[11] = (-m[o + 8] * a4 + m[o + 9] * a2 - m[o + 11] * a0) * inv;
        dst[12] = (-m[o + 4] * b3 + m[o + 5] * b1 - m[o + 6] * b0) * inv;
        dst[13] = (m[o] * b3 - m[o + 1] * b1 + m[o + 2] * b0) * inv;
        dst[14] = (-m[o + 12] * a3 + m[o + 13] * a1 - m[o + 14] * a0) * inv;
        dst[15] = (m[o + 8] * a3 - m[o + 9] * a1 + m[o + 10] * a0) * inv;
        return true;
    }
}
