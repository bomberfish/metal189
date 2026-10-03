package metal189.gl;

import static metal189.gl.GL.*;

import metal189.engine.Cmd;
import metal189.engine.CmdBuffer;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.engine.Native;

/** Turns the current GL state plus geometry into command-stream records. */
public final class Draw {
    private Draw() {}

    private static int mvVersion = -1, projVersion = -1;
    private static final int[] texVersion = new int[3];
    private static boolean texIdentity0 = true, texIdentity1 = true, texIdentity2 = true;

    static {
        for (int i = 0; i < 3; i++) texVersion[i] = -1;
    }

    /** Forces every state group and matrix to be re-sent (start of each frame). */
    public static void invalidate() {
        GL.dirty = -1;
        mvVersion = projVersion = -1;
        texVersion[0] = texVersion[1] = texVersion[2] = -1;
        Targets.invalidate();
    }

    /** Emits all dirty state groups and changed matrices. */
    public static void flush() {
        CmdBuffer c = Engine.cmd;
        Targets.flush();
        int d = GL.dirty;
        if (d != 0) {
            if ((d & D_PIPE) != 0) writePipe(c);
            if ((d & D_DEPTH) != 0) {
                long p = c.begin(Cmd.STATE_DEPTH, 1 + Cmd.SZ_DEPTH);
                Mem.putInt(p, depthTest ? 1 : 0);
                Mem.putInt(p + 4, depthFunc);
                Mem.putInt(p + 8, depthMask ? 1 : 0);
                Mem.putInt(p + 12, stencilTest ? 1 : 0);
            }
            if ((d & D_RASTER) != 0) {
                long p = c.begin(Cmd.STATE_RASTER, 1 + Cmd.SZ_RASTER);
                Mem.putInt(p, cull ? 1 : 0);
                Mem.putInt(p + 4, cullFace);
                Mem.putInt(p + 8, frontFace);
                Mem.putInt(p + 12, polyOffsetFill ? 1 : 0);
                Mem.putFloat(p + 16, polyFactor);
                Mem.putFloat(p + 20, polyUnits);
                Mem.putFloat(p + 24, lineWidth);
                Mem.putInt(p + 28, shadeModel == 0x1D00 ? 1 : 0);
            }
            if ((d & D_FRAG) != 0) {
                long p = c.begin(Cmd.STATE_FRAG, 1 + Cmd.SZ_FRAG);
                Mem.putInt(p, alphaTest ? 1 : 0);
                Mem.putInt(p + 4, alphaFunc);
                Mem.putFloat(p + 8, alphaRef);
                Mem.putInt(p + 12, fog ? 1 : 0);
                Mem.putInt(p + 16, fogMode);
                Mem.putInt(p + 20, fogDistanceMode);
                Mem.putFloat(p + 24, fogStart);
                Mem.putFloat(p + 28, fogEnd);
                Mem.putFloat(p + 32, fogDensity);
                for (int i = 0; i < 4; i++) Mem.putFloat(p + 36 + i * 4, fogColor[i]);
            }
            if ((d & D_UNITS) != 0) writeUnits(c);
            if ((d & D_TEXGEN) != 0) {
                long p = c.begin(Cmd.STATE_TEXGEN, 1 + Cmd.SZ_TEXGEN);
                boolean[] g = texGen[0];
                Mem.putInt(p, (g[0] ? 1 : 0) | (g[1] ? 2 : 0) | (g[2] ? 4 : 0) | (g[3] ? 8 : 0));
                for (int i = 0; i < 4; i++) Mem.putInt(p + 4 + i * 4, texGenMode[0][i]);
                for (int i = 0; i < 16; i++) Mem.putFloat(p + 20 + i * 4, objPlane[0][i]);
                for (int i = 0; i < 16; i++) Mem.putFloat(p + 84 + i * 4, eyePlane[0][i]);
            }
            if ((d & D_LIGHT) != 0) writeLight(c);
            if ((d & D_ATTRIB) != 0) {
                long p = c.begin(Cmd.STATE_ATTRIB, 1 + Cmd.SZ_ATTRIB);
                Mem.putFloat(p, colR); Mem.putFloat(p + 4, colG); Mem.putFloat(p + 8, colB); Mem.putFloat(p + 12, colA);
                Mem.putFloat(p + 16, nrmX); Mem.putFloat(p + 20, nrmY); Mem.putFloat(p + 24, nrmZ);
                for (int i = 0; i < 4; i++) Mem.putFloat(p + 28 + i * 4, texCoord[0][i]);
                for (int i = 0; i < 4; i++) Mem.putFloat(p + 44 + i * 4, texCoord[1][i]);
            }
            if ((d & D_VIEWPORT) != 0) {
                long p = c.begin(Cmd.STATE_VIEWPORT, 1 + Cmd.SZ_VIEWPORT);
                Mem.putInt(p, vpX); Mem.putInt(p + 4, vpY); Mem.putInt(p + 8, vpW); Mem.putInt(p + 12, vpH);
                Mem.putInt(p + 16, scissorTest ? 1 : 0);
                Mem.putInt(p + 20, scX); Mem.putInt(p + 24, scY); Mem.putInt(p + 28, scW); Mem.putInt(p + 32, scH);
            }
            GL.dirty = 0;
        }
        if (modelview.version != mvVersion) { writeMatrix(c, 0, modelview); mvVersion = modelview.version; }
        if (projection.version != projVersion) { writeMatrix(c, 1, projection); projVersion = projection.version; }
        for (int u = 0; u < 3; u++) {
            MatrixStack t = texMatrix[u];
            if (t.version != texVersion[u]) { writeMatrix(c, 2 + u, t); texVersion[u] = t.version; }
        }
    }

