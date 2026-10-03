package metal189.gl;

import metal189.engine.Cmd;
import metal189.engine.Engine;
import metal189.engine.Mem;

/** Framebuffer objects and renderbuffers. Binding changes are emitted lazily before draws/clears. */
public final class Targets {
    private Targets() {}

    static final class Fbo {
        int colorTex;
        int depth;   // renderbuffer id (or texture id when depthIsTex)
        boolean depthIsTex;
    }

    private static final java.util.HashMap<Integer, Fbo> fbos = new java.util.HashMap<Integer, Fbo>();
    private static int nextFbo = 1, nextRb = 1;
    public static int drawFbo;
    private static int emittedFbo = -1, emittedColor = -1, emittedDepth = -1;
    static int boundRenderbuffer;

    public static int genFramebuffer() {
        int id = nextFbo++;
        fbos.put(id, new Fbo());
        return id;
    }

    public static void deleteFramebuffer(int id) {
        fbos.remove(id);
        if (drawFbo == id) drawFbo = 0;
    }

    public static void bindFramebuffer(int id) { drawFbo = id; }

    public static void attachTexture(int attachment, int tex) {
        Fbo f = fbos.get(drawFbo);
        if (f == null) return;
        if (attachment == 0x8CE0) f.colorTex = tex;           // GL_COLOR_ATTACHMENT0
        else if (attachment == 0x8D00 || attachment == 0x821A) { f.depth = tex; f.depthIsTex = true; }
        emittedFbo = -1;
    }

    public static void attachRenderbuffer(int attachment, int rb) {
        Fbo f = fbos.get(drawFbo);
        if (f == null) return;
        if (attachment == 0x8D00 || attachment == 0x821A || attachment == 0x8D20) { f.depth = rb; f.depthIsTex = false; }
        emittedFbo = -1;
    }

    public static int genRenderbuffer() { return nextRb++; }

    public static void bindRenderbuffer(int rb) { boundRenderbuffer = rb; }

    public static void renderbufferStorage(int internalFormat, int w, int h) {
        if (boundRenderbuffer == 0) return;
        metal189.engine.Native.renderbufferStorage(boundRenderbuffer, internalFormat, w, h);
    }

    public static int status() { return 0x8CD5; } // GL_FRAMEBUFFER_COMPLETE

    static void invalidate() { emittedFbo = -1; }

    /** Emits a TARGET record if the bound framebuffer (or its attachments) changed. */
    static void flush() {
        int color = 0, depth = 0;
        if (drawFbo != 0) {
            Fbo f = fbos.get(drawFbo);
            if (f != null) {
                color = f.colorTex;
                depth = f.depth == 0 ? 0 : (f.depthIsTex ? f.depth : (f.depth | 0x40000000));
            }
        }
        if (drawFbo == emittedFbo && color == emittedColor && depth == emittedDepth) return;
        long p = Engine.cmd.begin(Cmd.TARGET, 4);
        Mem.putInt(p, drawFbo);
        Mem.putInt(p + 4, color);
        Mem.putInt(p + 8, depth);
        emittedFbo = drawFbo;
        emittedColor = color;
        emittedDepth = depth;
    }
}
