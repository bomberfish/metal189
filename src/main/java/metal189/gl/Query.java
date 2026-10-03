package metal189.gl;

import static org.lwjgl.opengl.GL11.*;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import metal189.engine.Cmd;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.engine.Native;

/** glGet*, glClear, glReadPixels and other queries/one-offs. */
public final class Query {
    private Query() {}

    public static String renderer;

    public static String getString(int name) {
        switch (name) {
            case GL_VENDOR: return "Apple (metal189)";
            case GL_RENDERER:
                if (renderer == null) renderer = "Metal: " + Native.deviceName();
                return renderer;
            case GL_VERSION: return "2.1 metal189";
            case GL_EXTENSIONS: return "GL_ARB_multitexture GL_ARB_texture_env_combine GL_EXT_blend_func_separate "
                    + "GL_ARB_framebuffer_object GL_ARB_vertex_buffer_object GL_ARB_shader_objects";
            case 0x8B8C /* GL_SHADING_LANGUAGE_VERSION */: return "1.20";
            default: return "";
        }
    }

    public static void getFloat(int pname, FloatBuffer out) {
        int o = out.position();
        switch (pname) {
            case GL_MODELVIEW_MATRIX: put16(GL.modelview, out, o); return;
            case GL_PROJECTION_MATRIX: put16(GL.projection, out, o); return;
            case GL_TEXTURE_MATRIX: put16(GL.texMatrix[GL.activeUnit], out, o); return;
            case GL_CURRENT_COLOR:
                out.put(o, GL.colR); out.put(o + 1, GL.colG); out.put(o + 2, GL.colB); out.put(o + 3, GL.colA); return;
            case GL_FOG_COLOR: for (int i = 0; i < 4; i++) out.put(o + i, GL.fogColor[i]); return;
            case GL_LINE_WIDTH: out.put(o, GL.lineWidth); return;
            case 0x84FF /* GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT */: out.put(o, 16f); return;
            case GL_FOG_START: out.put(o, GL.fogStart); return;
            case GL_FOG_END: out.put(o, GL.fogEnd); return;
            case GL_FOG_DENSITY: out.put(o, GL.fogDensity); return;
            default: out.put(o, (float) getInteger(pname));
        }
    }

    private static void put16(MatrixStack s, FloatBuffer out, int o) {
        float[] a = s.array();
        int t = s.top();
        for (int i = 0; i < 16; i++) out.put(o + i, a[t + i]);
    }

    public static int getInteger(int pname) {
        switch (pname) {
            case GL_MAX_TEXTURE_SIZE: return Textures.MAX_SIZE;
            case GL_TEXTURE_BINDING_2D: return GL.boundTex[GL.activeUnit];
            case GL_MATRIX_MODE: return GL.matrixMode;
            case 0x84E0 /* GL_ACTIVE_TEXTURE */: return 0x84C0 + GL.activeUnit;
            case 0x8CA6 /* GL_FRAMEBUFFER_BINDING */: return Targets.drawFbo;
            case 0x8894 /* GL_ARRAY_BUFFER_BINDING */: return Arrays.arrayBuffer;
            case 0x8B8D /* GL_CURRENT_PROGRAM */: return Programs.current;
            case 0x84E2 /* MAX_TEXTURE_UNITS */: case 0x8872 /* MAX_TEXTURE_IMAGE_UNITS */: return 8;
            case GL_MAX_MODELVIEW_STACK_DEPTH: return 64;
            case GL_MAX_PROJECTION_STACK_DEPTH: return 16;
            case GL_MAX_LIGHTS: return 8;
            case GL_DEPTH_FUNC: return GL.depthFunc;
            case GL_BLEND_SRC: return GL.blendSrcRGB;
            case GL_BLEND_DST: return GL.blendDstRGB;
            case GL_ALPHA_TEST_FUNC: return GL.alphaFunc;
            case GL_SHADE_MODEL: return GL.shadeModel;
            case GL_CULL_FACE_MODE: return GL.cullFace;
            case GL_FOG_MODE: return GL.fogMode;
            case 0x8D57 /* GL_MAX_SAMPLES */: return 4;
            case 0x8CDF /* GL_MAX_COLOR_ATTACHMENTS */: return 8;
            case GL_DEPTH_BITS: return 24;
            case GL_STENCIL_BITS: return 8;
            case GL_RED_BITS: case GL_GREEN_BITS: case GL_BLUE_BITS: case GL_ALPHA_BITS: return 8;
            case GL_UNPACK_ALIGNMENT: return GL.unpackAlignment;
            case GL_PACK_ALIGNMENT: return GL.packAlignment;
            case 0x821B /* MAJOR_VERSION */: return 2;
            case 0x821C /* MINOR_VERSION */: return 1;
            default: return 0;
        }
    }

    public static void getInteger(int pname, IntBuffer out) {
        int o = out.position();
        switch (pname) {
            case GL_VIEWPORT:
                out.put(o, GL.vpX); out.put(o + 1, GL.vpY); out.put(o + 2, GL.vpW); out.put(o + 3, GL.vpH);
                return;
            case GL_SCISSOR_BOX:
                out.put(o, GL.scX); out.put(o + 1, GL.scY); out.put(o + 2, GL.scW); out.put(o + 3, GL.scH);
                return;
            default:
                out.put(o, getInteger(pname));
        }
    }

    public static void pixelStore(int pname, int v) {
        switch (pname) {
            case GL_UNPACK_ROW_LENGTH: GL.unpackRowLength = v; break;
            case GL_UNPACK_SKIP_ROWS: GL.unpackSkipRows = v; break;
            case GL_UNPACK_SKIP_PIXELS: GL.unpackSkipPixels = v; break;
            case GL_UNPACK_ALIGNMENT: GL.unpackAlignment = v; break;
            case GL_PACK_ROW_LENGTH: GL.packRowLength = v; break;
            case GL_PACK_SKIP_ROWS: GL.packSkipRows = v; break;
            case GL_PACK_SKIP_PIXELS: GL.packSkipPixels = v; break;
            case GL_PACK_ALIGNMENT: GL.packAlignment = v; break;
            default: break;
        }
    }

    public static void clear(int mask) {
        if (Lists.compiling != null) return;
        Draw.flush();
        long p = Engine.cmd.begin(Cmd.CLEAR, 8);
        Mem.putInt(p, mask);
        Mem.putFloat(p + 4, GL.clearR);
        Mem.putFloat(p + 8, GL.clearG);
        Mem.putFloat(p + 12, GL.clearB);
        Mem.putFloat(p + 16, GL.clearA);
        Mem.putFloat(p + 20, (float) GL.clearDepth);
        Mem.putInt(p + 24, GL.clearStencil);
    }

    public static void readPixels(int x, int y, int w, int h, int format, int type, java.nio.Buffer out) {
        if (out == null) return;
        Engine.flushForReadback();
        Native.readPixels(Targets.drawFbo, x, y, w, h, format, type, Mem.positionAddress(out), (int) Mem.remainingBytes(out));
    }

    static void unused(ByteBuffer b) {}
}