    private static void writePipe(CmdBuffer c) {
        long p = c.begin(Cmd.STATE_PIPE, 1 + Cmd.SZ_PIPE);
        Mem.putInt(p, blend ? 1 : 0);
        Mem.putInt(p + 4, blendSrcRGB);
        Mem.putInt(p + 8, blendDstRGB);
        Mem.putInt(p + 12, blendSrcA);
        Mem.putInt(p + 16, blendDstA);
        Mem.putInt(p + 20, blendEq);
        Mem.putInt(p + 24, colorMask);
        Mem.putInt(p + 28, logicOpEnable ? 1 : 0);
        Mem.putInt(p + 32, logicOp);
        Mem.putFloat(p + 36, GL.blendColorR);
        Mem.putFloat(p + 40, GL.blendColorG);
        Mem.putFloat(p + 44, GL.blendColorB);
        Mem.putFloat(p + 48, GL.blendColorA);
    }

    private static void writeUnits(CmdBuffer c) {
        long p = c.begin(Cmd.STATE_UNITS, 1 + Cmd.SZ_UNITS);
        for (int u = 0; u < 3; u++) {
            long q = p + (long) u * Cmd.SZ_UNIT * 4;
            TexEnv e = env[u];
            Mem.putInt(q, tex2D[u] ? 1 : 0);
            Mem.putInt(q + 4, boundTex[u]);
            Mem.putInt(q + 8, e.mode);
            Mem.putInt(q + 12, e.combineRGB);
            Mem.putInt(q + 16, e.combineA);
            for (int i = 0; i < 3; i++) {
                Mem.putInt(q + 20 + i * 4, e.srcRGB[i]);
                Mem.putInt(q + 32 + i * 4, e.srcA[i]);
                Mem.putInt(q + 44 + i * 4, e.opRGB[i]);
                Mem.putInt(q + 56 + i * 4, e.opA[i]);
            }
            for (int i = 0; i < 4; i++) Mem.putFloat(q + 68 + i * 4, e.color[i]);
            Mem.putFloat(q + 84, e.rgbScale);
            Mem.putFloat(q + 88, e.alphaScale);
            Textures.writeSampler(boundTex[u], q + 92);
        }
    }

