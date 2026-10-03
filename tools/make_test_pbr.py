#!/usr/bin/env python3
"""Builds a small LabPBR test resource pack from vanilla textures (normals from
luminance, hand-picked smoothness/F0, metals for iron/gold) for testing."""
import io, json, sys, zipfile
import numpy as np
from PIL import Image

JAR = sys.argv[1]
OUT = sys.argv[2]
# name: (smoothness 0-1, f0 byte (230+ = metal), normal strength, porosity)
BLOCKS = {
    'stone': (0.35, 12, 2.5, 0), 'cobblestone': (0.25, 10, 4.0, 40), 'stonebrick': (0.4, 12, 3.0, 20),
    'planks_oak': (0.3, 10, 2.0, 30), 'brick': (0.3, 11, 3.5, 30), 'sand': (0.15, 10, 1.5, 60),
    'iron_block': (0.75, 230, 1.5, 0), 'gold_block': (0.85, 231, 1.5, 0), 'diamond_block': (0.9, 40, 1.5, 0),
    'quartz_block_side': (0.9, 15, 1.0, 0), 'obsidian': (0.95, 15, 1.0, 0), 'log_oak': (0.2, 10, 3.0, 40),
    'gravel': (0.1, 10, 3.5, 60), 'dirt': (0.05, 10, 2.5, 64), 'grass_top': (0.15, 10, 2.0, 50),
}

def normal_map(img, strength):
    a = np.asarray(img.convert('RGBA')).astype(np.float32) / 255.0
    lum = (a[..., 0] * 0.3 + a[..., 1] * 0.59 + a[..., 2] * 0.11)
    h, w = lum.shape
    # wrapped Sobel (textures tile)
    gx = (np.roll(lum, -1, 1) - np.roll(lum, 1, 1)) * 0.5
    gy = (np.roll(lum, -1, 0) - np.roll(lum, 1, 0)) * 0.5
    nx, ny = -gx * strength, gy * strength          # OpenGL convention: +y up the image
    nz = np.ones_like(nx)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny = nx / l, ny / l
    out = np.zeros((h, w, 4), np.uint8)
    out[..., 0] = np.clip((nx * 0.5 + 0.5) * 255, 0, 255)
    out[..., 1] = np.clip((ny * 0.5 + 0.5) * 255, 0, 255)
    out[..., 2] = np.clip(255 * (0.75 + 0.25 * lum / max(lum.max(), 1e-3)), 0, 255)   # AO
    out[..., 3] = np.clip(lum * 255, 1, 255)                                            # height
    return Image.fromarray(out, 'RGBA')

def specular_map(img, smooth, f0, porosity):
    a = np.asarray(img.convert('RGBA')).astype(np.float32) / 255.0
    lum = (a[..., 0] * 0.3 + a[..., 1] * 0.59 + a[..., 2] * 0.11)
    h, w = lum.shape
    out = np.zeros((h, w, 4), np.uint8)
    out[..., 0] = np.clip((smooth * (0.8 + 0.4 * lum)) * 255, 0, 255)
    out[..., 1] = f0
    out[..., 2] = porosity
    out[..., 3] = 255   # no emission
    return Image.fromarray(out, 'RGBA')

with zipfile.ZipFile(JAR) as jar, zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('pack.mcmeta', json.dumps({'pack': {'pack_format': 1, 'description': 'metal189 LabPBR test pack'}}))
    for name, (smooth, f0, strength, porosity) in BLOCKS.items():
        path = 'assets/minecraft/textures/blocks/%s.png' % name
        try:
            img = Image.open(io.BytesIO(jar.read(path)))
        except KeyError:
            print('missing', path)
            continue
        for suffix, im in (('_n', normal_map(img, strength)), ('_s', specular_map(img, smooth, f0, porosity))):
            b = io.BytesIO()
            im.save(b, 'PNG')
            z.writestr(path.replace('.png', suffix + '.png'), b.getvalue())
print('wrote', OUT)
