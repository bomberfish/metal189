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
     * Inside method (mcp/srg, desc), inserts {@code hookOwner.hookName()} before
     * every call to a method named {@code callMcp}/{@code callSrg}. Hooks may take
     * a float loaded from {@code floatArgSlot} (or none if slot < 0).
     */
    public static ClassPatch beforeCall(final String mcp, final String srg, final String desc,
                                        final String callMcp, final String callSrg,
                                        final String hookOwner, final String hookName, final int floatArgSlot) {
        return new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = find(cn, mcp, srg, desc);
                if (m == null) return false;
                boolean changed = false;
                for (org.objectweb.asm.tree.AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    if (!(n instanceof MethodInsnNode)) continue;
                    MethodInsnNode mi = (MethodInsnNode) n;
                    if (!mi.name.equals(callMcp) && !mi.name.equals(callSrg)) continue;
                    InsnList l = new InsnList();
                    if (floatArgSlot >= 0) {
                        l.add(new VarInsnNode(Opcodes.FLOAD, floatArgSlot));
                        l.add(new MethodInsnNode(Opcodes.INVOKESTATIC, hookOwner, hookName, "(F)V", false));
                    } else {
                        l.add(new MethodInsnNode(Opcodes.INVOKESTATIC, hookOwner, hookName, "()V", false));
                    }
                    // Insert before the argument loads of the call: walk back to the receiver load
                    // is fragile, so the hook runs right before the call instruction; hooks only
                    // emit stream records and never touch the operand stack.
                    m.instructions.insertBefore(mi, l);
                    changed = true;
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        };
    }

    /** Inserts a static no-arg call before every return of a method (and optionally at its head). */
    public static ClassPatch aroundMethod(final String mcp, final String srg, final String desc,
                                          final String hookOwner, final String headHook, final String tailHook) {
        return new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = find(cn, mcp, srg, desc);
                if (m == null) return false;
                if (headHook != null) m.instructions.insert(new MethodInsnNode(Opcodes.INVOKESTATIC, hookOwner, headHook, "()V", false));
                if (tailHook != null) {
                    for (org.objectweb.asm.tree.AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        int op = n.getOpcode();
                        if (op >= Opcodes.IRETURN && op <= Opcodes.RETURN) {
                            m.instructions.insertBefore(n, new MethodInsnNode(Opcodes.INVOKESTATIC, hookOwner, tailHook, "()V", false));
                        }
                    }
                }
                return true;
            }

            public boolean needsFrames() { return false; }
        };
    }

    /** Applies several patches to the same class. */
    public static ClassPatch chain(final ClassPatch... patches) {
        return new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (ClassPatch p : patches) changed |= p.apply(cn);
                return changed;
            }

            public boolean needsFrames() {
                for (ClassPatch p : patches) if (p.needsFrames()) return true;
                return false;
            }
        };
    }

    /** Rewrites every {@code new from()} in the class into {@code new to()}. */
    public static ClassPatch redirectNew(final String from, final String to) {
        return new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (MethodNode m : cn.methods) {
                    for (org.objectweb.asm.tree.AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() == Opcodes.NEW && from.equals(((org.objectweb.asm.tree.TypeInsnNode) n).desc)) {
                            ((org.objectweb.asm.tree.TypeInsnNode) n).desc = to;
                            changed = true;
                        } else if (n.getOpcode() == Opcodes.INVOKESPECIAL && from.equals(((MethodInsnNode) n).owner)
                                && "<init>".equals(((MethodInsnNode) n).name)) {
                            ((MethodInsnNode) n).owner = to;
                            changed = true;
                        }
                    }
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        };
    }

    /**
     * Inserts at the head of a method a call to a static hook receiving
     * {@code this} (if non-static) followed by all arguments. For non-void
     * methods, a non-null hook result is returned immediately.
     */
    public static ClassPatch injectHead(final String mcp, final String srg, final String desc,
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
                Type ret = Type.getReturnType(desc);
                if (ret.getSort() == Type.OBJECT || ret.getSort() == Type.ARRAY) {
                    org.objectweb.asm.tree.LabelNode cont = new org.objectweb.asm.tree.LabelNode();
                    l.add(new InsnNode(Opcodes.DUP));
                    l.add(new org.objectweb.asm.tree.JumpInsnNode(Opcodes.IFNULL, cont));
                    l.add(new InsnNode(Opcodes.ARETURN));
                    l.add(cont);
                    l.add(new InsnNode(Opcodes.POP));
                } else if (Type.getReturnType(hookDesc).getSort() != Type.VOID) {
                    l.add(new InsnNode(Opcodes.POP));
                }
                m.instructions.insert(l);
                return true;
            }

            public boolean needsFrames() { return true; }
        };
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
