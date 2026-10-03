package metal189.gl;

import static org.lwjgl.opengl.GL11.*;

import java.nio.FloatBuffer;

/**
 * The fixed-function state vanilla code drives through GL11. State is grouped
 * so that draws only ship the groups that changed (see {@link Draw#flush}).
 */
public final class GL {
    private GL() {}

    // ---- dirty groups (mirrored in native/src/commands.h) ----
    public static final int D_PIPE = 1, D_DEPTH = 2, D_RASTER = 4, D_FRAG = 8, D_UNITS = 16,
            D_TEXGEN = 32, D_LIGHT = 64, D_ATTRIB = 128, D_VIEWPORT = 256;
    public static int dirty = -1;

    // ---- pipeline / blend ----
    public static boolean blend;
    public static int blendSrcRGB = GL_ONE, blendDstRGB = GL_ZERO, blendSrcA = GL_ONE, blendDstA = GL_ZERO;
    public static int blendEq = 0x8006; // GL_FUNC_ADD
    public static float blendColorR, blendColorG, blendColorB, blendColorA; // GL_BLEND_COLOR
    public static int colorMask = 0xF;
    public static boolean logicOpEnable;
    public static int logicOp = GL_COPY;

    // ---- depth ----
    public static boolean depthTest;
    public static int depthFunc = GL_LESS;
    public static boolean depthMask = true;
    public static boolean stencilTest;

    // ---- raster ----
    public static boolean cull;
    public static int cullFace = GL_BACK, frontFace = GL_CCW;
    public static boolean polyOffsetFill, polyOffsetLine;
    public static float polyFactor, polyUnits;
    public static float lineWidth = 1f;
    public static int shadeModel = GL_SMOOTH;

    // ---- fragment fixed function ----
    public static boolean alphaTest;
    public static int alphaFunc = GL_ALWAYS;
    public static float alphaRef;
    public static boolean fog;
    public static int fogMode = GL_EXP;
    public static float fogStart = 0f, fogEnd = 1f, fogDensity = 1f;
    public static final float[] fogColor = new float[4];
    public static int fogDistanceMode = 0x855C; // GL_EYE_PLANE_ABSOLUTE_NV

    // ---- texture units ----
    public static final int UNITS = 8;
    public static int activeUnit, clientActiveUnit;
    public static final boolean[] tex2D = new boolean[UNITS];
    public static final int[] boundTex = new int[UNITS];
    public static final TexEnv[] env = new TexEnv[UNITS];

    // ---- texgen (per unit, S T R Q) ----
    public static final boolean[][] texGen = new boolean[UNITS][4];
    public static final int[][] texGenMode = new int[UNITS][4];
    public static final float[][] objPlane = new float[UNITS][16];
    public static final float[][] eyePlane = new float[UNITS][16];

    // ---- lighting ----
    public static boolean lighting, colorMaterial, normalize, rescaleNormal;
    public static int colorMaterialFace = GL_FRONT_AND_BACK, colorMaterialMode = GL_AMBIENT_AND_DIFFUSE;
    public static final boolean[] lightOn = new boolean[8];
    public static final float[][] lightPos = new float[8][4];
    public static final float[][] lightDiffuse = new float[8][4];
    public static final float[][] lightAmbient = new float[8][4];
    public static final float[][] lightSpecular = new float[8][4];
    public static final float[] lightModelAmbient = {0.2f, 0.2f, 0.2f, 1f};

    // ---- current vertex attributes ----
    public static float colR = 1, colG = 1, colB = 1, colA = 1;
    public static float nrmX = 0, nrmY = 0, nrmZ = 1;
    public static final float[][] texCoord = new float[UNITS][4];

    // ---- viewport / scissor / clear ----
    public static int vpX, vpY, vpW = 1, vpH = 1;
    public static boolean scissorTest;
    public static int scX, scY, scW = 1, scH = 1;
    public static float clearR, clearG, clearB, clearA;
    public static double clearDepth = 1.0;
    public static int clearStencil;

    // ---- matrices ----
    public static final MatrixStack modelview = new MatrixStack(64);
    public static final MatrixStack projection = new MatrixStack(16);
    public static final MatrixStack[] texMatrix = new MatrixStack[UNITS];
    public static int matrixMode = GL_MODELVIEW;
    public static MatrixStack current = modelview;

