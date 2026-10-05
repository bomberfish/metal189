// metal189: textures, samplers, render buffers, static meshes and vertex layouts.

#import "engine.h"
#import "resources.h"
#import "commands.h"
#import "raytrace.h"
#import "terrain_gpu.h"
#include <unordered_map>

namespace m189 {

static std::unordered_map<int, TexEntry> g_textures;
static std::unordered_map<int, TexEntry> g_renderbuffers;
static std::unordered_map<int, id<MTLBuffer>> g_meshes;
static std::vector<VertexLayout> g_formats(1);
static std::unordered_map<uint64_t, id<MTLSamplerState>> g_samplers;
static int g_nextMesh = 1;

// Work that must be encoded at the start of the next submitted command buffer.
static std::vector<PendingInit> g_inits;
static std::vector<PendingCopy> g_copies;
static std::vector<PendingUpload> g_uploads;
static std::vector<id> g_deferredReleases;

// Section vertex buffers live in heaps so a draw can reach any of them through its GPU
// address (the baseline terrain pass binds them once instead of per section).
static std::vector<id<MTLHeap>> g_sectionHeaps;
static uint64_t g_sectionsGeneration = 0;
uint64_t sectionsGeneration() { return g_sectionsGeneration; }
constexpr size_t kSectionHeapSize = 64u << 20;

static id<MTLBuffer> newSectionBuffer(const void* data, size_t bytes) {
    const MTLResourceOptions opts = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
    id<MTLBuffer> b = nil;
    for (id<MTLHeap> h : g_sectionHeaps) {
        if ([h maxAvailableSizeWithAlignment:256] < bytes) continue;
        b = [h newBufferWithLength:bytes options:opts];
        if (b) break;
    }
    if (!b) {
        MTLHeapDescriptor* d = [MTLHeapDescriptor new];
        d.storageMode = MTLStorageModeShared;
        d.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        d.size = std::max(kSectionHeapSize, (bytes + 0xFFFF) & ~(size_t)0xFFFF);
        id<MTLHeap> h = [device() newHeapWithDescriptor:d];
        if (h) {
            h.label = @"section vertices";
            g_sectionHeaps.push_back(h);
            b = [h newBufferWithLength:bytes options:opts];
        }
    }
    if (!b) return [device() newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared];
    memcpy(b.contents, data, bytes);
    return b;
}

static std::vector<int32_t> g_visible;

void terrainSetVisible(const int32_t* ids, int count) { g_visible.assign(ids, ids + std::max(count, 0)); }

const TerrainEntry* terrainEntries(const TerrainCmd& t, const uint8_t* body, uint32_t& count) {
    if (t.count != kTerrainVisible) {
        count = t.count;
        return (const TerrainEntry*)body;
    }
    double cam[3];
    memcpy(cam, body, sizeof cam);
    static std::vector<TerrainEntry> out[5];
    std::vector<TerrainEntry>& o = out[std::min<uint32_t>(t.layer, 4)];
    o.clear();
    size_t n = g_visible.size();
    bool backToFront = t.layer == 3;   // vanilla draws translucent sections in reverse
    bool all = t.layer > 3;            // every visible section (frame_exec.mm drawTerrain)
    for (size_t k = 0; k < n; k++) {
        int32_t id = g_visible[backToFront ? n - 1 - k : k];
        const Section* sp = section(id);
        if (!sp || (!all && !sp->layers[t.layer])) continue;   // vanilla: isLayerEmpty
        const Section& s = *sp;
        o.push_back({(uint32_t)id, (float)((double)s.ox - cam[0]), (float)((double)s.oy - cam[1]), (float)((double)s.oz - cam[2])});
    }
    count = (uint32_t)o.size();
    return o.data();
}

void sectionHeapsUse(id<MTLRenderCommandEncoder> enc) {
    if (g_sectionHeaps.empty()) return;
    [enc useHeaps:g_sectionHeaps.data() count:g_sectionHeaps.size() stages:MTLRenderStageVertex];
}

TexEntry* texture(int id) {
    auto it = g_textures.find(id);
    return it == g_textures.end() ? nullptr : &it->second;
}

TexEntry* renderbuffer(int id) {
    auto it = g_renderbuffers.find(id);
    return it == g_renderbuffers.end() ? nullptr : &it->second;
}

id<MTLBuffer> mesh(int id) {
    auto it = g_meshes.find(id);
    return it == g_meshes.end() ? nil : it->second;
}

const VertexLayout* layout(int id) {
    return id > 0 && id < (int)g_formats.size() ? &g_formats[id] : nullptr;
}

// ---------------------------------------------------------------------------
// vertex layouts

void formatRegister(int id, int stride, const int32_t* attrs, int count) {
    if (id <= 0) return;
    if ((int)g_formats.size() <= id) g_formats.resize(id + 1);
    VertexLayout l;
    simd_int4 none = {-1, 0, 0, 0};
    l.pos = l.color = l.tex0 = l.tex1 = l.normal = none;
    l.stride = simd_make_uint4((uint32_t)stride, 0, 0, 0);
    for (int i = 0; i < count; i++) {
        const int32_t* a = attrs + i * 5;
        simd_int4 v = {a[3], a[1], a[2], a[4]};
        switch (a[0]) {
            case 0: l.pos = v; break;
            case 1: l.color = v; break;
            case 2: l.tex0 = v; break;
            case 3: l.tex1 = v; break;
            case 4: l.normal = v; break;
            default: break;
        }
    }
    g_formats[id] = l;
}

// ---------------------------------------------------------------------------
// samplers

static MTLSamplerAddressMode addressMode(int wrap) {
    switch (wrap) {
        case 0x2901: return MTLSamplerAddressModeRepeat;          // GL_REPEAT
        case 0x8370: return MTLSamplerAddressModeMirrorRepeat;    // GL_MIRRORED_REPEAT
        case 0x812D: return MTLSamplerAddressModeClampToBorderColor; // GL_CLAMP_TO_BORDER
        case 0x2900: return MTLSamplerAddressModeClampToBorderColor; // GL_CLAMP: border texels (transparent black)
        default: return MTLSamplerAddressModeClampToEdge;         // GL_CLAMP_TO_EDGE
    }
}

id<MTLSamplerState> samplerFor(int minF, int magF, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float anisoIn) {
    MTLSamplerMinMagFilter min = MTLSamplerMinMagFilterNearest, mag = MTLSamplerMinMagFilterNearest;
    MTLSamplerMipFilter mip = MTLSamplerMipFilterNotMipmapped;
    switch (minF) {
        case 0x2601: min = MTLSamplerMinMagFilterLinear; break;                                  // LINEAR
        case 0x2700: mip = MTLSamplerMipFilterNearest; break;                                    // NEAREST_MIPMAP_NEAREST
        case 0x2701: min = MTLSamplerMinMagFilterLinear; mip = MTLSamplerMipFilterNearest; break; // LINEAR_MIPMAP_NEAREST
        case 0x2702: mip = MTLSamplerMipFilterLinear; break;                                     // NEAREST_MIPMAP_LINEAR
        case 0x2703: min = MTLSamplerMinMagFilterLinear; mip = MTLSamplerMipFilterLinear; break;  // LINEAR_MIPMAP_LINEAR
        default: break;
    }
    if (magF == 0x2601) mag = MTLSamplerMinMagFilterLinear;
    float lodMin = std::max(0.0f, minLod);
    float lodMax = std::min(maxLod, (float)std::min(maxLevel, 1000));
    if (lodMax < lodMin) lodMax = lodMin;
    int aniso = (int)std::clamp(anisoIn, 1.0f, 16.0f);
    uint64_t key = (uint64_t)min | (uint64_t)mag << 2 | (uint64_t)mip << 4 | (uint64_t)addressMode(wrapS) << 6 |
                   (uint64_t)addressMode(wrapT) << 10 | (uint64_t)(aniso & 31) << 14 |
                   (uint64_t)(uint32_t)(lodMin * 16) << 20 | (uint64_t)(uint32_t)(std::min(lodMax, 64.0f) * 16) << 40;
    auto it = g_samplers.find(key);
    if (it != g_samplers.end()) return it->second;
    MTLSamplerDescriptor* d = [MTLSamplerDescriptor new];
    d.minFilter = min;
    d.magFilter = mag;
    d.mipFilter = mip;
    d.sAddressMode = addressMode(wrapS);
    d.tAddressMode = addressMode(wrapT);
    d.rAddressMode = MTLSamplerAddressModeClampToEdge;
    d.borderColor = MTLSamplerBorderColorTransparentBlack;
    d.lodMinClamp = lodMin;
    d.lodMaxClamp = lodMax;
    d.maxAnisotropy = aniso;
    d.supportArgumentBuffers = YES;
    id<MTLSamplerState> s = [device() newSamplerStateWithDescriptor:d];
    g_samplers[key] = s;
    return s;
}

void texParams(int id, int minF, int magF, int wrapS, int wrapT, int maxLevel, float minLod, float maxLod, float aniso) {
    TexEntry& t = g_textures[id];
    t.minFilter = minF;
    t.magFilter = magF;
    t.wrapS = wrapS;
    t.wrapT = wrapT;
    t.maxLevel = maxLevel;
    t.minLod = minLod;
    t.maxLod = maxLod;
    t.aniso = aniso;
    t.sampler = nil;
}

// ---------------------------------------------------------------------------
// textures

static int fullChain(int w, int h) {
    int n = 1;
    while ((w > 1 || h > 1) && n < 16) { w = std::max(1, w >> 1); h = std::max(1, h >> 1); n++; }
    return n;
}

static bool isDepthFormat(int internalFormat) {
    switch (internalFormat) {
        case 0x1902: case 0x81A5: case 0x81A6: case 0x81A7: case 0x8CAC: case 0x88F0: case 0x84F9: return true;
        default: return false;
    }
}

static id<MTLTexture> newTexture(int w, int h, int levels, MTLPixelFormat fmt) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:levels > 1];
    d.mipmapLevelCount = levels;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    return [device() newTextureWithDescriptor:d];
}

