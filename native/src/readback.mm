// metal189: synchronous readbacks (glGetTexImage / glReadPixels).

#import "engine.h"
#import "resources.h"

namespace m189 {

// Copies a region of `tex` into CPU memory as GL `format`/`type` pixels.
// `flipRows` converts Metal-oriented (screen) rows into GL bottom-up order.
static void readTexture(id<MTLTexture> tex, int level, int x, int y, int w, int h, int format, int type,
                        uint8_t* dst, size_t dstSize, bool flipRows) {
    if (!tex || w <= 0 || h <= 0) return;
    Engine& e = engine();
    size_t pitch = (size_t)w * 4;
    id<MTLBuffer> buf = [e.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [e.queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    const uint8_t* src = (const uint8_t*)buf.contents;
    int bpp = (format == 0x1907 || format == 0x80E0) ? 3 : 4;
    size_t outPitch = (size_t)w * bpp;
    for (int r = 0; r < h; r++) {
        const uint8_t* s = src + (size_t)(flipRows ? h - 1 - r : r) * pitch;
        uint8_t* d = dst + (size_t)r * outPitch;
        if ((size_t)(r + 1) * outPitch > dstSize) break;
        for (int i = 0; i < w; i++) {
            uint8_t B = s[i * 4], G = s[i * 4 + 1], R = s[i * 4 + 2], A = s[i * 4 + 3];
            if (format == 0x80E1) { d[i * 4] = B; d[i * 4 + 1] = G; d[i * 4 + 2] = R; d[i * 4 + 3] = A; }
            else if (format == 0x1908) { d[i * 4] = R; d[i * 4 + 1] = G; d[i * 4 + 2] = B; d[i * 4 + 3] = A; }
            else if (format == 0x1907) { d[i * 3] = R; d[i * 3 + 1] = G; d[i * 3 + 2] = B; }
            else if (format == 0x80E0) { d[i * 3] = B; d[i * 3 + 1] = G; d[i * 3 + 2] = R; }
            else { d[i * 4] = B; d[i * 4 + 1] = G; d[i * 4 + 2] = R; d[i * 4 + 3] = A; }
        }
    }
}

void texGetImage(int id, int level, int format, int type, void* dst, size_t size) {
    TexEntry* t = texture(id);
    if (!t || !t->tex || level >= t->levels) return;
    int w = std::max(1, t->w >> level), h = std::max(1, t->h >> level);
    readTexture(t->tex, level, 0, 0, w, h, format, type, (uint8_t*)dst, size, false);
}

void readPixels(int fbo, int x, int y, int w, int h, int format, int type, void* dst, size_t size) {
    Engine& e = engine();
    if (fbo == 0) {
        if (!e.screenColor) return;
        int H = (int)e.screenColor.height;
        readTexture(e.screenColor, 0, x, H - (y + h), w, h, format, type, (uint8_t*)dst, size, true);
    }
    // FBO reads go through the colour texture with GL row order; callers use glGetTexImage.
}

} // namespace m189
