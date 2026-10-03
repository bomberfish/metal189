package metal189.core;

import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/** Small helpers for writing class patches. */
public final class Asm {
    private Asm() {}

    public static MethodNode find(ClassNode cn, String mcp, String srg, String desc) {
        for (MethodNode m : cn.methods) {
            if ((m.name.equals(mcp) || m.name.equals(srg)) && m.desc.equals(desc)) return m;
        }
        return null;
    }

    /**
     * Replaces a method body with a call to a static hook taking the same
     * arguments (prefixed with {@code this} when {@code passThis}), returning its result.
     */
    public static ClassPatch replaceBody(final String mcp, final String srg, final String desc,
                                         final String hookOwner, final String hookName, final String hookDesc,
                                         final boolean passThis) {
        return new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = find(cn, mcp, srg, desc);
                if (m == null) {
                    Metal189Transformer.LOG.error("metal189: {}.{}{} not found", cn.name, mcp, desc);
                    return false;
                }
                boolean isStatic = (m.access & Opcodes.ACC_STATIC) != 0;
                InsnList l = new InsnList();
                int slot = 0;
                if (!isStatic) {
                    if (passThis) l.add(new VarInsnNode(Opcodes.ALOAD, 0));
                    slot = 1;
                }
                for (Type t : Type.getArgumentTypes(desc)) {
                    l.add(new VarInsnNode(t.getOpcode(Opcodes.ILOAD), slot));
                    slot += t.getSize();
                }
                l.add(new MethodInsnNode(Opcodes.INVOKESTATIC, hookOwner, hookName, hookDesc, false));
                l.add(new InsnNode(Type.getReturnType(desc).getOpcode(Opcodes.IRETURN)));
                m.instructions.clear();
                m.instructions.add(l);
                m.tryCatchBlocks.clear();
                if (m.localVariables != null) m.localVariables.clear();
                m.maxStack = Math.max(slot + 1, 4);
                return true;
            }

            public boolean needsFrames() { return false; }
        };
    }
}