static void ensureStorage(TexEntry& t, int level, int w, int h, int internalFormat) {
    bool depth = isDepthFormat(internalFormat);
    MTLPixelFormat fmt = depth ? MTLPixelFormatDepth32Float : MTLPixelFormatBGRA8Unorm;
    if (level == 0) {
        int want = std::min(fullChain(w, h), std::max(1, std::min(t.maxLevel, 15) + 1));
        if (t.tex && t.w == w && t.h == h && t.tex.pixelFormat == fmt && t.levels >= want) return;
        id<MTLTexture> old = t.tex;
        t.tex = newTexture(w, h, want, fmt);
        t.w = w;
        t.h = h;
        t.levels = want;
        t.isDepth = depth;
        g_inits.push_back({t.tex, want, depth});
        if (old) g_deferredReleases.push_back(old);
        return;
    }
    if (!t.tex) return;
    if (level < t.levels) return;
    // A deeper mip level than allocated: grow the chain and keep existing levels.
    int levels = std::min(level + 1, fullChain(t.w, t.h));
    if (levels <= t.levels) return;
    id<MTLTexture> nt = newTexture(t.w, t.h, levels, t.tex.pixelFormat);
    g_inits.push_back({nt, levels, t.isDepth});
    g_copies.push_back({t.tex, nt, t.levels});
    g_deferredReleases.push_back(t.tex);
    t.tex = nt;
    t.levels = levels;
}

