package metal189.engine;

/**
 * Growable native buffer holding one frame's command stream. Records are
 * 4-byte aligned: header word = opcode | (lengthInWords << 16), then payload.
 * The layout mirrors native/src/commands.h.
 */
public final class CmdBuffer {
    private long base;
    private long cap;
    private long pos;

    public CmdBuffer(long capacity) {
        cap = capacity;
        base = Mem.malloc(cap);
    }

    public long base() { return base; }
    public int size() { return (int) pos; }
    public void reset() { pos = 0; }

    /** Starts a record of {@code words} words (including the header); returns the payload address. */
    public long begin(int op, int words) {
        long need = (long) words << 2;
        if (pos + need > cap) grow(need);
        long p = base + pos;
        Mem.U.putInt(p, (op & 0xFFFF) | (words << 16));
        pos += need;
        return p + 4;
    }

    private void grow(long need) {
        long ncap = Math.max(cap * 2, pos + need + 4096);
        long nb = Mem.malloc(ncap);
        Mem.copy(base, nb, pos);
        Mem.free(base);
        base = nb;
        cap = ncap;
    }
}
