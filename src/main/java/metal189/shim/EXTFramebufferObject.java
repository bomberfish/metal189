package metal189.shim;

import metal189.gl.Targets;

public final class EXTFramebufferObject {
    private EXTFramebufferObject() {}
    public static int glGenFramebuffersEXT() { return Targets.genFramebuffer(); }
    public static void glDeleteFramebuffersEXT(int f) { Targets.deleteFramebuffer(f); }
    public static void glBindFramebufferEXT(int target, int f) { Targets.bindFramebuffer(f); }
    public static int glCheckFramebufferStatusEXT(int target) { return Targets.status(); }
    public static void glFramebufferTexture2DEXT(int target, int attachment, int texTarget, int tex, int level) { Targets.attachTexture(attachment, tex); }
    public static void glFramebufferRenderbufferEXT(int target, int attachment, int rbTarget, int rb) { Targets.attachRenderbuffer(attachment, rb); }
    public static int glGenRenderbuffersEXT() { return Targets.genRenderbuffer(); }
    public static void glDeleteRenderbuffersEXT(int rb) {}
    public static void glBindRenderbufferEXT(int target, int rb) { Targets.bindRenderbuffer(rb); }
    public static void glRenderbufferStorageEXT(int target, int fmt, int w, int h) { Targets.renderbufferStorage(fmt, w, h); }
    public static void glGenerateMipmapEXT(int target) {}
}