// Converts one row of GL client pixels to BGRA8.
static void convertRow(const uint8_t* src, uint8_t* dst, int w, int format, int type, bool forceOpaque) {
    if ((format == 0x80E1 && (type == 0x8367 || type == 0x1401))) { // BGRA + 8_8_8_8_REV / UNSIGNED_BYTE
        memcpy(dst, src, (size_t)w * 4);
    } else if (format == 0x1908 && (type == 0x1401 || type == 0x8367)) { // RGBA bytes
        for (int i = 0; i < w; i++) {
            dst[i * 4] = src[i * 4 + 2]; dst[i * 4 + 1] = src[i * 4 + 1];
            dst[i * 4 + 2] = src[i * 4]; dst[i * 4 + 3] = src[i * 4 + 3];
        }
    } else if (format == 0x80E1 && type == 0x8035) { // BGRA + 8_8_8_8 (big-endian packing)
        for (int i = 0; i < w; i++) {
            dst[i * 4] = src[i * 4 + 3]; dst[i * 4 + 1] = src[i * 4 + 2];
            dst[i * 4 + 2] = src[i * 4 + 1]; dst[i * 4 + 3] = src[i * 4];
        }
    } else if (format == 0x1907 && type == 0x1401) { // RGB
        for (int i = 0; i < w; i++) {
            dst[i * 4] = src[i * 3 + 2]; dst[i * 4 + 1] = src[i * 3 + 1];
            dst[i * 4 + 2] = src[i * 3]; dst[i * 4 + 3] = 255;
        }
    } else if (format == 0x80E0 && type == 0x1401) { // BGR
        for (int i = 0; i < w; i++) {
            dst[i * 4] = src[i * 3]; dst[i * 4 + 1] = src[i * 3 + 1];
            dst[i * 4 + 2] = src[i * 3 + 2]; dst[i * 4 + 3] = 255;
        }
    } else if (format == 0x1909 && type == 0x1401) { // LUMINANCE
        for (int i = 0; i < w; i++) { dst[i * 4] = dst[i * 4 + 1] = dst[i * 4 + 2] = src[i]; dst[i * 4 + 3] = 255; }
    } else if (format == 0x190A && type == 0x1401) { // LUMINANCE_ALPHA
        for (int i = 0; i < w; i++) {
            dst[i * 4] = dst[i * 4 + 1] = dst[i * 4 + 2] = src[i * 2];
            dst[i * 4 + 3] = src[i * 2 + 1];
        }
    } else if (format == 0x1906 && type == 0x1401) { // ALPHA
        for (int i = 0; i < w; i++) { dst[i * 4] = dst[i * 4 + 1] = dst[i * 4 + 2] = 0; dst[i * 4 + 3] = src[i]; }
    } else if (format == 0x1903 && type == 0x1401) { // RED
        for (int i = 0; i < w; i++) { dst[i * 4] = 0; dst[i * 4 + 1] = 0; dst[i * 4 + 2] = src[i]; dst[i * 4 + 3] = 255; }
    } else if ((format == 0x1908 || format == 0x80E1) && type == 0x1406) { // float RGBA/BGRA
        const float* f = (const float*)src;
        for (int i = 0; i < w; i++) {
            uint8_t c[4];
            for (int k = 0; k < 4; k++) c[k] = (uint8_t)lroundf(std::clamp(f[i * 4 + k], 0.0f, 1.0f) * 255.0f);
            if (format == 0x1908) { dst[i * 4] = c[2]; dst[i * 4 + 1] = c[1]; dst[i * 4 + 2] = c[0]; }
            else { dst[i * 4] = c[0]; dst[i * 4 + 1] = c[1]; dst[i * 4 + 2] = c[2]; }
            dst[i * 4 + 3] = c[3];
        }
    } else {
        memset(dst, 0, (size_t)w * 4);
    }
    if (forceOpaque) for (int i = 0; i < w; i++) dst[i * 4 + 3] = 255;
}

