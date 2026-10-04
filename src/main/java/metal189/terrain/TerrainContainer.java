package metal189.terrain;

import net.minecraft.client.renderer.ChunkRenderContainer;
import net.minecraft.util.EnumWorldBlockLayer;

/** Stand-in for RenderList / VboRenderList: hands visible sections to the engine. */
public class TerrainContainer extends ChunkRenderContainer {
    private double vx, vy, vz;

    @Override
    public void initialize(double x, double y, double z) {
        super.initialize(x, y, z);
        vx = x;
        vy = y;
        vz = z;
    }

    @Override
    public void renderChunkLayer(EnumWorldBlockLayer layer) {
        if (!initialized) return;
        if (renderChunks.isEmpty()) Terrain.renderVisible(layer, vx, vy, vz);   // the usual case (Terrain.layerLoopSize)
        else Terrain.renderLayer(renderChunks, layer, vx, vy, vz);
    }
}
