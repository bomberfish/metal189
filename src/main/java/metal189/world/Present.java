package metal189.world;

import metal189.engine.Cmd;
import metal189.engine.Engine;
import metal189.engine.Mem;
import metal189.gl.Draw;
import metal189.gl.Targets;
import net.minecraft.client.Minecraft;
import net.minecraft.client.shader.Framebuffer;

/**
 * Before Framebuffer.framebufferRenderExt draws Minecraft's framebuffer onto the screen
 * (patched in metal189.core.Patches): tells the engine which texture the coming full-screen
 * draw copies, so it can present that texture instead of copying it (frame_exec.mm
 * presentWithoutCopy). Vanilla's state changes around the draw still happen.
 */
public final class Present {
    private Present() {}

    public static void beforeCopy(Framebuffer fb, int width, int height, boolean opaque) {
        if (!opaque || Targets.drawFbo != 0) return;
        if (fb != Minecraft.getMinecraft().getFramebuffer()) return;
        if (fb.framebufferTextureWidth != fb.framebufferWidth || fb.framebufferTextureHeight != fb.framebufferHeight) return;
        if (fb.framebufferWidth != width || fb.framebufferHeight != height) return;
        Draw.flush();
        long p = Engine.cmd.begin(Cmd.PRESENT_TEX, 2);
        Mem.putInt(p, fb.framebufferTexture);
    }
}
