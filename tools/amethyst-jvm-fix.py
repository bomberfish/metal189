#!/usr/bin/env python3
"""Fixes relocInfo::initialize in Amethyst's Java 8 libjvm.dylib (iOS, MirrorMappedCodeCache).

    tools/amethyst-jvm-fix.py path/to/lib/server/libjvm.dylib

With the JIT code cache mirrored (executable view + writable alias), the patched
relocInfo::initialize (angelauramc-openjdk-build f03a5a05) points the CodeSection's
locs_end at the writable alias so relocation data is written there, but never points it
back. For the compilers' scratch buffers, which live in the code cache, locs_end then sits
128 MB (the alias distance) past locs_limit: C2 tries to grow the relocation buffer by that
much ("malloc failed to allocate 134217776 bytes for Chunk::new") and C1's nmethods come out
too big to place ("CodeCache is full" with nearly all of it free).

The rewrite ends the function with locs_end = mirrored_find_rx(locs_end), in the same 188
bytes: the second, redundant mirrored_find_rw(this) call goes. The original instructions
are checked before anything is written. Re-sign the library afterwards.
"""
import struct, subprocess, sys

def symbols(path):
    out = subprocess.check_output(["nm", "-arch", "arm64", path], text=True)
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
    return syms

FN = "__ZN9relocInfo10initializeEP11CodeSectionP10Relocation"
RW = "__ZN2os3Bsd16mirrored_find_rwEPh"
RX = "__ZN2os3Bsd16mirrored_find_rxEPh"

def bl(pc, target):
    return 0x94000000 | (((target - pc) >> 2) & 0x3FFFFFF)

def b_cond(pc, target, cond):      # b.<cond>
    return 0x54000000 | ((((target - pc) >> 2) & 0x7FFFF) << 5) | cond

def cbz_w(pc, target, rt):
    return 0x34000000 | ((((target - pc) >> 2) & 0x7FFFF) << 5) | rt

def b(pc, target):
    return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

LS, NE, HI = 9, 1, 8

def original(f, rw):
    """The function as built (instruction words), for verification."""
    w = [0xA9BD57F6, 0xA9014FF4, 0xA9027BFD, 0x910083FD, 0xAA0203F4, 0xAA0103F3, 0xAA0003F5,
         bl(f + 28, rw), 0x91000816, 0xF9001676, 0xF9400288, 0xF9400108, 0xAA1403E0, 0xAA1303E1,
         0xD63F0100, 0xF9401660, bl(f + 64, rw), 0xEB16001F, b_cond(f + 72, f + 172, LS),
         0xAA0003F4, 0xAA1503E0, bl(f + 84, rw), 0x79400016, 0xAA1503E0, bl(f + 96, rw),
         0x91000808, 0xCB080289, 0xD341FD29, cbz_w(f + 112, f + 164, 9), 0x7100053F,
         b_cond(f + 120, f + 144, NE), 0x7940010A, 0x711FFD5F, b_cond(f + 132, f + 144, HI),
         0x32144D49, b(f + 140, f + 156), 0x32150128, 0x51400509, 0xAA1403E8, 0x79000009,
         0xAA0803E0, 0x78002416, 0xF9001660, 0xA9427BFD, 0xA9414FF4, 0xA8C357F6, 0xD65F03C0]
    return w

def fixed(f, rw, rx):
    w = [0xA9BD57F6, 0xA9014FF4, 0xA9027BFD, 0x910083FD, 0xAA0203F4, 0xAA0103F3, 0xAA0003F5,
         bl(f + 28, rw),                    # x0 = rw(this)
         0x91000816, 0xF9001676,            # data = x0 + 2; locs_end = data
         0xF9400288, 0xF9400108, 0xAA1403E0, 0xAA1303E1, 0xD63F0100,   # reloc->pack_data_to(dest)
         0xF9401660, bl(f + 64, rw),        # x0 = rw(locs_end)
         0xEB16001F, b_cond(f + 72, f + 160, LS),
         0xAA0003F4, 0xAA1503E0, bl(f + 84, rw),   # x20 = data_limit; x0 = rw(this)
         0x79400016,                        # suffix = *rw(this)
         0x91000808,                        # (the second rw(this) call was here)
         0xCB080289, 0xD341FD29, cbz_w(f + 104, f + 156, 9), 0x7100053F,
         b_cond(f + 112, f + 136, NE), 0x7940010A, 0x711FFD5F, b_cond(f + 124, f + 136, HI),
         0x32144D49, b(f + 132, f + 148), 0x32150128, 0x51400509, 0xAA1403E8, 0x79000009,
         0xAA0803E0, 0x78002416,
         bl(f + 160, rx),                   # x0 = rx(final locs_end)   <- also the b.ls target
         0xF9001660,                        # locs_end = x0
         0xA9427BFD, 0xA9414FF4, 0xA8C357F6, 0xD65F03C0,
         0xD503201F]                        # nop (same size as before)
    return w

def main():
    path = sys.argv[1]
    syms = symbols(path)
    f, rw, rx = syms[FN], syms[RW], syms[RX]
    data = bytearray(open(path, "rb").read())   # __TEXT at file offset 0: address = offset
    n = 47
    cur = list(struct.unpack_from(f"<{n}I", data, f))
    want_old, want_new = original(f, rw), fixed(f, rw, rx)
    assert len(want_old) == n and len(want_new) == n
    if cur == want_new:
        print("already fixed")
        return
    if cur != want_old:
        bad = [i for i in range(n) if cur[i] != want_old[i]]
        sys.exit(f"relocInfo::initialize is not the expected build (differs at {bad[:5]}); not patching")
    struct.pack_into(f"<{n}I", data, f, *want_new)
    open(path, "wb").write(data)
    print(f"patched relocInfo::initialize at {f:#x}")

if __name__ == "__main__":
    main()
