package metal189.capture;

import java.util.IdentityHashMap;
import java.util.List;
import metal189.engine.Mem;
import metal189.gl.Draw;
import metal189.gl.Formats;
import metal189.gl.Lists;
import metal189.gl.Programs;
import net.minecraft.client.renderer.WorldRenderer;
import net.minecraft.client.renderer.vertex.VertexFormat;
import net.minecraft.client.renderer.vertex.VertexFormatElement;

/** Replacement body of WorldVertexBufferUploader.draw: submits Tessellator geometry directly. */
public final class Tess {
    private Tess() {}

    private static final IdentityHashMap<VertexFormat, Integer> formats = new IdentityHashMap<VertexFormat, Integer>();

    public static int formatId(VertexFormat f) {
        Integer id = formats.get(f);
        if (id != null) return id;
        List<VertexFormatElement> els = f.getElements();
        int[] attrs = new int[els.size() * 5];
        int n = 0;
        for (int i = 0; i < els.size(); i++) {
            VertexFormatElement e = els.get(i);
            int usage;
            switch (e.getUsage()) {
                case POSITION: usage = Formats.POS; break;
                case COLOR: usage = Formats.COLOR; break;
                case NORMAL: usage = Formats.NORMAL; break;
                case UV: usage = e.getIndex() == 0 ? Formats.TEX0 : e.getIndex() == 1 ? Formats.TEX1 : -1; break;
                default: usage = -1;
            }
            if (usage < 0) continue;
            int k = n * 5;
            attrs[k] = usage;
            attrs[k + 1] = e.getType().getGlConstant();
            attrs[k + 2] = e.getElementCount();
            attrs[k + 3] = f.getOffset(i);
            attrs[k + 4] = (usage == Formats.COLOR || usage == Formats.NORMAL) && e.getType().getGlConstant() != 0x1406 ? 1 : 0;
            n++;
        }
        int nid = Formats.register(f.getNextOffset(), attrs, n);
        formats.put(f, nid);
        return nid;
    }

    public static void draw(WorldRenderer wr) {
        int count = wr.getVertexCount();
        if (count > 0 && !Programs.blocksDraw()) {
            VertexFormat f = wr.getVertexFormat();
            int stride = f.getNextOffset();
            Draw.arrays(wr.getDrawMode(), formatId(f), Mem.address(wr.getByteBuffer()), count, count * stride);
        }
        wr.reset();
    }

    static boolean compiling() { return Lists.compiling != null; }
}
