package metal189.terrain;

import java.util.AbstractSet;
import java.util.Collection;
import java.util.Iterator;
import java.util.NoSuchElementException;
import java.util.Set;
import net.minecraft.util.EnumFacing;

/**
 * The directions a visibility search took to reach a section
 * (RenderGlobal.ContainerLocalRenderInformation.setFacing, patched in metal189.core.Patches):
 * a bit mask instead of an EnumSet, which costs a class lookup and a copy loop per section
 * visited, tens of thousands of times per search at long render distances.
 */
public final class FacingSet extends AbstractSet<EnumFacing> {
    private int mask;

    /** Replaces EnumSet.noneOf(EnumFacing.class). */
    @SuppressWarnings("rawtypes")
    public static Set create(Class type) {
        return new FacingSet();
    }

    @Override public boolean contains(Object o) {
        return o instanceof EnumFacing && (mask & (1 << ((EnumFacing) o).ordinal())) != 0;
    }

    @Override public boolean add(EnumFacing f) {
        int b = 1 << f.ordinal();
        boolean changed = (mask & b) == 0;
        mask |= b;
        return changed;
    }

    @Override public boolean addAll(Collection<? extends EnumFacing> c) {
        if (c instanceof FacingSet) {
            int old = mask;
            mask |= ((FacingSet) c).mask;
            return mask != old;
        }
        return super.addAll(c);
    }

    @Override public boolean remove(Object o) {
        if (!contains(o)) return false;
        mask &= ~(1 << ((EnumFacing) o).ordinal());
        return true;
    }

    @Override public void clear() { mask = 0; }

    @Override public int size() { return Integer.bitCount(mask); }

    @Override public boolean isEmpty() { return mask == 0; }

    @Override public Iterator<EnumFacing> iterator() {
        return new Iterator<EnumFacing>() {
            private int left = mask, last = -1;
            private final EnumFacing[] values = EnumFacing.values();

            public boolean hasNext() { return left != 0; }

            public EnumFacing next() {
                if (left == 0) throw new NoSuchElementException();
                last = Integer.numberOfTrailingZeros(left);
                left &= left - 1;
                return values[last];
            }

            public void remove() {
                if (last < 0) throw new IllegalStateException();
                mask &= ~(1 << last);
                last = -1;
            }
        };
    }
}