static int srcBytesPerPixel(int format, int type) {
    int comps;
    switch (format) {
        case 0x1908: case 0x80E1: comps = 4; break;
        case 0x1907: case 0x80E0: comps = 3; break;
        case 0x190A: comps = 2; break;
        default: comps = 1; break;
    }
    if (type == 0x8367 || type == 0x8035) return 4;
    if (type == 0x1406) return comps * 4;
    return comps;
}

static void stageUpload(TexEntry& t, int level, int x, int y, int w, int h, int format, int type,
                        const uint8_t* data, int rowLength) {
    if (!t.tex || level >= t.levels || w <= 0 || h <= 0 || !data) return;
    int lw = std::max(1, t.w >> level), lh = std::max(1, t.h >> level);
    if (x < 0 || y < 0 || x + w > lw || y + h > lh) {
        // Clip to the level like GL would reject; keep the in-bounds part.
        int x0 = std::max(0, x), y0 = std::max(0, y);
        int x1 = std::min(lw, x + w), y1 = std::min(lh, y + h);
        if (x1 <= x0 || y1 <= y0) return;
        int bpp = srcBytesPerPixel(format, type);
        data += ((size_t)(y0 - y) * rowLength + (x0 - x)) * bpp;
        x = x0; y = y0; w = x1 - x0; h = y1 - y0;
    }
    if (t.isDepth) return;
    int bpp = srcBytesPerPixel(format, type);
    size_t srcPitch = (size_t)rowLength * bpp;
    size_t dstPitch = (size_t)w * 4;
    size_t bytes = dstPitch * h;
    StagingAlloc s = stagingAlloc(bytes);
    uint8_t* dst = (uint8_t*)s.buffer.contents + s.offset;
    bool opaque = t.forceOpaque;
    for (int r = 0; r < h; r++) convertRow(data + r * srcPitch, dst + r * dstPitch, w, format, type, opaque);
    g_uploads.push_back({s.buffer, s.offset, dstPitch, t.tex, level, x, y, w, h});
}

