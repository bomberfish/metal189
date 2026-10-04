// metal189: debug captures of render targets to PNG.

#import "engine.h"
#import "resources.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

namespace m189 {

// which: 0 = screen target, otherwise a texture id (GL row order, flipped for PNG).
bool captureToPng(int which, const char* path) {
    Engine& e = engine();
    id<MTLTexture> tex = nil;
    bool flip = false;
    if (which == 0) tex = screenForReadback(&flip);
    else { TexEntry* t = texture(which); tex = t ? (t->presented ? t->presented : t->tex) : nil; flip = true; }
    if (!tex) return false;
    waitIdle();
    int w = (int)tex.width, h = (int)tex.height;
    size_t pitch = (size_t)w * 4;
    id<MTLBuffer> buf = [e.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [e.queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t* px = (uint8_t*)malloc(pitch * h);
    const uint8_t* src = (const uint8_t*)buf.contents;
    for (int y = 0; y < h; y++) {
        const uint8_t* s = src + (size_t)(flip ? h - 1 - y : y) * pitch;
        uint8_t* d = px + (size_t)y * pitch;
        for (int x = 0; x < w; x++) { // BGRA -> RGBA, opaque like the window shows it
            d[x * 4] = s[x * 4 + 2]; d[x * 4 + 1] = s[x * 4 + 1]; d[x * 4 + 2] = s[x * 4]; d[x * 4 + 3] = 255;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, pitch, cs, kCGImageAlphaPremultipliedLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    bool ok = false;
    if (dst) {
        CGImageDestinationAddImage(dst, img, nullptr);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return ok;
}

} // namespace m189
