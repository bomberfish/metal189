package metal189.core;

import java.util.HashMap;
import java.util.Map;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodNode;

/** Registry of targeted class patches, keyed by deobfuscated class name. */
public final class Patches {
    private Patches() {}

    private static final Map<String, ClassPatch> PATCHES = new HashMap<String, ClassPatch>();

    static {
        // Forge's threaded splash screen drives a second GL context; keep it off.
        PATCHES.put("net.minecraftforge.fml.client.SplashProgress", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (MethodNode m : cn.methods) {
                    if (!"start".equals(m.name)) continue;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() == Opcodes.PUTSTATIC && "enabled".equals(((FieldInsnNode) n).name)) {
                            m.instructions.insertBefore(n, new InsnNode(Opcodes.POP));
                            m.instructions.insertBefore(n, new InsnNode(Opcodes.ICONST_0));
                            changed = true;
                        }
                    }
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        });
    }

    public static void register(String className, ClassPatch patch) { PATCHES.put(className, patch); }

    static {
        // Tessellator output goes straight to the engine.
        register("net.minecraft.client.renderer.WorldVertexBufferUploader",
            Asm.replaceBody("draw", "func_181679_a", "(Lnet/minecraft/client/renderer/WorldRenderer;)V",
                "metal189/capture/Tess", "draw", "(Lnet/minecraft/client/renderer/WorldRenderer;)V", false));
    }

    static ClassPatch forClass(String name) { return PATCHES.get(name); }
}
