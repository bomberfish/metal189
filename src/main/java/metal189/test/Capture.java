package metal189.test;

import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import javax.imageio.ImageIO;
import metal189.engine.Native;
import net.minecraft.client.Minecraft;
import net.minecraft.client.shader.Framebuffer;

/** Captures Minecraft's main framebuffer (the final image before the screen blit). */
final class Capture {
    private Capture() {}

    static boolean metalFramebuffer(String path) {
        Framebuffer fb = Minecraft.getMinecraft().getFramebuffer();
        int tex = fb != null && fb.framebufferTexture > 0 ? fb.framebufferTexture : 0;
        return Native.capture(tex, path);
    }

    static boolean glFramebuffer(String path) {
        try {
            Framebuffer fb = Minecraft.getMinecraft().getFramebuffer();
            int w = fb.framebufferTextureWidth, h = fb.framebufferTextureHeight;
            IntBuffer buf = java.nio.ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder()).asIntBuffer();
            org.lwjgl.opengl.GL11.glBindTexture(org.lwjgl.opengl.GL11.GL_TEXTURE_2D, fb.framebufferTexture);
            org.lwjgl.opengl.GL11.glPixelStorei(org.lwjgl.opengl.GL11.GL_PACK_ALIGNMENT, 1);
            org.lwjgl.opengl.GL11.glGetTexImage(org.lwjgl.opengl.GL11.GL_TEXTURE_2D, 0, 0x80E1, 0x8367, buf);
            int[] px = new int[w * h];
            buf.get(px);
            BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) img.setRGB(x, h - 1 - y, px[y * w + x] & 0xFFFFFF);
            }
            return ImageIO.write(img, "png", new File(path));
        } catch (Exception e) {
            Native.LOG.error("metal189-test: GL capture failed", e);
            return false;
        }
    }
}
