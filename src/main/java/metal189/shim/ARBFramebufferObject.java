package metal189.shim;

import metal189.gl.Targets;

public final class ARBFramebufferObject {
    private ARBFramebufferObject() {}
    public static int glGenFramebuffers() { return Targets.genFramebuffer(); }
    public static void glDeleteFramebuffers(int f) { Targets.deleteFramebuffer(f); }
    public static void glBindFramebuffer(int target, int f) { Targets.bindFramebuffer(f); }
    public static int glCheckFramebufferStatus(int target) { return Targets.status(); }
    public static void glFramebufferTexture2D(int target, int attachment, int texTarget, int tex, int level) { Targets.attachTexture(attachment, tex); }
    public static void glFramebufferRenderbuffer(int target, int attachment, int rbTarget, int rb) { Targets.attachRenderbuffer(attachment, rb); }
    public static int glGenRenderbuffers() { return Targets.genRenderbuffer(); }
    public static void glDeleteRenderbuffers(int rb) {}
    public static void glBindRenderbuffer(int target, int rb) { Targets.bindRenderbuffer(rb); }
    public static void glRenderbufferStorage(int target, int fmt, int w, int h) { Targets.renderbufferStorage(fmt, w, h); }
    public static void glGenerateMipmap(int target) {}
}
