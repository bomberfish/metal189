package metal189.gl;

import static metal189.gl.GL.*;

import java.util.ArrayDeque;

/** glPushAttrib / glPopAttrib for the state groups vanilla and common mods touch. */
public final class AttribStack {
    private AttribStack() {}

    static final int CURRENT = 0x1, LINE = 0x4, POLYGON = 0x8, LIGHTING = 0x40, FOG = 0x80, DEPTH = 0x100,
            VIEWPORT = 0x800, TRANSFORM = 0x1000, ENABLE = 0x2000, COLOR = 0x4000, TEXTURE = 0x40000, SCISSOR = 0x80000;

    private static final class Snap {
        int mask;
        boolean blend, alphaTest, depthTest, cull, fog, lighting, colorMaterial, normalize, rescaleNormal,
                polyOffsetFill, polyOffsetLine, logicOpEnable, scissorTest;
        boolean[] tex2D = new boolean[UNITS], lightOn = new boolean[8];
        boolean[][] texGen = new boolean[UNITS][4];
        int blendSrcRGB, blendDstRGB, blendSrcA, blendDstA, blendEq, colorMask, logicOp, alphaFunc;
        float blendColorR, blendColorG, blendColorB, blendColorA;
        float alphaRef;
        int depthFunc; boolean depthMask;
        int cullFace, frontFace, shadeModel; float polyFactor, polyUnits, lineWidth;
        int fogMode; float fogStart, fogEnd, fogDensity; float[] fogColor = new float[4];
        float colR, colG, colB, colA, nrmX, nrmY, nrmZ; float[][] texCoord = new float[UNITS][4];
        int vpX, vpY, vpW, vpH, scX, scY, scW, scH, matrixMode, activeUnit;
        int[] boundTex = new int[UNITS];
        float[][] lightPos = new float[8][4], lightDiffuse = new float[8][4], lightAmbient = new float[8][4];
        float[] lightModelAmbient = new float[4];
        int colorMaterialFace, colorMaterialMode;
    }

    private static final ArrayDeque<Snap> stack = new ArrayDeque<Snap>();

    public static void push(int mask) {
        Snap s = new Snap();
        s.mask = mask;
        s.blend = blend; s.alphaTest = alphaTest; s.depthTest = depthTest; s.cull = cull; s.fog = fog;
        s.lighting = lighting; s.colorMaterial = colorMaterial; s.normalize = normalize; s.rescaleNormal = rescaleNormal;
        s.polyOffsetFill = polyOffsetFill; s.polyOffsetLine = polyOffsetLine; s.logicOpEnable = logicOpEnable;
        s.scissorTest = scissorTest;
        System.arraycopy(tex2D, 0, s.tex2D, 0, UNITS);
        System.arraycopy(lightOn, 0, s.lightOn, 0, 8);
        for (int u = 0; u < UNITS; u++) {
            System.arraycopy(texGen[u], 0, s.texGen[u], 0, 4);
            System.arraycopy(texCoord[u], 0, s.texCoord[u], 0, 4);
        }
        s.blendSrcRGB = blendSrcRGB; s.blendDstRGB = blendDstRGB; s.blendSrcA = blendSrcA; s.blendDstA = blendDstA;
        s.blendEq = blendEq; s.colorMask = colorMask; s.logicOp = logicOp; s.alphaFunc = alphaFunc; s.alphaRef = alphaRef;
        s.blendColorR = blendColorR; s.blendColorG = blendColorG; s.blendColorB = blendColorB; s.blendColorA = blendColorA;
        s.depthFunc = depthFunc; s.depthMask = depthMask;
        s.cullFace = cullFace; s.frontFace = frontFace; s.shadeModel = shadeModel;
        s.polyFactor = polyFactor; s.polyUnits = polyUnits; s.lineWidth = lineWidth;
        s.fogMode = fogMode; s.fogStart = fogStart; s.fogEnd = fogEnd; s.fogDensity = fogDensity;
        System.arraycopy(fogColor, 0, s.fogColor, 0, 4);
        s.colR = colR; s.colG = colG; s.colB = colB; s.colA = colA; s.nrmX = nrmX; s.nrmY = nrmY; s.nrmZ = nrmZ;
        s.vpX = vpX; s.vpY = vpY; s.vpW = vpW; s.vpH = vpH; s.scX = scX; s.scY = scY; s.scW = scW; s.scH = scH;
        s.matrixMode = matrixMode; s.activeUnit = activeUnit;
        System.arraycopy(boundTex, 0, s.boundTex, 0, UNITS);
        for (int l = 0; l < 8; l++) {
            System.arraycopy(lightPos[l], 0, s.lightPos[l], 0, 4);
            System.arraycopy(lightDiffuse[l], 0, s.lightDiffuse[l], 0, 4);
            System.arraycopy(lightAmbient[l], 0, s.lightAmbient[l], 0, 4);
        }
        System.arraycopy(lightModelAmbient, 0, s.lightModelAmbient, 0, 4);
        s.colorMaterialFace = colorMaterialFace; s.colorMaterialMode = colorMaterialMode;
        stack.push(s);
    }

