package metal189.core;

import java.util.HashMap;
import java.util.Map;
import net.minecraft.launchwrapper.IClassTransformer;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;

/**
 * Reference (vanilla GL) test mode: rendering stays on LWJGL/OpenGL, but mouse
 * and keyboard go through metal189's no-grab implementations and
 * Display.update drives the test driver.
 */
public class ReferenceTransformer implements IClassTransformer {
    private static final Map<String, String> REDIRECT = new HashMap<String, String>();

    static {
        REDIRECT.put("org/lwjgl/input/Mouse", "metal189/platform/Mouse");
        REDIRECT.put("org/lwjgl/input/Keyboard", "metal189/platform/Keyboard");
    }

    @Override
    public byte[] transform(String name, String transformedName, byte[] bytes) {
        if (bytes == null || transformedName.startsWith("metal189.")) return bytes;
        if (!Metal189Transformer.contains(bytes, "org/lwjgl/".getBytes())) return bytes;
        ClassNode cn = new ClassNode();
        new ClassReader(bytes).accept(cn, 0);
        boolean changed = false;
        for (MethodNode m : cn.methods) {
            for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                if (!(n instanceof MethodInsnNode) || n.getOpcode() != Opcodes.INVOKESTATIC) continue;
                MethodInsnNode mi = (MethodInsnNode) n;
                String t = REDIRECT.get(mi.owner);
                if (t != null) { mi.owner = t; changed = true; }
                else if ("org/lwjgl/opengl/Display".equals(mi.owner) && "update".equals(mi.name) && "()V".equals(mi.desc)) {
                    mi.owner = "metal189/test/RefDisplay";
                    changed = true;
                }
            }
        }
        if (!changed) return bytes;
        ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        cn.accept(cw);
        return cw.toByteArray();
    }
}
