// metal189: native resource tables.
#pragma once
#import "engine.h"
#include "ff.h"
#include <unordered_map>

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
    id<MTLTexture> presented = nil;   // the image moved to the screen by screenAdopt (read until next written)
};

struct PendingInit { id<MTLTexture> tex; int levels; bool depth; };
struct PendingCopy { id<MTLTexture> src, dst; int levels; };
struct PendingUpload { id<MTLBuffer> src; size_t offset; size_t bytesPerRow; id<MTLTexture> dst; int level, x, y, w, h; };
struct StagingAlloc { id<MTLBuffer> buffer; size_t offset; };

TexEntry* texture(int id);
TexEntry* renderbuffer(int id);
id<MTLBuffer> mesh(int id);
const VertexLayout* layout(int id);
id<MTLSamplerState> samplerFor(int minF, int magF, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float aniso);

void formatRegister(int id, int stride, const int32_t* attrs, int count);
void texImage(int id, int level, int internalFormat, int w, int h, int format, int type, const void* data, int rowLength);
void texSubImage(int id, int level, int x, int y, int w, int h, int format, int type, const void* data, int rowLength);
void texParams(int id, int minF, int magF, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float aniso);
void texDelete(int id);
void renderbufferStorage(int id, int internalFormat, int w, int h);
int meshCreate(const void* data, size_t size);
void meshDelete(int id);

struct Section {
    id<MTLBuffer> layers[4] = {nil, nil, nil, nil};
    uint32_t vertices[4] = {0, 0, 0, 0};
    // Solid layers are stored by facing (kFaceGroups order): quads [groupStart[l][g], groupStart[l][g+1])
    // face group g, all on or past `plane[l][g]` along its axis (towards its normal: the min for
    // a + facing, the max for a - one). The translucent layer keeps its own order (one group).
    uint32_t groupStart[4][8] = {};
    float plane[4][7] = {};
    int32_t ox = 0, oy = 0, oz = 0;   // world block coordinates of the section origin
    uint64_t version = 0;             // changes when its solid layers or position do (globally unique)
    uint32_t solid[128] = {};         // opaque cubes: bit (y << 8) | (z << 4) | x (chunk builds report them)
    bool emits = false;               // some block in it gives light
    bool tinted = false;              // translucent blocks other than water (stained glass, ice, slime, portals)
};
// Face groups in storage order: -Y, -X, -Z, +Y, other, +Z, +X (the faces a camera above the
// terrain sees are mostly contiguous). Group 4 holds quads that are not axis-aligned.
enum FaceGroup { FG_NY = 0, FG_NX, FG_NZ, FG_PY, FG_OTHER, FG_PZ, FG_PX, FG_COUNT };
Section* section(int id);
const std::unordered_map<int, Section>& allSections();
const Section* sectionAt(int sx, int sy, int sz);   // by position (blocks / 16)
void sectionUpload(int id, int layer, const void* data, size_t bytes, uint32_t vertexCount, int ox, int oy, int oz);
void sectionDelete(int id);
void sectionSolid(int id, const uint32_t* bits, bool emits, bool tinted);
// Changes whenever any section's geometry does (uploads, deletions).
uint64_t sectionsGeneration();
// Makes every section vertex buffer resident for draws that reach them by GPU address.
void sectionHeapsUse(id<MTLRenderCommandEncoder> enc);
// The visible sections in vanilla order (RenderGlobal.renderInfos), set when it changes.
void terrainSetVisible(const int32_t* ids, int count);
// A TERRAIN command's sections with their camera-relative offsets (expanding the visible list).
struct TerrainEntry;
struct TerrainCmd;
const TerrainEntry* terrainEntries(const TerrainCmd& t, const uint8_t* body, uint32_t& count);

StagingAlloc stagingAlloc(size_t bytes);
void encodePendingResourceWork(id<MTLCommandBuffer> cb);
void releaseDeferred();

} // namespace m189