void texImage(int id, int level, int internalFormat, int w, int h, int format, int type, const void* data, int rowLength) {
    if (w <= 0 || h <= 0) return;
    TexEntry& t = g_textures[id];
    t.forceOpaque = internalFormat == 0x1907 || internalFormat == 0x8051; // GL_RGB / GL_RGB8
    ensureStorage(t, level, w, h, internalFormat);
    if (data) stageUpload(t, level, 0, 0, w, h, format, type, (const uint8_t*)data, rowLength);
}

void texSubImage(int id, int level, int x, int y, int w, int h, int format, int type, const void* data, int rowLength) {
    TexEntry* t = texture(id);
    if (!t) return;
    stageUpload(*t, level, x, y, w, h, format, type, (const uint8_t*)data, rowLength);
}

void texDelete(int id) {
    auto it = g_textures.find(id);
    if (it == g_textures.end()) return;
    if (it->second.tex) g_deferredReleases.push_back(it->second.tex);
    g_textures.erase(it);
}

void renderbufferStorage(int id, int internalFormat, int w, int h) {
    TexEntry& t = g_renderbuffers[id];
    bool stencil = internalFormat == 0x88F0 || internalFormat == 0x84F9; // DEPTH24_STENCIL8 / DEPTH_STENCIL
    MTLPixelFormat fmt = stencil ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatDepth32Float;
    if (t.tex && t.w == w && t.h == h && t.tex.pixelFormat == fmt) return;
    if (t.tex) g_deferredReleases.push_back(t.tex);
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    t.tex = [device() newTextureWithDescriptor:d];
    t.w = w;
    t.h = h;
    t.levels = 1;
    t.isDepth = true;
    g_inits.push_back({t.tex, 1, true});
}

// ---------------------------------------------------------------------------
// terrain sections

static std::unordered_map<int, Section> g_sections;
// by id (ids are small and dense): map nodes never move, so these stay valid until erased
static std::vector<Section*> g_sectionById;

Section* section(int sid) {
    return sid >= 0 && (size_t)sid < g_sectionById.size() ? g_sectionById[sid] : nullptr;
}

const std::unordered_map<int, Section>& allSections() { return g_sections; }

// sections by position (blocks / 16)
static std::unordered_map<uint64_t, int> g_sectionAt;

static uint64_t sectionKey(int sx, int sy, int sz) {
    return ((uint64_t)(uint32_t)(sx & 0x1FFFFF) << 42) | ((uint64_t)(uint32_t)(sy & 0x1FFFFF) << 21) | (uint64_t)(uint32_t)(sz & 0x1FFFFF);
}

static void sectionUnplace(int sid, const Section& s) {
    auto it = g_sectionAt.find(sectionKey(s.ox >> 4, s.oy >> 4, s.oz >> 4));
    if (it != g_sectionAt.end() && it->second == sid) g_sectionAt.erase(it);
}

const Section* sectionAt(int sx, int sy, int sz) {
    auto it = g_sectionAt.find(sectionKey(sx, sy, sz));
    return it == g_sectionAt.end() ? nullptr : section(it->second);
}