    // ---- pixel store ----
    public static int unpackRowLength, unpackSkipRows, unpackSkipPixels, unpackAlignment = 4;
    public static int packRowLength, packSkipRows, packSkipPixels, packAlignment = 4;

    static {
        for (int i = 0; i < UNITS; i++) {
            env[i] = new TexEnv();
            texMatrix[i] = new MatrixStack(8);
            texCoord[i][3] = 1f;
            for (int c = 0; c < 4; c++) texGenMode[i][c] = GL_EYE_LINEAR;
            // GL defaults: S plane (1,0,0,0), T plane (0,1,0,0)
            objPlane[i][0] = 1f; objPlane[i][5] = 1f;
            eyePlane[i][0] = 1f; eyePlane[i][5] = 1f;
        }
        for (int i = 0; i < 8; i++) {
            lightPos[i][2] = 1f;
            lightAmbient[i][3] = 1f;
        }
        lightDiffuse[0][0] = lightDiffuse[0][1] = lightDiffuse[0][2] = lightDiffuse[0][3] = 1f;
        lightSpecular[0][0] = lightSpecular[0][1] = lightSpecular[0][2] = lightSpecular[0][3] = 1f;
        for (int i = 1; i < 8; i++) { lightDiffuse[i][3] = 1f; lightSpecular[i][3] = 1f; }
    }

    // ------------------------------------------------------------------
    // enable / disable

    public static void setCap(int cap, boolean on) {
        switch (cap) {
            case GL_BLEND: if (blend != on) { blend = on; dirty |= D_PIPE; } return;
            case GL_ALPHA_TEST: if (alphaTest != on) { alphaTest = on; dirty |= D_FRAG; } return;
            case GL_DEPTH_TEST: if (depthTest != on) { depthTest = on; dirty |= D_DEPTH; } return;
            case GL_CULL_FACE: if (cull != on) { cull = on; dirty |= D_RASTER; } return;
            case GL_FOG: if (fog != on) { fog = on; dirty |= D_FRAG; } return;
            case GL_LIGHTING: if (lighting != on) { lighting = on; dirty |= D_LIGHT; } return;
            case GL_COLOR_MATERIAL: if (colorMaterial != on) { colorMaterial = on; dirty |= D_LIGHT; } return;
            case GL_NORMALIZE: if (normalize != on) { normalize = on; dirty |= D_LIGHT; } return;
            case 0x803A /* GL_RESCALE_NORMAL */: if (rescaleNormal != on) { rescaleNormal = on; dirty |= D_LIGHT; } return;
            case GL_TEXTURE_2D: if (tex2D[activeUnit] != on) { tex2D[activeUnit] = on; dirty |= D_UNITS; } return;
            case GL_POLYGON_OFFSET_FILL: if (polyOffsetFill != on) { polyOffsetFill = on; dirty |= D_RASTER; } return;
            case GL_POLYGON_OFFSET_LINE: if (polyOffsetLine != on) { polyOffsetLine = on; dirty |= D_RASTER; } return;
            case GL_COLOR_LOGIC_OP: if (logicOpEnable != on) { logicOpEnable = on; dirty |= D_PIPE; } return;
            case GL_SCISSOR_TEST: if (scissorTest != on) { scissorTest = on; dirty |= D_VIEWPORT; } return;
            case GL_STENCIL_TEST: stencilTest = on; dirty |= D_DEPTH; return;
            case GL_TEXTURE_GEN_S: case GL_TEXTURE_GEN_T: case GL_TEXTURE_GEN_R: case GL_TEXTURE_GEN_Q: {
                int c = cap - GL_TEXTURE_GEN_S;
                if (texGen[activeUnit][c] != on) { texGen[activeUnit][c] = on; dirty |= D_TEXGEN; }
                return;
            }
            default:
                if (cap >= GL_LIGHT0 && cap < GL_LIGHT0 + 8) {
                    int l = cap - GL_LIGHT0;
                    if (lightOn[l] != on) { lightOn[l] = on; dirty |= D_LIGHT; }
                }
                // GL_DITHER, GL_LINE_SMOOTH, GL_POLYGON_SMOOTH, GL_MULTISAMPLE...: no effect
        }
    }

