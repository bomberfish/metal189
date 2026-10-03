package m189compat;

import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.FontRenderer;
import net.minecraft.client.gui.Gui;
import net.minecraft.client.gui.ScaledResolution;
import net.minecraft.client.renderer.GlStateManager;
import net.minecraft.client.renderer.RenderGlobal;
import net.minecraft.client.renderer.RenderHelper;
import net.minecraft.client.renderer.Tessellator;
import net.minecraft.client.renderer.WorldRenderer;
import net.minecraft.client.renderer.entity.RenderManager;
import net.minecraft.client.renderer.vertex.DefaultVertexFormats;
import net.minecraft.entity.Entity;
import net.minecraft.entity.item.EntityArmorStand;
import net.minecraft.entity.monster.EntityZombie;
import net.minecraft.entity.passive.EntityPig;
import net.minecraft.init.Items;
import net.minecraft.item.ItemStack;
import net.minecraft.util.AxisAlignedBB;
import net.minecraft.util.ResourceLocation;
import net.minecraftforge.client.event.RenderGameOverlayEvent;
import net.minecraftforge.client.event.RenderWorldLastEvent;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.common.eventhandler.SubscribeEvent;
import org.lwjgl.BufferUtils;
import org.lwjgl.opengl.GL11;
import org.lwjgl.util.glu.GLU;

/**
 * Test-only "mod" exercising GL the way simple 1.8.9 mods do (ESP boxes, tracers,
 * beams, circles, points, immediate mode, display lists, client arrays, wireframe,
 * stencil, dashed lines, HUD panels, scaled text, items, scissor, 2D projection).
 * Lives outside metal189.* so its LWJGL calls are redirected like any mod's. Inert
 * unless the test driver enables it ("compat on").
 */
public final class CompatScene {
    private static CompatScene instance;

    public static void enable() {
        if (instance == null) {
            instance = new CompatScene();
            MinecraftForge.EVENT_BUS.register(instance);
        }
    }

    private int displayList = -1;
    private final FloatBuffer modelview = BufferUtils.createFloatBuffer(16);
    private final FloatBuffer projection = BufferUtils.createFloatBuffer(16);
    private final IntBuffer viewport = BufferUtils.createIntBuffer(16);
    private final List<float[]> projected = new ArrayList<float[]>();

    // ------------------------------------------------------------------ world