    public static void pop() {
        Snap s = stack.poll();
        if (s == null) return;
        int m = s.mask;
        if ((m & ENABLE) != 0) {
            blend = s.blend; alphaTest = s.alphaTest; depthTest = s.depthTest; cull = s.cull; fog = s.fog;
            lighting = s.lighting; colorMaterial = s.colorMaterial; normalize = s.normalize; rescaleNormal = s.rescaleNormal;
            polyOffsetFill = s.polyOffsetFill; polyOffsetLine = s.polyOffsetLine; logicOpEnable = s.logicOpEnable;
            scissorTest = s.scissorTest;
            System.arraycopy(s.tex2D, 0, tex2D, 0, UNITS);
            System.arraycopy(s.lightOn, 0, lightOn, 0, 8);
            for (int u = 0; u < UNITS; u++) System.arraycopy(s.texGen[u], 0, texGen[u], 0, 4);
        }
        if ((m & COLOR) != 0) {
            blend = s.blend; alphaTest = s.alphaTest; logicOpEnable = s.logicOpEnable;
            blendSrcRGB = s.blendSrcRGB; blendDstRGB = s.blendDstRGB; blendSrcA = s.blendSrcA; blendDstA = s.blendDstA;
            blendColorR = s.blendColorR; blendColorG = s.blendColorG; blendColorB = s.blendColorB; blendColorA = s.blendColorA;
            blendEq = s.blendEq; colorMask = s.colorMask; logicOp = s.logicOp; alphaFunc = s.alphaFunc; alphaRef = s.alphaRef;
        }
        if ((m & DEPTH) != 0) { depthTest = s.depthTest; depthFunc = s.depthFunc; depthMask = s.depthMask; }
        if ((m & POLYGON) != 0) {
            cull = s.cull; cullFace = s.cullFace; frontFace = s.frontFace;
            polyOffsetFill = s.polyOffsetFill; polyOffsetLine = s.polyOffsetLine; polyFactor = s.polyFactor; polyUnits = s.polyUnits;
        }
        if ((m & LINE) != 0) lineWidth = s.lineWidth;
        if ((m & LIGHTING) != 0) {
            lighting = s.lighting; colorMaterial = s.colorMaterial; shadeModel = s.shadeModel;
            System.arraycopy(s.lightOn, 0, lightOn, 0, 8);
            for (int l = 0; l < 8; l++) {
                System.arraycopy(s.lightPos[l], 0, lightPos[l], 0, 4);
                System.arraycopy(s.lightDiffuse[l], 0, lightDiffuse[l], 0, 4);
                System.arraycopy(s.lightAmbient[l], 0, lightAmbient[l], 0, 4);
            }
            System.arraycopy(s.lightModelAmbient, 0, lightModelAmbient, 0, 4);
            colorMaterialFace = s.colorMaterialFace; colorMaterialMode = s.colorMaterialMode;
        }
        if ((m & FOG) != 0) {
            fog = s.fog; fogMode = s.fogMode; fogStart = s.fogStart; fogEnd = s.fogEnd; fogDensity = s.fogDensity;
            System.arraycopy(s.fogColor, 0, fogColor, 0, 4);
        }
        if ((m & CURRENT) != 0) {
            colR = s.colR; colG = s.colG; colB = s.colB; colA = s.colA; nrmX = s.nrmX; nrmY = s.nrmY; nrmZ = s.nrmZ;
            for (int u = 0; u < UNITS; u++) System.arraycopy(s.texCoord[u], 0, texCoord[u], 0, 4);
        }
        if ((m & VIEWPORT) != 0) { vpX = s.vpX; vpY = s.vpY; vpW = s.vpW; vpH = s.vpH; }
        if ((m & SCISSOR) != 0) { scissorTest = s.scissorTest; scX = s.scX; scY = s.scY; scW = s.scW; scH = s.scH; }
        if ((m & TRANSFORM) != 0) { normalize = s.normalize; rescaleNormal = s.rescaleNormal; matrixMode(s.matrixMode); }
        if ((m & TEXTURE) != 0) {
            System.arraycopy(s.boundTex, 0, boundTex, 0, UNITS);
            activeUnit = s.activeUnit;
            for (int u = 0; u < UNITS; u++) System.arraycopy(s.texGen[u], 0, texGen[u], 0, 4);
        }
        GL.dirty = -1;
    }
}