void sectionUpload(int sid, int layer, const void* data, size_t bytes, uint32_t vertexCount, int ox, int oy, int oz) {
    if (layer < 0 || layer > 3) return;
    if (layer < 3) rtSectionChanged(sid);
    g_sectionsGeneration++;
    static uint64_t versions = 0;
    Section& s = g_sections[sid];
    if (sid >= 0) {
        if ((size_t)sid >= g_sectionById.size()) g_sectionById.resize((size_t)sid + 1024, nullptr);
        g_sectionById[sid] = &s;
    }
    bool moved = s.version == 0 || s.ox != ox || s.oy != oy || s.oz != oz;
    if (moved) {
        if (s.version != 0) sectionUnplace(sid, s);
        g_sectionAt[sectionKey(ox >> 4, oy >> 4, oz >> 4)] = sid;
    }
    // what solid terrain looks like changed (translucent re-sorts as the camera moves do not count)
    if (layer < 3 || moved) s.version = ++versions;
    s.ox = ox;
    s.oy = oy;
    s.oz = oz;
    if (s.layers[layer]) g_deferredReleases.push_back(s.layers[layer]);
    s.layers[layer] = nil;
    s.vertices[layer] = 0;
    for (int g = 0; g < 8; g++) s.groupStart[layer][g] = 0;
    if (bytes == 0 || vertexCount == 0) {
        terrainMetaChanged(sid, &s);
        return;
    }
    uint32_t quads = vertexCount / 4;
    size_t stride = bytes / vertexCount;
    if (layer < 3 && vertexCount % 4 == 0 && stride == 28) {
        // sort the quads by facing (stable: coplanar overlays keep their order)
        static std::vector<uint8_t> group;
        static std::vector<uint8_t> sorted;
        group.resize(quads);
        uint32_t count[FG_COUNT] = {};
        float plane[FG_COUNT];
        for (int g = 0; g < FG_COUNT; g++) plane[g] = (g == FG_PX || g == FG_PY || g == FG_PZ) ? 1e30f : -1e30f;
        const uint8_t* src = (const uint8_t*)data;
        for (uint32_t q = 0; q < quads; q++) {
            const float* p0 = (const float*)(src + (size_t)q * 4 * 28);
            const float* p1 = (const float*)(src + ((size_t)q * 4 + 1) * 28);
            const float* p2 = (const float*)(src + ((size_t)q * 4 + 2) * 28);
            float ax = p1[0] - p0[0], ay = p1[1] - p0[1], az = p1[2] - p0[2];
            float bx = p2[0] - p1[0], by = p2[1] - p1[1], bz = p2[2] - p1[2];
            float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
            float len2 = nx * nx + ny * ny + nz * nz;
            int g = FG_OTHER;
            // GL's front faces wind counter-clockwise, so (p1 - p0) x (p2 - p1) is the outward normal
            const float k = 0.9999f;
            if (len2 > 0) {
                if (nx * nx > k * len2) g = nx > 0 ? FG_PX : FG_NX;
                else if (ny * ny > k * len2) g = ny > 0 ? FG_PY : FG_NY;
                else if (nz * nz > k * len2) g = nz > 0 ? FG_PZ : FG_NZ;
            }
            if (g != FG_OTHER) {
                int axis = (g == FG_PX || g == FG_NX) ? 0 : (g == FG_PY || g == FG_NY) ? 1 : 2;
                bool pos = g == FG_PX || g == FG_PY || g == FG_PZ;
                for (int v = 0; v < 4; v++) {
                    float c = ((const float*)(src + ((size_t)q * 4 + v) * 28))[axis];
                    plane[g] = pos ? std::min(plane[g], c) : std::max(plane[g], c);
                }
            }
            group[q] = (uint8_t)g;
            count[g]++;
        }
        uint32_t start[FG_COUNT + 1];
        start[0] = 0;
        for (int g = 0; g < FG_COUNT; g++) start[g + 1] = start[g] + count[g];
        for (int g = 0; g <= FG_COUNT; g++) s.groupStart[layer][g] = start[g];
        for (int g = 0; g < FG_COUNT; g++) s.plane[layer][g] = plane[g];
        sorted.resize(bytes);
        uint32_t at[FG_COUNT];
        memcpy(at, start, sizeof at);
        for (uint32_t q = 0; q < quads; q++) memcpy(&sorted[(size_t)at[group[q]]++ * 112], src + (size_t)q * 112, 112);
        s.layers[layer] = newSectionBuffer(sorted.data(), bytes);
    } else {
        // one group: always drawn whole
        for (int g = FG_OTHER + 1; g <= FG_COUNT; g++) s.groupStart[layer][g] = quads;
        s.layers[layer] = newSectionBuffer(data, bytes);
    }
    s.vertices[layer] = vertexCount;
    terrainMetaChanged(sid, &s);
}

void sectionSolid(int sid, const uint32_t* bits, bool emits, bool tinted) {
    auto it = g_sections.find(sid);
    if (it == g_sections.end()) return;
    static_assert(sizeof it->second.solid == 512, "4096 bits");
    it->second.emits = emits;
    it->second.tinted = tinted;
    if (memcmp(it->second.solid, bits, 512) == 0) return;
    memcpy(it->second.solid, bits, 512);
    static uint64_t versions = 1ull << 62;   // apart from the upload versions
    it->second.version = ++versions;
}

void sectionDelete(int sid) {
    rtSectionDeleted(sid);
    g_sectionsGeneration++;
    auto it = g_sections.find(sid);
    if (it == g_sections.end()) return;
    sectionUnplace(sid, it->second);
    for (id<MTLBuffer> b : it->second.layers) if (b) g_deferredReleases.push_back(b);
    if (sid >= 0 && (size_t)sid < g_sectionById.size()) g_sectionById[sid] = nullptr;
    g_sections.erase(it);
    terrainMetaChanged(sid, nullptr);
}