    public static boolean isEnabled(int cap) {
        switch (cap) {
            case GL_BLEND: return blend;
            case GL_ALPHA_TEST: return alphaTest;
            case GL_DEPTH_TEST: return depthTest;
            case GL_CULL_FACE: return cull;
            case GL_FOG: return fog;
            case GL_LIGHTING: return lighting;
            case GL_COLOR_MATERIAL: return colorMaterial;
            case GL_NORMALIZE: return normalize;
            case 0x803A: return rescaleNormal;
            case GL_TEXTURE_2D: return tex2D[activeUnit];
            case GL_POLYGON_OFFSET_FILL: return polyOffsetFill;
            case GL_COLOR_LOGIC_OP: return logicOpEnable;
            case GL_SCISSOR_TEST: return scissorTest;
            default:
                if (cap >= GL_LIGHT0 && cap < GL_LIGHT0 + 8) return lightOn[cap - GL_LIGHT0];
                return false;
        }
    }

    // ------------------------------------------------------------------
    // simple setters

    public static void blendFunc(int s, int d) { blendFuncSeparate(s, d, s, d); }

    public static void blendFuncSeparate(int s, int d, int sa, int da) {
        if (s != blendSrcRGB || d != blendDstRGB || sa != blendSrcA || da != blendDstA) {
            blendSrcRGB = s; blendDstRGB = d; blendSrcA = sa; blendDstA = da;
            dirty |= D_PIPE;
        }
    }

    public static void blendEquation(int eq) { if (eq != blendEq) { blendEq = eq; dirty |= D_PIPE; } }

    public static void colorMask(boolean r, boolean g, boolean b, boolean a) {
        int m = (r ? 1 : 0) | (g ? 2 : 0) | (b ? 4 : 0) | (a ? 8 : 0);
        if (m != colorMask) { colorMask = m; dirty |= D_PIPE; }
    }

    public static void logicOp(int op) { if (op != logicOp) { logicOp = op; dirty |= D_PIPE; } }

    public static void blendColor(float r, float g, float b, float a) {
        r = Math.max(0f, Math.min(1f, r)); g = Math.max(0f, Math.min(1f, g));
        b = Math.max(0f, Math.min(1f, b)); a = Math.max(0f, Math.min(1f, a));
        if (r != blendColorR || g != blendColorG || b != blendColorB || a != blendColorA) {
            blendColorR = r; blendColorG = g; blendColorB = b; blendColorA = a;
            dirty |= D_PIPE;
        }
    }
    public static void depthFunc(int f) { if (f != depthFunc) { depthFunc = f; dirty |= D_DEPTH; } }
    public static void depthMask(boolean m) { if (m != depthMask) { depthMask = m; dirty |= D_DEPTH; } }
    public static void cullFace(int m) { if (m != cullFace) { cullFace = m; dirty |= D_RASTER; } }
    public static void frontFace(int m) { if (m != frontFace) { frontFace = m; dirty |= D_RASTER; } }

    public static void polygonOffset(float factor, float units) {
        if (factor != polyFactor || units != polyUnits) { polyFactor = factor; polyUnits = units; dirty |= D_RASTER; }
    }

    public static void lineWidth(float w) { if (w != lineWidth) { lineWidth = w; dirty |= D_RASTER; } }
    public static void shadeModel(int m) { if (m != shadeModel) { shadeModel = m; dirty |= D_RASTER; } }

    public static void alphaFunc(int f, float ref) {
        if (f != alphaFunc || ref != alphaRef) { alphaFunc = f; alphaRef = ref; dirty |= D_FRAG; }
    }

    public static void fogi(int pname, int v) {
        if (pname == GL_FOG_MODE) { fogMode = v; dirty |= D_FRAG; }
        else if (pname == 0x855A /* GL_FOG_DISTANCE_MODE_NV */) { fogDistanceMode = v; dirty |= D_FRAG; }
        else fogf(pname, v);
    }

    public static void fogf(int pname, float v) {
        switch (pname) {
            case GL_FOG_DENSITY: fogDensity = v; break;
            case GL_FOG_START: fogStart = v; break;
            case GL_FOG_END: fogEnd = v; break;
            case GL_FOG_MODE: fogMode = (int) v; break;
            default: return;
        }
        dirty |= D_FRAG;
    }

