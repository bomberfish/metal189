package metal189.engine;

/** Command-stream opcodes and payload sizes (words, excluding header). Mirrors native/src/commands.h. */
public final class Cmd {
    private Cmd() {}

    public static final int NOP = 0;
    public static final int STATE_PIPE = 2;      // 9: blend, srcRGB, dstRGB, srcA, dstA, eq, colorMask, logicOn, logicOp
    public static final int STATE_DEPTH = 3;     // 4: test, func, mask, stencil
    public static final int STATE_RASTER = 4;    // 8: cull, cullFace, frontFace, polyFill, factor f, units f, lineWidth f, flat
    public static final int STATE_FRAG = 5;      // 13: alphaTest, alphaFunc, ref f, fog, mode, distMode, start f, end f, density f, color 4f
    public static final int STATE_UNITS = 6;     // 3 * 31 (see Draw.writeUnits)
    public static final int STATE_TEXGEN = 7;    // 37: bits, mode[4], objPlane[16] f, eyePlane[16] f
    public static final int STATE_LIGHT = 8;     // 33: lighting, lightBits, colorMat, colorMatMode, normFlags, pos[2][4], diff[2][4], amb[2][4], model[4]
    public static final int STATE_ATTRIB = 9;    // 15: color 4f, normal 3f, tex0 4f, tex1 4f
    public static final int STATE_VIEWPORT = 10; // 9: vp x y w h, scissor on, sc x y w h
    public static final int MATRIX = 11;         // 17: which (0 mv, 1 proj, 2+u texture u), 16 f
    public static final int DRAW = 12;           // 5: prim, format, count, chunk, offset
    public static final int DRAW_MESH = 13;      // 5: prim, format, mesh, byteOffset, count
    public static final int TARGET = 14;         // 3: fbo, colorTex, depthBuffer   (fbo 0 = screen)
    public static final int CLEAR = 15;          // 7: mask, r f, g f, b f, a f, depth f, stencil
    public static final int COPY_TEX = 16;       // 8: tex, level, xoff, yoff, x, y, w, h
    public static final int PHASE = 17;          // 1: phase id
    public static final int TERRAIN = 18;        // 3 + 4n: layer, format, n, {section, offX f, offY f, offZ f}*n

    public static final int SZ_PIPE = 9, SZ_DEPTH = 4, SZ_RASTER = 8, SZ_FRAG = 13, SZ_UNIT = 31, SZ_UNITS = 3 * 31,
            SZ_TEXGEN = 37, SZ_LIGHT = 33, SZ_ATTRIB = 15, SZ_VIEWPORT = 9;
}
