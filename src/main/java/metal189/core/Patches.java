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

    /** Adds a patch for a class (after any already registered for it). */
    public static void register(String className, ClassPatch patch) {
        ClassPatch before = PATCHES.get(className);
        PATCHES.put(className, before == null ? patch : Asm.chain(before, patch));
    }

    static {
        // Minecraft's framebuffer reaches the screen without a copy when possible (metal189.world.Present).
        register("net.minecraft.client.shader.Framebuffer", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = Asm.find(cn, "framebufferRenderExt", "func_178038_a", "(IIZ)V");
                if (m == null) return false;
                for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    if (n.getOpcode() != Opcodes.INVOKEVIRTUAL) continue;
                    org.objectweb.asm.tree.MethodInsnNode c = (org.objectweb.asm.tree.MethodInsnNode) n;
                    if (!c.owner.equals("net/minecraft/client/renderer/Tessellator") || !(c.name.equals("draw") || c.name.equals("func_78381_a"))) continue;
                    org.objectweb.asm.tree.InsnList l = new org.objectweb.asm.tree.InsnList();
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 0));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 1));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 2));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 3));
                    l.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/world/Present", "beforeCopy",
                        "(Lnet/minecraft/client/shader/Framebuffer;IIZ)V", false));
                    m.instructions.insertBefore(c, l);
                    return true;
                }
                return false;
            }

            public boolean needsFrames() { return false; }
        });
    }

    static {
        // Render distance past 32 chunks and faster chunk loading (metal189.terrain.Limits).
        register("net.minecraft.server.management.PlayerManager", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = Asm.find(cn, "setPlayerViewRadius", "func_152622_a", "(I)V");
                if (m == null) return false;
                for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    if (n.getOpcode() == Opcodes.BIPUSH && ((org.objectweb.asm.tree.IntInsnNode) n).operand == 32) {
                        m.instructions.set(n, new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Limits", "maxViewRadius", "()I", false));
                        return true;
                    }
                }
                return false;
            }

            public boolean needsFrames() { return false; }
        });
        register("net.minecraft.client.renderer.chunk.ChunkRenderDispatcher", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                int threads = 0, buffers = 0;
                for (MethodNode m : cn.methods) {
                    if (!m.name.equals("<init>") || !m.desc.equals("()V")) continue;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        int op = n.getOpcode();
                        if (op == Opcodes.ICONST_2 && n.getNext() != null && n.getNext().getOpcode() == Opcodes.IF_ICMPGE) {
                            AbstractInsnNode c = new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Limits", "builderThreads", "()I", false);
                            m.instructions.set(n, c);
                            n = c;
                            threads++;
                        } else if (op == Opcodes.ICONST_5) {
                            // the free-buffer queue's capacity and the loop filling it
                            AbstractInsnNode c = new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Limits", "builderBuffers", "()I", false);
                            m.instructions.set(n, c);
                            n = c;
                            buffers++;
                        }
                    }
                }
                return threads == 1 && buffers == 2;
            }

            public boolean needsFrames() { return false; }
        });
        register("net.minecraft.server.integrated.IntegratedServer", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = Asm.find(cn, "tick", "func_71217_p", "()V");
                if (m == null) return false;
                int n = 0;
                for (AbstractInsnNode i = m.instructions.getFirst(); i != null; i = i.getNext()) {
                    if (i.getOpcode() != Opcodes.GETFIELD) continue;
                    String f = ((FieldInsnNode) i).name;
                    if (!f.equals("renderDistanceChunks") && !f.equals("field_151451_c")) continue;
                    m.instructions.insert(i, new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Limits", "serverViewDistance", "(I)I", false));
                    n++;
                }
                return n > 0;
            }

            public boolean needsFrames() { return false; }
        });
        register("net.minecraft.entity.player.EntityPlayerMP", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = Asm.find(cn, "onUpdate", "func_70071_h_", "()V");
                if (m == null) return false;
                for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    // while (iterator1.hasNext() && list.size() < 10)
                    if (n.getOpcode() != Opcodes.BIPUSH || ((org.objectweb.asm.tree.IntInsnNode) n).operand != 10) continue;
                    AbstractInsnNode prev = n.getPrevious();
                    if (!(prev instanceof org.objectweb.asm.tree.MethodInsnNode) || !"size".equals(((org.objectweb.asm.tree.MethodInsnNode) prev).name)) continue;
                    m.instructions.set(n, new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Limits", "chunksPerTick", "()I", false));
                    return true;
                }
                return false;
            }

            public boolean needsFrames() { return false; }
        });
    }

    static {
        // Section placement tables for the terrain search (metal189.terrain.Search.chunkPositions).
        register("net.minecraft.client.renderer.ViewFrustum", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                MethodNode m = Asm.find(cn, "updateChunkPositions", "func_178163_a", "(DD)V");
                if (m == null) return false;
                for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                    if (n.getOpcode() != Opcodes.RETURN) continue;
                    org.objectweb.asm.tree.InsnList l = new org.objectweb.asm.tree.InsnList();
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 0));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.DLOAD, 1));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.DLOAD, 3));
                    l.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Search", "chunkPositions",
                        "(Ljava/lang/Object;DD)V", false));
                    m.instructions.insertBefore(n, l);
                }
                return true;
            }

            public boolean needsFrames() { return false; }
        });
    }

    static {
        // The visibility search's per-section direction sets (metal189.terrain.FacingSet).
        register("net.minecraft.client.renderer.RenderGlobal$ContainerLocalRenderInformation", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (MethodNode m : cn.methods) {
                    if (!m.name.equals("<init>")) continue;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() != Opcodes.INVOKESTATIC) continue;
                        org.objectweb.asm.tree.MethodInsnNode c = (org.objectweb.asm.tree.MethodInsnNode) n;
                        if (!c.owner.equals("java/util/EnumSet") || !c.name.equals("noneOf")) continue;
                        c.owner = "metal189/terrain/FacingSet";
                        c.name = "create";
                        c.desc = "(Ljava/lang/Class;)Ljava/util/Set;";
                        changed = true;
                    }
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        });
    }

    static {
        // Leaves' graphics level is read through Lod.leaves (fast leaves for far sections).
        ClassPatch leaves = new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (MethodNode m : cn.methods) {
                    if (m.name.equals("setGraphicsLevel") || m.name.equals("func_150122_b") || m.name.equals("<init>")) continue;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() != Opcodes.GETFIELD) continue;
                        String f = ((FieldInsnNode) n).name;
                        if (!f.equals("isTransparent") && !f.equals("field_176238_O") && !f.equals("fancyGraphics") && !f.equals("field_150121_P")) continue;
                        // shouldSideBeRendered culls faces between leaves when this answers false
                        boolean side = m.name.equals("shouldSideBeRendered") || m.name.equals("func_176225_a");
                        m.instructions.insert(n, new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Lod",
                            side ? "leavesSide" : "leaves", "(Z)Z", false));
                        changed = true;
                    }
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        };
        register("net.minecraft.block.BlockLeaves", leaves);
        register("net.minecraft.block.BlockLeavesBase", leaves);
    }

    static {
        // Forge 1.8.9 bug: getSkyBlendColour caches its biome-blended sky colour by the
        // camera's X and Z but saves Y as the Z, so the cache never hits and every sky-colour
        // query (several a frame) re-blends up to (2r+1)^2 biomes. Save the Z.
        register("net.minecraftforge.client.ForgeHooksClient", new ClassPatch() {
            public boolean apply(ClassNode cn) {
                boolean changed = false;
                for (MethodNode m : cn.methods) {
                    if (!"getSkyBlendColour".equals(m.name)) continue;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() != Opcodes.PUTSTATIC || !"skyZ".equals(((FieldInsnNode) n).name)) continue;
                        AbstractInsnNode prev = n.getPrevious();
                        if (!(prev instanceof org.objectweb.asm.tree.MethodInsnNode)) continue;
                        org.objectweb.asm.tree.MethodInsnNode call = (org.objectweb.asm.tree.MethodInsnNode) prev;
                        if ("getY".equals(call.name)) { call.name = "getZ"; changed = true; }
                        else if ("func_177956_o".equals(call.name)) { call.name = "func_177952_p"; changed = true; }
                    }
                }
                return changed;
            }

            public boolean needsFrames() { return false; }
        });
    }

    static {
        // Tessellator output goes straight to the engine.
        register("net.minecraft.client.renderer.WorldVertexBufferUploader",
            Asm.replaceBody("draw", "func_181679_a", "(Lnet/minecraft/client/renderer/WorldRenderer;)V",
                "metal189/capture/Tess", "draw", "(Lnet/minecraft/client/renderer/WorldRenderer;)V", false));

        // Terrain: engine-owned section buffers and per-layer draws.
        register("net.minecraft.client.renderer.RenderGlobal", Asm.chain(
            Asm.redirectNew("net/minecraft/client/renderer/RenderList", "metal189/terrain/TerrainContainer"),
            Asm.redirectNew("net/minecraft/client/renderer/VboRenderList", "metal189/terrain/TerrainContainer"),
            // shaders mode: the first-person player casts a shadow
            Asm.injectTail("renderEntities", "func_180446_a",
                "(Lnet/minecraft/entity/Entity;Lnet/minecraft/client/renderer/culling/ICamera;F)V",
                "metal189/world/Phases", "afterEntities", "(F)V", 3),
            // renderEntities' section loops visit only sections with something in them (EntityCull)
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    MethodNode m = Asm.find(cn, "renderEntities", "func_180446_a",
                        "(Lnet/minecraft/entity/Entity;Lnet/minecraft/client/renderer/culling/ICamera;F)V");
                    if (m == null) return false;
                    int lists = 0, sets = 0;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() != Opcodes.INVOKEINTERFACE || !"iterator".equals(((org.objectweb.asm.tree.MethodInsnNode) n).name)) continue;
                        AbstractInsnNode prev = n.getPrevious();
                        if (!(prev instanceof FieldInsnNode) || prev.getOpcode() != Opcodes.GETFIELD) continue;
                        String field = ((FieldInsnNode) prev).name;
                        String target = null, desc = null;
                        if (field.equals("renderInfos") || field.equals("field_72755_R")) {
                            target = lists == 0 ? "entityInfos" : lists == 1 ? "tileEntityInfos" : null;
                            desc = "(Ljava/util/List;)Ljava/util/Iterator;";
                            lists++;
                        } else if (field.equals("setTileEntities") || field.equals("field_181024_n")) {
                            target = sets++ == 0 ? "setIterator" : null;
                            desc = "(Ljava/util/Set;)Ljava/util/Iterator;";
                        }
                        if (target == null) continue;
                        AbstractInsnNode call = new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/world/EntityCull", target, desc, false);
                        m.instructions.set(n, call);
                        n = call;
                    }
                    return lists == 2 && sets == 1;
                }

                public boolean needsFrames() { return false; }
            },
            // setupTerrain's visibility search is metal189.terrain.Search (vanilla's rules, no
            // per-section allocation; rate-limited while the camera is still)
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    MethodNode m = Asm.find(cn, "setupTerrain", "func_174970_a",
                        "(Lnet/minecraft/entity/Entity;DLnet/minecraft/client/renderer/culling/ICamera;IZ)V");
                    if (m == null) return false;
                    for (AbstractInsnNode i = m.instructions.getFirst(); i != null; i = i.getNext()) {
                        if (i.getOpcode() != Opcodes.GETFIELD) continue;
                        String f = ((FieldInsnNode) i).name;
                        if (!f.equals("displayListEntitiesDirty") && !f.equals("field_147595_R")) continue;
                        AbstractInsnNode next = i.getNext();
                        if (next == null || next.getOpcode() != Opcodes.IFEQ) continue;   // the "if (... && dirty)" read
                        org.objectweb.asm.tree.InsnList l = new org.objectweb.asm.tree.InsnList();
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 0));   // this
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 1));   // viewEntity
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.DLOAD, 2));   // partialTicks
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 4));   // camera (after the debug frustum swap)
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 5));   // frameCount
                        l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 6));   // playerSpectator
                        l.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Search", "run",
                            "(ZLnet/minecraft/client/renderer/RenderGlobal;Lnet/minecraft/entity/Entity;DLnet/minecraft/client/renderer/culling/ICamera;IZ)Z", false));
                        m.instructions.insert(i, l);
                        return true;
                    }
                    return false;
                }

                public boolean needsFrames() { return false; }
            },
            // setupTerrain's update scheduling runs only when something it depends on changed
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    MethodNode m = Asm.find(cn, "setupTerrain", "func_174970_a",
                        "(Lnet/minecraft/entity/Entity;DLnet/minecraft/client/renderer/culling/ICamera;IZ)V");
                    if (m == null) return false;
                    AbstractInsnNode clear = null, end = null;
                    for (AbstractInsnNode n = m.instructions.getFirst(); n != null; n = n.getNext()) {
                        if (n.getOpcode() == Opcodes.INVOKEVIRTUAL) {
                            String name = ((org.objectweb.asm.tree.MethodInsnNode) n).name;
                            if (name.equals("clearChunkUpdates") || name.equals("func_178513_e")) clear = n;
                        }
                        if (n.getOpcode() == Opcodes.INVOKEINTERFACE && "addAll".equals(((org.objectweb.asm.tree.MethodInsnNode) n).name)
                                && n.getNext() != null && n.getNext().getOpcode() == Opcodes.POP)
                            end = n.getNext();   // the last one: chunksToUpdate.addAll(set)
                    }
                    if (clear == null || end == null) return false;
                    AbstractInsnNode receiver = clear.getPrevious() != null ? clear.getPrevious().getPrevious() : null;   // aload_0, getfield
                    if (receiver == null || receiver.getOpcode() != Opcodes.ALOAD) return false;
                    org.objectweb.asm.tree.LabelNode skip = new org.objectweb.asm.tree.LabelNode();
                    m.instructions.insert(end, skip);
                    org.objectweb.asm.tree.InsnList l = new org.objectweb.asm.tree.InsnList();
                    l.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Search", "scheduleNow", "()Z", false));
                    l.add(new org.objectweb.asm.tree.JumpInsnNode(Opcodes.IFEQ, skip));
                    m.instructions.insertBefore(receiver, l);
                    return true;
                }

                public boolean needsFrames() { return true; }
            },
            // renderBlockLayer's per-section loop: the layer is drawn from the engine's visible list
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    MethodNode m = Asm.find(cn, "renderBlockLayer", "func_174977_a",
                        "(Lnet/minecraft/util/EnumWorldBlockLayer;DILnet/minecraft/entity/Entity;)I");
                    if (m == null) return false;
                    int n = 0;
                    for (AbstractInsnNode i = m.instructions.getFirst(); i != null; i = i.getNext()) {
                        if (i.getOpcode() != Opcodes.INVOKEINTERFACE || !"size".equals(((org.objectweb.asm.tree.MethodInsnNode) i).name)) continue;
                        AbstractInsnNode prev = i.getPrevious();
                        if (!(prev instanceof FieldInsnNode) || prev.getOpcode() != Opcodes.GETFIELD) continue;
                        String f = ((FieldInsnNode) prev).name;
                        if (!f.equals("renderInfos") && !f.equals("field_72755_R")) continue;
                        AbstractInsnNode call = new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Terrain",
                            "layerLoopSize", "(Ljava/util/List;)I", false);
                        m.instructions.set(i, call);
                        i = call;
                        n++;
                    }
                    return n == 2;
                }

                public boolean needsFrames() { return false; }
            }));
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
                    t.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 2));
                    t.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 3));
                    t.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Terrain", "endBlock",
                        "(Lnet/minecraft/client/renderer/WorldRenderer;Lnet/minecraft/block/state/IBlockState;Lnet/minecraft/util/BlockPos;Lnet/minecraft/world/IBlockAccess;)V", false));
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

        // shaders mode can hide vanilla's underwater "suspended" particles
        register("net.minecraft.client.particle.EffectRenderer",
            Asm.injectHeadCancel("addEffect", "func_78873_a", "(Lnet/minecraft/client/particle/EntityFX;)V",
                "metal189/world/Particles", "cancel", "(Lnet/minecraft/client/particle/EntityFX;)Z", false));

        register("net.minecraft.client.gui.FontRenderer",
            Asm.injectTailThis("readFontTexture", "func_111272_d", "()V",
                "metal189/gui/HdFont", "afterReadFontTexture", "(Lnet/minecraft/client/gui/FontRenderer;)V"));

        register("net.minecraft.client.renderer.texture.TextureMap",
            Asm.injectTailThis("loadTextureAtlas", "func_110571_b", "(Lnet/minecraft/client/resources/IResourceManager;)V",
                "metal189/world/PbrAtlas", "onStitched", "(Lnet/minecraft/client/renderer/texture/TextureMap;)V"));

        register("net.minecraft.client.renderer.chunk.RenderChunk", Asm.chain(
            // sections marked for an update (metal189.terrain.Search.scheduleNow)
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    MethodNode m = Asm.find(cn, "setNeedsUpdate", "func_178575_a", "(Z)V");
                    if (m == null) return false;
                    org.objectweb.asm.tree.InsnList l = new org.objectweb.asm.tree.InsnList();
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ALOAD, 0));
                    l.add(new org.objectweb.asm.tree.VarInsnNode(Opcodes.ILOAD, 1));
                    l.add(new org.objectweb.asm.tree.MethodInsnNode(Opcodes.INVOKESTATIC, "metal189/terrain/Search", "needsUpdate",
                        "(Lnet/minecraft/client/renderer/chunk/RenderChunk;Z)V", false));
                    m.instructions.insert(l);
                    return true;
                }

                public boolean needsFrames() { return false; }
            },
            // how the section was last built (metal189.terrain.Lod)
            new ClassPatch() {
                public boolean apply(ClassNode cn) {
                    cn.fields.add(new org.objectweb.asm.tree.FieldNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_VOLATILE, "metal189$lod", "I", null, null));
                    // the engine's section id (metal189.terrain.Terrain)
                    cn.fields.add(new org.objectweb.asm.tree.FieldNode(Opcodes.ACC_PUBLIC, "metal189$id", "I", null, null));
                    return true;
                }

                public boolean needsFrames() { return false; }
            },
            Asm.injectHeadThisOnly("rebuildChunk", "func_178581_b", "(FFFLnet/minecraft/client/renderer/chunk/ChunkCompileTaskGenerator;)V",
                "metal189/terrain/Terrain", "beginRebuild", "(Lnet/minecraft/client/renderer/chunk/RenderChunk;)V"),
            Asm.injectTailThis("rebuildChunk", "func_178581_b", "(FFFLnet/minecraft/client/renderer/chunk/ChunkCompileTaskGenerator;)V",
                "metal189/terrain/Terrain", "endRebuild", "(Lnet/minecraft/client/renderer/chunk/RenderChunk;)V"),
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