    private static void writeLight(CmdBuffer c) {
        long p = c.begin(Cmd.STATE_LIGHT, 1 + Cmd.SZ_LIGHT);
        Mem.putInt(p, lighting ? 1 : 0);
        Mem.putInt(p + 4, (lightOn[0] ? 1 : 0) | (lightOn[1] ? 2 : 0));
        Mem.putInt(p + 8, colorMaterial ? 1 : 0);
        Mem.putInt(p + 12, colorMaterialMode);
        Mem.putInt(p + 16, (normalize ? 1 : 0) | (rescaleNormal ? 2 : 0));
        long q = p + 20;
        for (int l = 0; l < 2; l++) for (int i = 0; i < 4; i++) Mem.putFloat(q + (l * 4 + i) * 4, lightPos[l][i]);
        q += 32;
        for (int l = 0; l < 2; l++) for (int i = 0; i < 4; i++) Mem.putFloat(q + (l * 4 + i) * 4, lightDiffuse[l][i]);
        q += 32;
        for (int l = 0; l < 2; l++) for (int i = 0; i < 4; i++) Mem.putFloat(q + (l * 4 + i) * 4, lightAmbient[l][i]);
        q += 32;
        for (int i = 0; i < 4; i++) Mem.putFloat(q + i * 4, lightModelAmbient[i]);
    }

    private static void writeMatrix(CmdBuffer c, int which, MatrixStack s) {
        long p = c.begin(Cmd.MATRIX, 18);
        Mem.putInt(p, which);
        float[] a = s.array();
        int o = s.top();
        for (int i = 0; i < 16; i++) Mem.putFloat(p + 4 + i * 4, a[o + i]);
    }

    // ------------------------------------------------------------------
    // geometry

    /** Copies {@code bytes} of vertex data into the frame arena and draws it. */
    public static void arrays(int prim, int format, long src, int vertexCount, int bytes) {
        if (vertexCount <= 0) return;
        if (Lists.compiling != null) {
            Lists.compiling.addDraw(prim, format, src, vertexCount, bytes);
            return;
        }
        long off = arenaAlloc(bytes, bytes / vertexCount);
        Mem.copy(src, Engine.arenaBase + off, bytes);
        flush();
        long p = Engine.cmd.begin(Cmd.DRAW, 6);
        Mem.putInt(p, prim);
        Mem.putInt(p + 4, format);
        Mem.putInt(p + 8, vertexCount);
        Mem.putInt(p + 12, Engine.arenaChunk);
        Mem.putInt(p + 16, (int) off);
    }

    /** Draws {@code count} vertices of a static mesh starting at byte offset {@code byteOffset}. */
    public static void mesh(int prim, int format, int mesh, int byteOffset, int count) {
        if (count <= 0) return;
        flush();
        long p = Engine.cmd.begin(Cmd.DRAW_MESH, 6);
        Mem.putInt(p, prim);
        Mem.putInt(p + 4, format);
        Mem.putInt(p + 8, mesh);
        Mem.putInt(p + 12, byteOffset);
        Mem.putInt(p + 16, count);
    }

    /**
     * Reserves space in the current arena chunk at a multiple of {@code stride},
     * so the native side can address it by vertex index and merge consecutive
     * draws. Grows to a new chunk when full.
     */
    public static long arenaAlloc(int bytes, int stride) {
        long off = Engine.arenaOffset;
        long rem = off % stride;
        if (rem != 0) off += stride - rem;
        if (off + bytes > Engine.arenaCapacity) {
            Engine.growArena(bytes);
            off = 0;
        }
        Engine.arenaOffset = off + bytes;
        return off;
    }

    static void phase(int id) {
        long p = Engine.cmd.begin(Cmd.PHASE, 2);
        Mem.putInt(p, id);
    }

    static void unused() { Native.LOG.debug(""); }
}