// ---------------------------------------------------------------------------
// meshes

int meshCreate(const void* data, size_t size) {
    id<MTLBuffer> b = [device() newBufferWithBytes:data length:size options:MTLResourceStorageModeShared];
    int id = g_nextMesh++;
    g_meshes[id] = b;
    return id;
}

void meshDelete(int id) {
    auto it = g_meshes.find(id);
    if (it == g_meshes.end()) return;
    g_deferredReleases.push_back(it->second);
    g_meshes.erase(it);
}

// ---------------------------------------------------------------------------
// staging + pending work

StagingAlloc stagingAlloc(size_t bytes) {
    Engine& e = engine();
    FrameResources& f = *e.cur;
    size_t aligned = (bytes + 255) & ~(size_t)255;
    if (aligned > kStagingChunk / 2) {
        id<MTLBuffer> b = [device() newBufferWithLength:aligned options:MTLResourceStorageModeShared];
        f.staging.push_back(b);
        return {b, 0};
    }
    if (f.stagingCur == nil || f.stagingOffset + aligned > kStagingChunk) {
        if (f.stagingFree.empty()) {
            f.stagingCur = [device() newBufferWithLength:kStagingChunk options:MTLResourceStorageModeShared];
        } else {
            f.stagingCur = f.stagingFree.back();
            f.stagingFree.pop_back();
        }
        f.stagingChunks.push_back(f.stagingCur);
        f.stagingOffset = 0;
    }
    StagingAlloc s{f.stagingCur, f.stagingOffset};
    f.stagingOffset += aligned;
    return s;
}

// Encodes texture initialisation, mip-chain copies and uploads queued since the
// last submission. Runs before any render pass of the command buffer.
void encodePendingResourceWork(id<MTLCommandBuffer> cb) {
    for (const PendingInit& in : g_inits) {
        for (int l = 0; l < in.levels; l++) {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            if (in.depth) {
                rp.depthAttachment.texture = in.tex;
                rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.clearDepth = 1.0;
                rp.depthAttachment.storeAction = MTLStoreActionStore;
                if (in.tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                    rp.stencilAttachment.texture = in.tex;
                    rp.stencilAttachment.loadAction = MTLLoadActionClear;
                    rp.stencilAttachment.storeAction = MTLStoreActionStore;
                }
                if (l > 0) break;
            } else {
                rp.colorAttachments[0].texture = in.tex;
                rp.colorAttachments[0].level = l;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            }
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc endEncoding];
        }
    }
    g_inits.clear();
    if (g_copies.empty() && g_uploads.empty()) return;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (const PendingCopy& c : g_copies) {
        for (int l = 0; l < c.levels; l++) {
            [blit copyFromTexture:c.src sourceSlice:0 sourceLevel:l toTexture:c.dst destinationSlice:0
                 destinationLevel:l sliceCount:1 levelCount:1];
        }
    }
    g_copies.clear();
    for (const PendingUpload& u : g_uploads) {
        [blit copyFromBuffer:u.src sourceOffset:u.offset sourceBytesPerRow:u.bytesPerRow
             sourceBytesPerImage:u.bytesPerRow * u.h sourceSize:MTLSizeMake(u.w, u.h, 1)
                       toTexture:u.dst destinationSlice:0 destinationLevel:u.level
               destinationOrigin:MTLOriginMake(u.x, u.y, 0)];
    }
    g_uploads.clear();
    [blit endEncoding];
}

// Objects deleted during a frame stay alive until that frame's command buffer
// has been encoded (the command buffer then retains what it uses).
// Called after each frame's commit. Objects replaced while recording frame N may still be in
// use by frames N - 1 and earlier, and section buffers are reached by GPU address (command
// buffers do not retain them): they are kept until frames that old have certainly finished.
void releaseDeferred() {
    static std::vector<id> ring[kFramesInFlight + 1];
    static uint64_t n = 0;
    std::vector<id>& oldest = ring[(n + 1) % (kFramesInFlight + 1)];
    oldest.clear();
    ring[n % (kFramesInFlight + 1)].swap(g_deferredReleases);
    g_deferredReleases.clear();
    n++;
}

} // namespace m189
