// metal189: native resource tables.
#pragma once
#import "engine.h"
#include "ff.h"

namespace m189 {

struct TexEntry {
    id<MTLTexture> tex = nil;
    int w = 0, h = 0, levels = 0;
    bool isDepth = false;
    bool forceOpaque = false;
    int minFilter = 0x2702, magFilter = 0x2601;   // GL defaults
    int wrapS = 0x2901, wrapT = 0x2901;
    int maxLevel = 1000;
    float minLod = -1000.0f, maxLod = 1000.0f, aniso = 1.0f;
    id<MTLSamplerState> sampler = nil;
};

struct PendingInit { id<MTLTexture> tex; int levels; bool depth; };
struct PendingCopy { id<MTLTexture> src, dst; int levels; };
struct PendingUpload { id<MTLBuffer> src; size_t offset; size_t bytesPerRow; id<MTLTexture> dst; int level, x, y, w, h; };
struct StagingAlloc { id<MTLBuffer> buffer; size_t offset; };

TexEntry* texture(int id);
TexEntry* renderbuffer(int id);
id<MTLBuffer> mesh(int id);
const VertexLayout* layout(int id);
id<MTLSamplerState> textureSampler(TexEntry& t);

void formatRegister(int id, int stride, const int32_t* attrs, int count);
void texImage(int id, int level, int internalFormat, int w, int h, int format, int type, const void* data, int rowLength);
void texSubImage(int id, int level, int x, int y, int w, int h, int format, int type, const void* data, int rowLength);
void texParams(int id, int minF, int magF, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float aniso);
void texDelete(int id);
void renderbufferStorage(int id, int internalFormat, int w, int h);
int meshCreate(const void* data, size_t size);
void meshDelete(int id);

StagingAlloc stagingAlloc(size_t bytes);
void encodePendingResourceWork(id<MTLCommandBuffer> cb);
void releaseDeferred();

} // namespace m189
