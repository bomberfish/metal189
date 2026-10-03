package metal189.core;

import java.io.InputStream;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import net.minecraft.launchwrapper.IClassTransformer;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;

/**
 * Rewrites game classes so that every LWJGL display/input/OpenGL entry point
 * lands in metal189, then applies targeted engine patches.
 */
public class Metal189Transformer implements IClassTransformer {
    static final Logger LOG = LogManager.getLogger("metal189");

    private static final Map<String, String> REDIRECT = new HashMap<String, String>();
    private static final String CAPS = "org/lwjgl/opengl/ContextCapabilities";

    static {
        String[] gl = {"GL11", "GL12", "GL13", "GL14", "GL15", "GL20", "GL21", "GL30", "GL31", "GL32",
            "ARBMultitexture", "ARBFramebufferObject", "EXTFramebufferObject", "ARBShaderObjects",
            "ARBVertexShader", "ARBFragmentShader", "ARBVertexBufferObject", "EXTBlendFuncSeparate",
            "ARBBufferObject", "GLContext", "EXTTextureFilterAnisotropic", "ARBOcclusionQuery", "GL33"};
        for (String c : gl) REDIRECT.put("org/lwjgl/opengl/" + c, "metal189/shim/" + c);
        REDIRECT.put("org/lwjgl/opengl/Display", "metal189/platform/Display");
        REDIRECT.put("org/lwjgl/input/Mouse", "metal189/platform/Mouse");
        REDIRECT.put("org/lwjgl/input/Keyboard", "metal189/platform/Keyboard");
        REDIRECT.put("org/lwjgl/util/glu/Project", "metal189/shim/Project");
        REDIRECT.put("org/lwjgl/util/glu/GLU", "metal189/shim/GLU");
    }

    /** "owner.name desc" of every static method our shims provide, read lazily from class bytes. */
    private static final Map<String, Set<String>> provided = new HashMap<String, Set<String>>();
    private static final Set<String> warned = new HashSet<String>();

    @Override
    public byte[] transform(String name, String transformedName, byte[] bytes) {
        if (bytes == null || transformedName.startsWith("metal189.")) return bytes;
        ClassPatch patch = Patches.forClass(transformedName);
        boolean lwjgl = contains(bytes, LWJGL_BYTES);
        if (!lwjgl && patch == null) return bytes;
        try {
            ClassNode cn = new ClassNode();
            new ClassReader(bytes).accept(cn, 0);
            boolean changed = false;
            boolean frames = false;
            if (patch != null) {
                changed |= patch.apply(cn);
                frames = patch.needsFrames();
            }
            if (lwjgl) changed |= redirect(cn);
            if (!changed) return bytes;
            ClassWriter cw = new SafeClassWriter(frames ? ClassWriter.COMPUTE_FRAMES : ClassWriter.COMPUTE_MAXS);
            cn.accept(cw);
            return cw.toByteArray();
        } catch (RuntimeException e) {
            LOG.error("metal189: failed to transform {}", transformedName, e);
            throw e;
        }
    }

    static boolean redirect(ClassNode cn) {
        boolean changed = false;
        for (MethodNode m : cn.methods) {
            InsnList insns = m.instructions;
            for (AbstractInsnNode n = insns.getFirst(); n != null; n = n.getNext()) {
                if (n instanceof MethodInsnNode) {
                    MethodInsnNode mi = (MethodInsnNode) n;
                    String target = REDIRECT.get(mi.owner);
                    if (target == null || mi.getOpcode() != Opcodes.INVOKESTATIC) continue;
                    if (!provides(target, mi.name, mi.desc)) {
                        String key = mi.owner + "." + mi.name + mi.desc;
                        if (warned.add(key)) LOG.warn("metal189: no replacement for {} (used by {})", key, cn.name);
                        continue;
                    }
                    mi.owner = target;
                    changed = true;
                } else if (n instanceof FieldInsnNode) {
                    FieldInsnNode fi = (FieldInsnNode) n;
                    if (fi.getOpcode() == Opcodes.GETFIELD && CAPS.equals(fi.owner) && "Z".equals(fi.desc)) {
                        // capabilities.FLAG -> GLContext.cap("FLAG"), receiver dropped
                        InsnList rep = new InsnList();
                        rep.add(new InsnNode(Opcodes.POP));
                        rep.add(new LdcInsnNode(fi.name));
                        rep.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/shim/GLContext", "cap", "(Ljava/lang/String;)Z", false));
                        AbstractInsnNode last = rep.getLast();
                        insns.insert(fi, rep);
                        insns.remove(fi);
                        n = last;
                        changed = true;
                    }
                }
            }
        }
        return changed;
    }

    private static synchronized boolean provides(String owner, String name, String desc) {
        Set<String> s = provided.get(owner);
        if (s == null) {
            final Set<String> found = new HashSet<String>();
            try {
                InputStream in = Metal189Transformer.class.getResourceAsStream("/" + owner + ".class");
                if (in != null) {
                    try {
                        new ClassReader(in).accept(new ClassVisitor(Opcodes.ASM5) {
                            @Override
                            public MethodVisitor visitMethod(int access, String n, String d, String sig, String[] ex) {
                                if ((access & Opcodes.ACC_STATIC) != 0) found.add(n + d);
                                return null;
                            }
                        }, ClassReader.SKIP_CODE);
                    } finally {
                        in.close();
                    }
                }
            } catch (Exception e) {
                LOG.error("metal189: cannot index {}", owner, e);
            }
            s = found;
            provided.put(owner, s);
        }
        return s.contains(name + desc);
    }

    private static final byte[] LWJGL_BYTES = "org/lwjgl/".getBytes();

    static boolean contains(byte[] hay, byte[] needle) {
        outer:
        for (int i = 0, n = hay.length - needle.length; i <= n; i++) {
            if (hay[i] != needle[0]) continue;
            for (int j = 1; j < needle.length; j++) if (hay[i + j] != needle[j]) continue outer;
            return true;
        }
        return false;
    }
}