    public static void fogv(int pname, FloatBuffer p) {
        if (pname == GL_FOG_COLOR) {
            int o = p.position();
            for (int i = 0; i < 4; i++) fogColor[i] = p.get(o + i);
            dirty |= D_FRAG;
        } else {
            fogf(pname, p.get(p.position()));
        }
    }

    public static void color(float r, float g, float b, float a) {
        if (Lists.compiling != null && !Immediate.active()) { Lists.compiling.ops.add(new float[] {Lists.OP_COLOR, r, g, b, a}); return; }
        colR = r; colG = g; colB = b; colA = a;
        dirty |= D_ATTRIB;
    }

    public static void normal(float x, float y, float z) {
        if (Lists.compiling != null && !Immediate.active()) { Lists.compiling.ops.add(new float[] {Lists.OP_NORMAL, x, y, z}); return; }
        nrmX = x; nrmY = y; nrmZ = z;
        dirty |= D_ATTRIB;
    }

    public static void multiTexCoord(int unit, float s, float t) {
        float[] tc = texCoord[unit];
        tc[0] = s; tc[1] = t; tc[2] = 0f; tc[3] = 1f;
        dirty |= D_ATTRIB;
    }

    public static void viewport(int x, int y, int w, int h) {
        vpX = x; vpY = y; vpW = w; vpH = h;
        dirty |= D_VIEWPORT;
    }

    public static void scissor(int x, int y, int w, int h) {
        scX = x; scY = y; scW = w; scH = h;
        dirty |= D_VIEWPORT;
    }

    public static void activeTexture(int texUnitEnum) {
        activeUnit = Math.max(0, Math.min(UNITS - 1, texUnitEnum - 0x84C0));
    }

    public static void clientActiveTexture(int texUnitEnum) {
        clientActiveUnit = Math.max(0, Math.min(UNITS - 1, texUnitEnum - 0x84C0));
    }

    public static void matrixMode(int mode) {
        matrixMode = mode;
        switch (mode) {
            case GL_PROJECTION: current = projection; break;
            case GL_TEXTURE: current = texMatrix[activeUnit]; break;
            default: current = modelview; break;
        }
    }

    /** The matrix stack GL_TEXTURE mode refers to follows the active unit. */
    public static MatrixStack cur() {
        return matrixMode == GL_TEXTURE ? texMatrix[activeUnit] : current;
    }

    // ------------------------------------------------------------------
    // lighting

    public static void light(int light, int pname, FloatBuffer p) {
        int l = light - GL_LIGHT0;
        if (l < 0 || l >= 8) return;
        int o = p.position();
        float x = p.get(o), y = p.remaining() > 1 ? p.get(o + 1) : 0, z = p.remaining() > 2 ? p.get(o + 2) : 0,
                w = p.remaining() > 3 ? p.get(o + 3) : 1;
        switch (pname) {
            case GL_POSITION: {
                // Positions are stored in eye space, transformed by the modelview at call time.
                float[] m = modelview.array();
                int t = modelview.top();
                float[] d = lightPos[l];
                d[0] = m[t] * x + m[t + 4] * y + m[t + 8] * z + m[t + 12] * w;
                d[1] = m[t + 1] * x + m[t + 5] * y + m[t + 9] * z + m[t + 13] * w;
                d[2] = m[t + 2] * x + m[t + 6] * y + m[t + 10] * z + m[t + 14] * w;
                d[3] = m[t + 3] * x + m[t + 7] * y + m[t + 11] * z + m[t + 15] * w;
                break;
            }
            case GL_DIFFUSE: set4(lightDiffuse[l], x, y, z, w); break;
            case GL_AMBIENT: set4(lightAmbient[l], x, y, z, w); break;
            case GL_SPECULAR: set4(lightSpecular[l], x, y, z, w); break;
            default: return;
        }
        dirty |= D_LIGHT;
    }

    public static void lightModel(int pname, FloatBuffer p) {
        if (pname == GL_LIGHT_MODEL_AMBIENT) {
            int o = p.position();
            set4(lightModelAmbient, p.get(o), p.get(o + 1), p.get(o + 2), p.get(o + 3));
            dirty |= D_LIGHT;
        }
    }

    public static void colorMaterial(int face, int mode) {
        if (face != colorMaterialFace || mode != colorMaterialMode) {
            colorMaterialFace = face;
            colorMaterialMode = mode;
            dirty |= D_LIGHT;
        }
    }

