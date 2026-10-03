package metal189.world;

import metal189.engine.Mem;
import metal189.engine.Native;
import net.minecraft.block.Block;
import net.minecraft.block.BlockBush;
import net.minecraft.block.BlockDoublePlant;
import net.minecraft.block.BlockLilyPad;
import net.minecraft.block.BlockGlass;
import net.minecraft.block.BlockLeaves;
import net.minecraft.block.BlockLiquid;
import net.minecraft.block.BlockPane;
import net.minecraft.block.BlockStainedGlass;
import net.minecraft.block.BlockStainedGlassPane;
import net.minecraft.block.BlockVine;
import net.minecraft.block.material.Material;
import net.minecraft.block.state.IBlockState;
import net.minecraft.init.Blocks;

/**
 * Per block-state material classification for the advanced pipeline, indexed
 * by Block.getStateId (the id stamped into terrain vertices).
 * Ids: 0 default, 1 leaves/vines, 2 water, 3 emissive, 4 metal, 5 glass, 6 lava, (7 entities),
 * 8 plant, 9 double plant lower half, 10 double plant upper half.
 */
public final class Materials {
    private Materials() {}

    private static boolean uploaded;

    public static void upload() {
        if (uploaded) return;
        uploaded = true;
        long mat = Mem.malloc(65536), emi = Mem.malloc(65536);
        for (Block b : Block.blockRegistry) {
            for (IBlockState state : b.getBlockState().getValidStates()) {
                int id = Block.getStateId(state);
                if (id < 0 || id >= 65536) continue;
                int m = classify(b, state);
                int light = b.getLightValue();
                int e = light > 0 ? Math.min(255, light * 17) : 0;
                if (b == Blocks.lava || b == Blocks.flowing_lava) m = 6;
                Mem.U.putByte(mat + id, (byte) m);
                Mem.U.putByte(emi + id, (byte) e);
            }
        }
        Native.advSetTables(mat, emi);
        Mem.free(mat);
        Mem.free(emi);
    }

    private static int classify(Block b, IBlockState state) {
        Material m = b.getMaterial();
        if (b instanceof BlockLiquid) return m == Material.water ? 2 : 6;
        if (b instanceof BlockDoublePlant)
            return state.getValue(BlockDoublePlant.HALF) == BlockDoublePlant.EnumBlockHalf.UPPER ? 10 : 9;
        if (b instanceof BlockLilyPad) return 0;
        if (b instanceof BlockBush) return 8;
        if (b instanceof BlockLeaves || b instanceof BlockVine || m == Material.leaves || m == Material.vine) return 1;
        if (b instanceof BlockGlass || b instanceof BlockStainedGlass || b instanceof BlockPane
                || b instanceof BlockStainedGlassPane || m == Material.glass || m == Material.ice || m == Material.packedIce) return 5;
        if (b == Blocks.iron_block || b == Blocks.gold_block || b == Blocks.diamond_block || b == Blocks.emerald_block
                || b == Blocks.iron_bars || b == Blocks.rail || b == Blocks.golden_rail || b == Blocks.activator_rail
                || b == Blocks.detector_rail || b == Blocks.cauldron || b == Blocks.hopper || b == Blocks.anvil) return 4;
        if (b.getLightValue() > 0) return 3;
        return 0;
    }
}
