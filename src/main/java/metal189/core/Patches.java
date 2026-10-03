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

        // Terrain: engine-owned section buffers and per-layer draws.
        register("net.minecraft.client.renderer.RenderGlobal", Asm.chain(
            Asm.redirectNew("net/minecraft/client/renderer/RenderList", "metal189/terrain/TerrainContainer"),
            Asm.redirectNew("net/minecraft/client/renderer/VboRenderList", "metal189/terrain/TerrainContainer")));
        register("net.minecraft.client.renderer.chunk.ChunkRenderDispatcher",
            Asm.injectHead("uploadChunk", "func_178503_a",
                "(Lnet/minecraft/util/EnumWorldBlockLayer;Lnet/minecraft/client/renderer/WorldRenderer;Lnet/minecraft/client/renderer/chunk/RenderChunk;Lnet/minecraft/client/renderer/chunk/CompiledChunk;)Lcom/google/common/util/concurrent/ListenableFuture;",
                "metal189/terrain/Terrain", "upload",
                "(Lnet/minecraft/util/EnumWorldBlockLayer;Lnet/minecraft/client/renderer/WorldRenderer;Lnet/minecraft/client/renderer/chunk/RenderChunk;Lnet/minecraft/client/renderer/chunk/CompiledChunk;)Lcom/google/common/util/concurrent/ListenableFuture;",
                false));
        // Block state ids stamped into chunk vertices (materials for the advanced pipeline).
        register("net.minecraft.client.renderer.BlockRendererDispatcher", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                org.objectweb.asm.tree.MethodNode m = Asm.find(cn, "renderBlock", "func_175018_a",
                    "(Lnet/minecraft/block/state/IBlockState;Lnet/minecraft/util/BlockPos;Lnet/minecraft/world/IBlockAccess;Lnet/minecraft/client/renderer/WorldRenderer;)Z");
                if (m == null) return false;
                org.objectweb.asm.tree.InsnList head = new org.objectweb.asm.tree.InsnList();
                head.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 4));
                head.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Terrain", "beginBlock",
                    "(Lnet/minecraft/client/renderer/WorldRenderer;)V", false));
                m.instructions.insert(head);
                for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    if (n.getOpcode() != Opcodes.IRETURN) continue;
                    org.objectweb.asm.tree.InsnList t = new org.objectweb.asm.tree.InsnList();
                    t.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 4));
                    t.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 1));
                    t.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Terrain", "endBlock",
                        "(Lnet/minecraft/client/renderer/WorldRenderer;Lnet/minecraft/block/state/IBlockState;)V", false));
                    m.instructions.insertBefore(n, t);
                }
                return true;
            }

            public boolean needsFrames() { return false; }
        });

        // Phase markers in EntityRenderer.renderWorldPass.
        final String rwp = "(IFJ)V";
        register("net.minecraft.client.renderer.EntityRenderer", Asm.chain(
            Asm.aroundMethod("renderWorldPass", "func_175068_a", rwp, "metal189/world/Phases", "worldBegin", "worldEnd"),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderSky", "func_174976_a", "metal189/world/Phases", "sky", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderCloudsCheck", "func_180437_a", "metal189/world/Phases", "clouds", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "setupTerrain", "func_174970_a", "metal189/world/Phases", "terrain", 2),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderEntities", "func_180446_a", "metal189/world/Phases", "entities", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "drawSelectionBox", "func_72731_b", "metal189/world/Phases", "outline", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "drawBlockDamageTexture", "func_174981_a", "metal189/world/Phases", "destroy", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderLitParticles", "func_78872_b", "metal189/world/Phases", "litParticles", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderParticles", "func_78874_a", "metal189/world/Phases", "particles", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderRainSnow", "func_78474_d", "metal189/world/Phases", "weather", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderWorldBorder", "func_180449_a", "metal189/world/Phases", "worldBorder", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "dispatchRenderLast", "dispatchRenderLast", "metal189/world/Phases", "renderLast", -1),
            Asm.beforeCall("renderWorldPass", "func_175068_a", rwp, "renderHand", "func_78476_b", "metal189/world/Phases", "hand", -1)));

        register("net.minecraft.client.renderer.chunk.RenderChunk", Asm.chain(
            Asm.injectHead("deleteGlResources", "func_178566_a", "()V",
                "metal189/terrain/Terrain", "delete", "(Lnet/minecraft/client/renderer/chunk/RenderChunk;)V", true),
            Asm.injectHeadThisOnly("setPosition", "func_178576_a", "(Lnet/minecraft/util/BlockPos;)V",
                "metal189/terrain/Terrain", "moved", "(Lnet/minecraft/client/renderer/chunk/RenderChunk;)V"),
            Asm.injectHead("setCompiledChunk", "func_178580_a", "(Lnet/minecraft/client/renderer/chunk/CompiledChunk;)V",
                "metal189/terrain/Terrain", "compiled",
                "(Lnet/minecraft/client/renderer/chunk/RenderChunk;Lnet/minecraft/client/renderer/chunk/CompiledChunk;)V", true)));
    }

    static ClassPatch forClass(String name) { return PATCHES.get(name); }
}