    @SubscribeEvent
    public void onWorldLast(RenderWorldLastEvent e) {
        Minecraft mc = Minecraft.getMinecraft();
        if (mc.theWorld == null) return;
        RenderManager rm = mc.getRenderManager();
        double vx = rm.viewerPosX, vy = rm.viewerPosY, vz = rm.viewerPosZ;
        Tessellator t = Tessellator.getInstance();
        WorldRenderer wr = t.getWorldRenderer();

        GlStateManager.pushMatrix();
        GlStateManager.translate(-vx, -vy, -vz);
        GlStateManager.disableTexture2D();
        GlStateManager.disableLighting();
        GlStateManager.enableBlend();
        GlStateManager.tryBlendFuncSeparate(770, 771, 1, 0);

        List<Entity> targets = new ArrayList<Entity>();
        for (Entity en : mc.theWorld.loadedEntityList)
            if (en instanceof EntityArmorStand || en instanceof EntityPig || en instanceof EntityZombie) targets.add(en);

        // 1. filled translucent ESP boxes (depth tested, no depth writes)
        GlStateManager.depthMask(false);
        for (Entity en : targets) {
            AxisAlignedBB bb = en.getEntityBoundingBox().expand(0.05, 0.05, 0.05);
            filledBox(wr, t, bb, 0.2f, 0.6f, 1.0f, 0.25f);
        }
        // 2. outlined boxes through walls, smooth wide lines
        GlStateManager.disableDepth();
        GL11.glEnable(GL11.GL_LINE_SMOOTH);
        GL11.glLineWidth(2.5f);
        for (Entity en : targets) RenderGlobal.drawOutlinedBoundingBox(en.getEntityBoundingBox(), 255, 60, 60, 255);
        // 3. tracers from in front of the camera
        GL11.glLineWidth(1.5f);
        wr.begin(GL11.GL_LINES, DefaultVertexFormats.POSITION_COLOR);
        for (Entity en : targets) {
            wr.pos(vx, vy + mc.thePlayer.getEyeHeight() - 0.2, vz - 1.0).color(1f, 1f, 0f, 1f).endVertex();
            wr.pos(en.posX, en.posY + en.height / 2, en.posZ).color(1f, 1f, 0f, 1f).endVertex();
        }
        t.draw();
        GL11.glDisable(GL11.GL_LINE_SMOOTH);
        GL11.glLineWidth(1f);
        GlStateManager.enableDepth();

        // 4. a waypoint beam (two crossed translucent quads)
        GlStateManager.disableCull();
        double bx = 4.5, bz = -10.5;
        wr.begin(GL11.GL_QUADS, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(bx - 0.3, 4, bz).color(0.3f, 1f, 0.3f, 0.5f).endVertex();
        wr.pos(bx + 0.3, 4, bz).color(0.3f, 1f, 0.3f, 0.5f).endVertex();
        wr.pos(bx + 0.3, 40, bz).color(0.3f, 1f, 0.3f, 0.0f).endVertex();
        wr.pos(bx - 0.3, 40, bz).color(0.3f, 1f, 0.3f, 0.0f).endVertex();
        wr.pos(bx, 4, bz - 0.3).color(0.3f, 1f, 0.3f, 0.5f).endVertex();
        wr.pos(bx, 4, bz + 0.3).color(0.3f, 1f, 0.3f, 0.5f).endVertex();
        wr.pos(bx, 40, bz + 0.3).color(0.3f, 1f, 0.3f, 0.0f).endVertex();
        wr.pos(bx, 40, bz - 0.3).color(0.3f, 1f, 0.3f, 0.0f).endVertex();
        t.draw();
        GlStateManager.enableCull();

        // 5. circle (line loop) and translucent disc (triangle fan) on the ground
        double cx = -3.5, cy = 4.02, cz = -7.5;
        GL11.glLineWidth(2f);
        wr.begin(GL11.GL_LINE_LOOP, DefaultVertexFormats.POSITION_COLOR);
        for (int i = 0; i < 64; i++) {
            double a = i * Math.PI * 2 / 64;
            wr.pos(cx + Math.cos(a) * 1.5, cy, cz + Math.sin(a) * 1.5).color(1f, 0.5f, 0f, 1f).endVertex();
        }
        t.draw();
        GL11.glLineWidth(1f);
        wr.begin(GL11.GL_TRIANGLE_FAN, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(cx, cy, cz).color(1f, 0.5f, 0f, 0.4f).endVertex();
        for (int i = 0; i <= 32; i++) {
            double a = -i * Math.PI * 2 / 32;
            wr.pos(cx + Math.cos(a) * 1.2, cy, cz + Math.sin(a) * 1.2).color(1f, 0.5f, 0f, 0.1f).endVertex();
        }
        t.draw();

        // 6. points
        GL11.glPointSize(6f);
        wr.begin(GL11.GL_POINTS, DefaultVertexFormats.POSITION_COLOR);
        for (int i = 0; i < 5; i++) wr.pos(-2 + i, 5.5, -5.5).color(1f, 0f, 1f, 1f).endVertex();
        t.draw();
        GL11.glPointSize(1f);

        // 7. immediate mode with per-vertex colour
        GL11.glBegin(GL11.GL_TRIANGLES);
        GL11.glColor4f(1f, 0f, 0f, 1f);
        GL11.glVertex3d(1.5, 4.1, -4.0);
        GL11.glColor4f(0f, 1f, 0f, 1f);
        GL11.glVertex3d(3.0, 4.1, -4.0);
        GL11.glColor4f(0f, 0f, 1f, 1f);
        GL11.glVertex3d(2.25, 5.4, -4.0);
        GL11.glEnd();

        // 8. display list compiled once
        if (displayList < 0) {
            displayList = GL11.glGenLists(1);
            GL11.glNewList(displayList, GL11.GL_COMPILE);
            GL11.glBegin(GL11.GL_QUADS);
            GL11.glColor4f(0.9f, 0.9f, 0.2f, 0.8f);
            GL11.glVertex3d(-1.0, 4.1, -4.0);
            GL11.glVertex3d(0.0, 4.1, -4.0);
            GL11.glVertex3d(0.0, 5.1, -4.0);
            GL11.glVertex3d(-1.0, 5.1, -4.0);
            GL11.glEnd();
            GL11.glEndList();
        }
        GL11.glCallList(displayList);

        // 9. client-side vertex array
        FloatBuffer va = BufferUtils.createFloatBuffer(12);
        va.put(new float[] {-2.5f, 4.1f, -4f, -1.5f, 4.1f, -4f, -1.5f, 5.1f, -4f, -2.5f, 5.1f, -4f}).flip();
        GlStateManager.color(0.2f, 0.9f, 0.9f, 0.8f);
        GL11.glEnableClientState(GL11.GL_VERTEX_ARRAY);
        GL11.glVertexPointer(3, 0, va);
        GL11.glDrawArrays(GL11.GL_QUADS, 0, 4);
        GL11.glDisableClientState(GL11.GL_VERTEX_ARRAY);

        // 10. wireframe box
        GL11.glPolygonMode(GL11.GL_FRONT_AND_BACK, GL11.GL_LINE);
        filledBox(wr, t, new AxisAlignedBB(3.5, 4.0, -6.5, 4.5, 5.0, -5.5), 1f, 1f, 1f, 1f);
        GL11.glPolygonMode(GL11.GL_FRONT_AND_BACK, GL11.GL_FILL);

        // 11. dashed line
        GL11.glEnable(GL11.GL_LINE_STIPPLE);
        GL11.glLineStipple(2, (short) 0x00FF);
        GL11.glLineWidth(2f);
        wr.begin(GL11.GL_LINES, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(-4, 4.05, -3).color(1f, 1f, 1f, 1f).endVertex();
        wr.pos(4, 4.05, -3).color(1f, 1f, 1f, 1f).endVertex();
        t.draw();
        GL11.glLineWidth(1f);
        GL11.glDisable(GL11.GL_LINE_STIPPLE);

        // 12. stencil: a quad drawn only inside a disc mask
        net.minecraft.client.shader.Framebuffer fb = mc.getFramebuffer();
        if (!fb.isStencilEnabled()) fb.enableStencil();
        GL11.glEnable(GL11.GL_STENCIL_TEST);
        GL11.glClear(GL11.GL_STENCIL_BUFFER_BIT);
        GL11.glStencilFunc(GL11.GL_ALWAYS, 1, 0xFF);
        GL11.glStencilOp(GL11.GL_KEEP, GL11.GL_KEEP, GL11.GL_REPLACE);
        GL11.glStencilMask(0xFF);
        GlStateManager.colorMask(false, false, false, false);
        wr.begin(GL11.GL_TRIANGLE_FAN, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(6.0, 5.0, -6.0).color(1f, 1f, 1f, 1f).endVertex();
        for (int i = 0; i <= 32; i++) {
            double a = i * Math.PI * 2 / 32;
            wr.pos(6.0 + Math.cos(a) * 0.8, 5.0 + Math.sin(a) * 0.8, -6.0).color(1f, 1f, 1f, 1f).endVertex();
        }
        t.draw();
        GlStateManager.colorMask(true, true, true, true);
        GL11.glStencilFunc(GL11.GL_EQUAL, 1, 0xFF);
        GL11.glStencilOp(GL11.GL_KEEP, GL11.GL_KEEP, GL11.GL_KEEP);
        wr.begin(GL11.GL_QUADS, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(5.0, 4.0, -6.0).color(1f, 0.2f, 0.8f, 1f).endVertex();
        wr.pos(7.0, 4.0, -6.0).color(1f, 0.2f, 0.8f, 1f).endVertex();
        wr.pos(7.0, 6.0, -6.0).color(0.2f, 0.2f, 1f, 1f).endVertex();
        wr.pos(5.0, 6.0, -6.0).color(0.2f, 0.2f, 1f, 1f).endVertex();
        t.draw();
        GL11.glDisable(GL11.GL_STENCIL_TEST);

        GlStateManager.depthMask(true);
        GlStateManager.enableTexture2D();

        // 13. billboarded world-space text through walls
        GlStateManager.pushMatrix();
        GlStateManager.translate(0.5, 6.5, -6.5);
        GlStateManager.rotate(-rm.playerViewY, 0f, 1f, 0f);
        GlStateManager.rotate(rm.playerViewX, 1f, 0f, 0f);
        GlStateManager.scale(-0.03f, -0.03f, 0.03f);
        GlStateManager.disableDepth();
        FontRenderer fr = mc.fontRendererObj;
        String label = "§bworld text §c❤ 20";
        fr.drawStringWithShadow(label, -fr.getStringWidth(label) / 2f, 0, 0xFFFFFFFF);
        GlStateManager.enableDepth();
        GlStateManager.popMatrix();

        GlStateManager.disableBlend();
        GlStateManager.popMatrix();

        // 14. capture matrices for 2D projection in the HUD (like 2D ESP mods)
        modelview.clear();
        projection.clear();
        viewport.clear();
        GL11.glGetFloat(GL11.GL_MODELVIEW_MATRIX, modelview);
        GL11.glGetFloat(GL11.GL_PROJECTION_MATRIX, projection);
        GL11.glGetInteger(GL11.GL_VIEWPORT, viewport);
        projected.clear();
        FloatBuffer win = BufferUtils.createFloatBuffer(3);
        for (Entity en : targets) {
            win.clear();
            if (GLU.gluProject((float) (en.posX - vx), (float) (en.posY + en.height + 0.3 - vy), (float) (en.posZ - vz),
                    modelview, projection, viewport, win) && win.get(2) < 1f)
                projected.add(new float[] {win.get(0), win.get(1)});
        }
    }

    private static void filledBox(WorldRenderer wr, Tessellator t, AxisAlignedBB b, float r, float g, float bl, float a) {
        wr.begin(GL11.GL_QUADS, DefaultVertexFormats.POSITION_COLOR);
        double[][] q = {
            {b.minX, b.minY, b.minZ, b.maxX, b.minY, b.minZ, b.maxX, b.maxY, b.minZ, b.minX, b.maxY, b.minZ},
            {b.minX, b.minY, b.maxZ, b.minX, b.maxY, b.maxZ, b.maxX, b.maxY, b.maxZ, b.maxX, b.minY, b.maxZ},
            {b.minX, b.minY, b.minZ, b.minX, b.maxY, b.minZ, b.minX, b.maxY, b.maxZ, b.minX, b.minY, b.maxZ},
            {b.maxX, b.minY, b.minZ, b.maxX, b.minY, b.maxZ, b.maxX, b.maxY, b.maxZ, b.maxX, b.maxY, b.minZ},
            {b.minX, b.maxY, b.minZ, b.maxX, b.maxY, b.minZ, b.maxX, b.maxY, b.maxZ, b.minX, b.maxY, b.maxZ},
            {b.minX, b.minY, b.minZ, b.minX, b.minY, b.maxZ, b.maxX, b.minY, b.maxZ, b.maxX, b.minY, b.minZ},
        };
        for (double[] f : q)
            for (int i = 0; i < 4; i++) wr.pos(f[i * 3], f[i * 3 + 1], f[i * 3 + 2]).color(r, g, bl, a).endVertex();
        t.draw();
    }

    // ------------------------------------------------------------------ HUD

    @SubscribeEvent
    public void onHud(RenderGameOverlayEvent.Post e) {
        if (e.type != RenderGameOverlayEvent.ElementType.ALL) return;
        Minecraft mc = Minecraft.getMinecraft();
        ScaledResolution sr = e.resolution;
        FontRenderer fr = mc.fontRendererObj;

        // 15. translucent panel, gradient, text at half scale with shadow
        Gui.drawRect(4, 4, 124, 64, 0x90000000);
        GlStateManager.disableTexture2D();
        GlStateManager.enableBlend();
        Tessellator t = Tessellator.getInstance();
        WorldRenderer wr = t.getWorldRenderer();
        GlStateManager.shadeModel(GL11.GL_SMOOTH);
        wr.begin(GL11.GL_QUADS, DefaultVertexFormats.POSITION_COLOR);
        wr.pos(124, 4, 0).color(0f, 0.6f, 1f, 0.8f).endVertex();
        wr.pos(4, 4, 0).color(1f, 0.2f, 0.6f, 0.8f).endVertex();
        wr.pos(4, 8, 0).color(1f, 0.2f, 0.6f, 0.8f).endVertex();
        wr.pos(124, 8, 0).color(0f, 0.6f, 1f, 0.8f).endVertex();
        t.draw();
        GlStateManager.shadeModel(GL11.GL_FLAT);
        GlStateManager.enableTexture2D();
        fr.drawStringWithShadow("§lCompat HUD", 8, 12, 0xFFFFFF);
        GL11.glPushMatrix();
        GL11.glScalef(0.5f, 0.5f, 1f);
        fr.drawString("half-scale text 123", 16, 46, 0xFFAAAAAA);
        GL11.glPopMatrix();

        // 16. items in the HUD (armor-HUD style)
        RenderHelper.enableGUIStandardItemLighting();
        ItemStack[] stacks = {new ItemStack(Items.diamond_sword), new ItemStack(Items.golden_apple, 12), new ItemStack(Items.iron_chestplate)};
        stacks[2].setItemDamage(120);
        for (int i = 0; i < stacks.length; i++) {
            mc.getRenderItem().renderItemAndEffectIntoGUI(stacks[i], 8 + i * 20, 38);
            mc.getRenderItem().renderItemOverlays(fr, stacks[i], 8 + i * 20, 38);
        }
        RenderHelper.disableStandardItemLighting();

        // 17. textured rect from a resource
        mc.getTextureManager().bindTexture(new ResourceLocation("textures/gui/icons.png"));
        GlStateManager.color(1f, 1f, 1f, 1f);
        GlStateManager.enableBlend();
        mc.ingameGUI.drawTexturedModalRect(80, 40, 52, 0, 9, 9);
        mc.ingameGUI.drawTexturedModalRect(92, 40, 16, 0, 9, 9);

        // 18. scissored panel (content overflows the clip)
        int f = sr.getScaleFactor();
        int px = sr.getScaledWidth() - 104, py = 4, pw = 100, ph = 30;
        Gui.drawRect(px, py, px + pw, py + ph, 0x80203040);
        GL11.glEnable(GL11.GL_SCISSOR_TEST);
        GL11.glScissor(px * f, mc.displayHeight - (py + ph) * f, pw * f, ph * f);
        Gui.drawRect(px - 20, py + 10, px + pw + 20, py + 20, 0xFFFF8800);
        fr.drawString("this line is clipped by the scissor box", px + 2, py + 2, 0xFFFFFF);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);

        // 19. rounded corner via GL_POLYGON
        GlStateManager.disableTexture2D();
        GlStateManager.color(0.3f, 0.9f, 0.4f, 0.9f);
        GL11.glBegin(GL11.GL_POLYGON);
        for (int i = 0; i <= 16; i++) {
            double a = i * Math.PI * 0.5 / 16;
            GL11.glVertex2d(140 + Math.cos(a) * 12, 16 - Math.sin(a) * 12);
        }
        GL11.glVertex2d(140, 16);
        GL11.glEnd();

        // 20. 2D ESP markers at projected entity positions
        float sx = (float) sr.getScaledWidth() / mc.displayWidth, sy = (float) sr.getScaledHeight() / mc.displayHeight;
        for (float[] p : projected) {
            float x = p[0] * sx, y = sr.getScaledHeight() - p[1] * sy;
            Gui.drawRect((int) x - 3, (int) y - 3, (int) x + 3, (int) y + 3, 0xFF00FF00);
        }
        GlStateManager.enableTexture2D();
        GlStateManager.color(1f, 1f, 1f, 1f);
    }
}
