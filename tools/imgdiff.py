#!/usr/bin/env python3
"""Compares two captures: prints difference statistics and writes an amplified diff image."""
import sys
import numpy as np
from PIL import Image

a = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.int32)
b = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(np.int32)
if a.shape != b.shape:
    print('size mismatch', a.shape, b.shape); sys.exit(1)
d = np.abs(a - b)
m = d.max(axis=2)
n = m.size
print('pixels: %d  identical: %.3f%%  >2: %.3f%%  >8: %.3f%%  >32: %.3f%%  max: %d  mean: %.4f' % (
    n, 100.0 * (m == 0).sum() / n, 100.0 * (m > 2).sum() / n, 100.0 * (m > 8).sum() / n,
    100.0 * (m > 32).sum() / n, m.max(), d.mean()))
if len(sys.argv) > 3:
    vis = np.clip(m * 8, 0, 255).astype(np.uint8)
    Image.fromarray(vis).save(sys.argv[3])
    ys, xs = np.nonzero(m > 8)
    if len(xs):
        print('bbox of >8 diffs: x %d..%d  y %d..%d' % (xs.min(), xs.max(), ys.min(), ys.max()))