    // ------------------------------------------------------------------
    // texgen

    public static void texGeni(int coord, int pname, int param) {
        int c = coord - GL_S;
        if (c < 0 || c > 3 || pname != GL_TEXTURE_GEN_MODE) return;
        texGenMode[activeUnit][c] = param;
        dirty |= D_TEXGEN;
    }

    public static void texGenv(int coord, int pname, FloatBuffer p) {
        int c = coord - GL_S;
        if (c < 0 || c > 3) return;
        int o = p.position();
        float a = p.get(o), b = p.get(o + 1), cc = p.get(o + 2), d = p.get(o + 3);
        if (pname == GL_OBJECT_PLANE) {
            float[] dst = objPlane[activeUnit];
            dst[c * 4] = a; dst[c * 4 + 1] = b; dst[c * 4 + 2] = cc; dst[c * 4 + 3] = d;
        } else if (pname == GL_EYE_PLANE) {
            // eye plane = plane * inverse(modelview) at specification time
            float[] inv = new float[16];
            Mat.invert(modelview.array(), modelview.top(), inv);
            float[] dst = eyePlane[activeUnit];
            for (int i = 0; i < 4; i++) {
                dst[c * 4 + i] = a * inv[i * 4] + b * inv[i * 4 + 1] + cc * inv[i * 4 + 2] + d * inv[i * 4 + 3];
            }
        } else {
            return;
        }
        dirty |= D_TEXGEN;
    }

    static void set4(float[] d, float x, float y, float z, float w) { d[0] = x; d[1] = y; d[2] = z; d[3] = w; }

    /** Per-unit texture environment (GL_TEXTURE_ENV). */
    public static final class TexEnv {
        public int mode = GL_MODULATE;
        public int combineRGB = GL_MODULATE, combineA = GL_MODULATE;
        public final int[] srcRGB = {GL_TEXTURE, 0x8578, 0x8576};   // TEXTURE, PREVIOUS, CONSTANT
        public final int[] srcA = {GL_TEXTURE, 0x8578, 0x8576};
        public final int[] opRGB = {GL_SRC_COLOR, GL_SRC_COLOR, GL_SRC_ALPHA};
        public final int[] opA = {GL_SRC_ALPHA, GL_SRC_ALPHA, GL_SRC_ALPHA};
        public final float[] color = new float[4];
        public float rgbScale = 1f, alphaScale = 1f;
    }

    public static void texEnvi(int target, int pname, int v) {
        if (target != GL_TEXTURE_ENV) return;
        TexEnv e = env[activeUnit];
        switch (pname) {
            case GL_TEXTURE_ENV_MODE: e.mode = v; break;
            case 0x8571: e.combineRGB = v; break;           // GL_COMBINE_RGB
            case 0x8572: e.combineA = v; break;             // GL_COMBINE_ALPHA
            case 0x8580: case 0x8581: case 0x8582: e.srcRGB[pname - 0x8580] = v; break;
            case 0x8588: case 0x8589: case 0x858A: e.srcA[pname - 0x8588] = v; break;
            case 0x8590: case 0x8591: case 0x8592: e.opRGB[pname - 0x8590] = v; break;
            case 0x8598: case 0x8599: case 0x859A: e.opA[pname - 0x8598] = v; break;
            case 0x8573: e.rgbScale = v; break;             // GL_RGB_SCALE
            case GL_ALPHA_SCALE: e.alphaScale = v; break;
            default: return;
        }
        dirty |= D_UNITS;
    }

    public static void texEnvf(int target, int pname, float v) {
        if (pname == 0x8573) { env[activeUnit].rgbScale = v; dirty |= D_UNITS; }
        else if (pname == GL_ALPHA_SCALE) { env[activeUnit].alphaScale = v; dirty |= D_UNITS; }
        else texEnvi(target, pname, (int) v);
    }

    public static void texEnvv(int target, int pname, FloatBuffer p) {
        if (target == GL_TEXTURE_ENV && pname == GL_TEXTURE_ENV_COLOR) {
            int o = p.position();
            set4(env[activeUnit].color, p.get(o), p.get(o + 1), p.get(o + 2), p.get(o + 3));
            dirty |= D_UNITS;
        } else {
            texEnvf(target, pname, p.get(p.position()));
        }
    }
}
