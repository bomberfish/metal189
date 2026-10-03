#!/usr/bin/env python3
"""Tiles images into a grid: montage.py out.png cols img1 img2 ..."""
import sys
from PIL import Image
out, cols, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ims = [Image.open(f).convert('RGB') for f in files]
w, h = ims[0].size
scale = 0.5 if w > 1000 else 1.0
w2, h2 = int(w * scale), int(h * scale)
rows = (len(ims) + cols - 1) // cols
m = Image.new('RGB', (w2 * cols, h2 * rows))
for i, im in enumerate(ims):
    m.paste(im.resize((w2, h2)), ((i % cols) * w2, (i // cols) * h2))
m.save(out)
