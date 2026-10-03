// metal189: hardware ray tracing scene.
//
// Every terrain section gets a primitive acceleration structure with one triangle
// geometry per opaque/cutout render layer (solid layers are flagged opaque, cutout
// layers are alpha-tested by the shaders' intersection loops). BLASes are built when
// a section is (re)uploaded, closest sections first and under a per-frame budget.
//
// The TLAS lives in "ray tracing space": world coordinates relative to an origin that
// follows the camera in 128-block steps, so it only has to be rebuilt when sections
// change or the origin moves, not every frame. Rebuilds go to a ring slot no frame in
// flight can still be reading.
#import "raytrace.h"
#import "resources.h"
#import "gpu_profiler.h"
#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <unordered_set>
#include <mach/mach_time.h>

namespace m189 {

extern bool g_optGpuStats;

namespace {

struct RtSection {
    id<MTLAccelerationStructure> blas = nil;
    id<MTLBuffer> verts[3] = {nil, nil, nil};  // buffers the BLAS was built from (hit shading reads them)
    uint32_t layers = 0;
    int32_t ox = 0, oy = 0, oz = 0;             // section origin at build time
    bool queued = false;
};

std::unordered_map<int, RtSection> g_rt;
std::vector<int> g_queue;
bool g_sceneDirty = true;

id<MTLBuffer> g_quadIndices = nil;
uint32_t g_quadIndexQuads = 0;

// TLAS ring: a rebuild writes slot (cur + 1) % kTlasSlots; frames in flight read at
// most kFramesInFlight distinct slots, so the written one is never in use.
constexpr int kTlasSlots = kFramesInFlight + 1;
struct TlasSlot {
    id<MTLAccelerationStructure> tlas = nil;
    size_t size = 0;
    id<MTLBuffer> desc = nil, inst = nil;
    uint32_t count = 0;
    int64_t ox = 0, oy = 0, oz = 0;            // origin of this TLAS (blocks)
    std::vector<id<MTLResource>> resources;    // BLASes + vertex buffers referenced
    NSArray* keep = nil;
};
TlasSlot g_tlas[kTlasSlots];
int g_cur = -1;

id<MTLBuffer> g_scratch[kFramesInFlight];
uint64_t g_frame = 0;

// Residency (macOS 15+): BLASes and the vertex buffers they reference live in one
// residency set attached to each command buffer, instead of per-encoder useResources
// over thousands of allocations. Removals wait until no frame in flight can use them.
id g_residency = nil;   // id<MTLResidencySet>
bool g_residencyDirty = false;
std::vector<std::pair<uint64_t, id>> g_pendingRemoval;

bool residencyAvailable() {
    if (@available(macOS 15.0, *)) {
        if (!g_residency) {
            MTLResidencySetDescriptor* d = [MTLResidencySetDescriptor new];
            d.label = @"rt scene";
            d.initialCapacity = 8192;
            NSError* err = nil;
            g_residency = [device() newResidencySetWithDescriptor:d error:&err];
            if (!g_residency) log("rt: residency set unavailable: %s", err.localizedDescription.UTF8String);
        }
        return g_residency != nil;
    }
    return false;
}

void residentAdd(id a) {
    if (!a || !residencyAvailable()) return;
    if (@available(macOS 15.0, *)) {
        [(id<MTLResidencySet>)g_residency addAllocation:(id<MTLAllocation>)a];
        g_residencyDirty = true;
    }
}

void residentRemoveLater(id a) {
    if (a && g_residency) g_pendingRemoval.push_back({g_frame + kFramesInFlight + 1, a});
}

void releaseSection(RtSection& r) {
    residentRemoveLater(r.blas);
    for (auto& v : r.verts) residentRemoveLater(v);
}

constexpr uint32_t kMaxBuildsPerFrame = 64;
constexpr uint64_t kMaxBuildTrianglesPerFrame = 512u << 10;
constexpr int64_t kOriginStep = 128;

// Index pattern for BLAS quads: (0,1,2) (0,2,3); shaders map primitive ids back with it.
id<MTLBuffer> quadIndices(uint32_t quads) {
    if (quads > g_quadIndexQuads) {
        uint32_t n = std::max<uint32_t>(quads, std::max<uint32_t>(16384, g_quadIndexQuads * 2));
        id<MTLBuffer> b = [device() newBufferWithLength:(size_t)n * 6 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        uint32_t* p = (uint32_t*)b.contents;
        for (uint32_t q = 0; q < n; q++, p += 6) {
            uint32_t v = q * 4;
            p[0] = v; p[1] = v + 1; p[2] = v + 2; p[3] = v; p[4] = v + 2; p[5] = v + 3;
        }
        g_quadIndices = b;
        g_quadIndexQuads = n;
    }
    return g_quadIndices;
}

id<MTLBuffer> ensureBuffer(id<MTLBuffer> b, size_t bytes, MTLResourceOptions opts) {
    if (b && b.length >= bytes) return b;
    size_t n = std::max<size_t>(bytes + bytes / 2, 4096);
    return [device() newBufferWithLength:n options:opts];
}

size_t align256(size_t v) { return (v + 255) & ~(size_t)255; }

int64_t snapOrigin(double v) { return (int64_t)std::floor(v / (double)kOriginStep) * kOriginStep; }

} // namespace

bool rtAvailable() { return engine().supportsRaytracing; }

void rtSectionChanged(int sid) {
    if (!rtAvailable()) return;
    RtSection& r = g_rt[sid];
    if (!r.queued) {
        r.queued = true;
        g_queue.push_back(sid);
    }
}

void rtSectionDeleted(int sid) {
    auto it = g_rt.find(sid);
    if (it == g_rt.end()) return;
    if (it->second.blas) g_sceneDirty = true;
    releaseSection(it->second);
    g_rt.erase(it);
}

void rtRelease() {
    // Called when ray tracing is switched off: nothing will call rtPrepare to process
    // deferred residency removals, so wait for the GPU and empty the set now.
    waitIdle();
    if (g_residency) {
        if (@available(macOS 15.0, *)) {
            id<MTLResidencySet> rs = (id<MTLResidencySet>)g_residency;
            [rs removeAllAllocations];
            [rs commit];
        }
    }
    g_pendingRemoval.clear();
    g_residencyDirty = false;
    for (auto& kv : g_rt) {
        RtSection& r = kv.second;
        r.blas = nil;
        for (auto& v : r.verts) v = nil;
        if (!r.queued) {
            r.queued = true;
            g_queue.push_back(kv.first);
        }
    }
    for (TlasSlot& t : g_tlas) {
        t.tlas = nil;
        t.size = 0;
        t.count = 0;
        t.resources.clear();
        t.keep = nil;
    }
    for (auto& b : g_scratch) b = nil;
    g_cur = -1;
    g_sceneDirty = true;
}

bool rtPrepare(id<MTLCommandBuffer> cb, double camX, double camY, double camZ, float radius, RtScene& out) {
    out.instanceCount = 0;
    out.resources = nullptr;
    if (!rtAvailable()) return false;
    id<MTLDevice> dev = device();
    int frameSlot = (int)(g_frame++ % kFramesInFlight);

    // ---- section BLAS builds, closest first ----
    struct Job {
        int sid;
        MTLPrimitiveAccelerationStructureDescriptor* desc;
        id<MTLAccelerationStructure> as;
        size_t scratchOffset;
        id<MTLBuffer> verts[3];
        uint32_t layers;
        int32_t ox, oy, oz;
    };
    std::vector<Job> jobs;
    NSMutableArray* buildKeep = [NSMutableArray array];
    size_t scratchBytes = 0;
    if (!g_queue.empty()) {
        std::vector<std::pair<double, int>> order;
        order.reserve(g_queue.size());
        for (int sid : g_queue) {
            Section* s = section(sid);
            double dx = s ? s->ox + 8 - camX : 1e9, dy = s ? s->oy + 8 - camY : 0, dz = s ? s->oz + 8 - camZ : 0;
            order.push_back({dx * dx + dy * dy + dz * dz, sid});
        }
        std::sort(order.begin(), order.end());
        std::vector<int> rest;
        uint64_t triangles = 0;
        for (auto& [d, sid] : order) {
            auto it = g_rt.find(sid);
            if (it == g_rt.end()) continue;             // deleted meanwhile
            Section* s = section(sid);
            if (!s) { if (it->second.blas) g_sceneDirty = true; releaseSection(it->second); g_rt.erase(it); continue; }
            if (jobs.size() >= kMaxBuildsPerFrame || triangles >= kMaxBuildTrianglesPerFrame) { rest.push_back(sid); continue; }
            it->second.queued = false;
            NSMutableArray* geoms = [NSMutableArray array];
            Job j{};
            j.sid = sid;
            j.ox = s->ox; j.oy = s->oy; j.oz = s->oz;
            int g = 0;
            for (int layer = 0; layer < 3; layer++) {
                uint32_t quads = s->layers[layer] ? s->vertices[layer] / 4 : 0;
                if (!quads) continue;
                MTLAccelerationStructureTriangleGeometryDescriptor* gd = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
                gd.vertexBuffer = s->layers[layer];
                gd.vertexBufferOffset = 0;
                gd.vertexStride = 28;
                gd.vertexFormat = MTLAttributeFormatFloat3;
                gd.indexBuffer = quadIndices(quads);
                gd.indexBufferOffset = 0;
                gd.indexType = MTLIndexTypeUInt32;
                gd.triangleCount = quads * 2;
                gd.opaque = layer == 0;
                gd.allowDuplicateIntersectionFunctionInvocation = YES;
                [geoms addObject:gd];
                [buildKeep addObject:gd.indexBuffer];
                j.verts[g] = s->layers[layer];
                j.layers |= (uint32_t)layer << (2 * g);
                g++;
                triangles += quads * 2;
            }
            if (g == 0) {
                if (it->second.blas) g_sceneDirty = true;
                releaseSection(it->second);
                it->second.blas = nil;
                for (auto& v : it->second.verts) v = nil;
                continue;
            }
            j.desc = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
            j.desc.geometryDescriptors = geoms;
            MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:j.desc];
            j.as = [dev newAccelerationStructureWithSize:sz.accelerationStructureSize];
            if (!j.as) { rest.push_back(sid); it->second.queued = true; continue; }
            j.scratchOffset = scratchBytes;
            scratchBytes += align256(sz.buildScratchBufferSize);
            jobs.push_back(j);
        }
        g_queue.swap(rest);
    }
    if (!jobs.empty()) g_sceneDirty = true;
    // sections rebuilt this frame switch to their new BLAS (built before the TLAS below)
    for (Job& j : jobs) {
        RtSection& r = g_rt[j.sid];
        releaseSection(r);
        residentAdd(j.as);
        for (int g = 0; g < 3; g++) residentAdd(j.verts[g]);
        r.blas = j.as;
        for (int g = 0; g < 3; g++) r.verts[g] = j.verts[g];
        r.layers = j.layers;
        r.ox = j.ox; r.oy = j.oy; r.oz = j.oz;
    }

    // ---- TLAS (only when sections changed or the origin moved) ----
    int64_t ox = snapOrigin(camX), oy = snapOrigin(camY), oz = snapOrigin(camZ);
    bool originMoved = g_cur < 0 || g_tlas[g_cur].ox != ox || g_tlas[g_cur].oy != oy || g_tlas[g_cur].oz != oz;
    MTLInstanceAccelerationStructureDescriptor* td = nil;
    MTLAccelerationStructureSizes tsz{};
    int next = -1;
    if (g_sceneDirty || originMoved) {
        next = (g_cur + 1 + kTlasSlots) % kTlasSlots;
        TlasSlot& t = g_tlas[next];
        std::vector<MTLAccelerationStructureUserIDInstanceDescriptor> descs;
        std::vector<RtInstanceData> inst;
        NSMutableArray* blases = [NSMutableArray array];
        t.resources.clear();
        // instances cover everything loaded within the radius of the origin cell
        double reach = radius + kOriginStep;
        double cx = ox + kOriginStep * 0.5, cy = oy + kOriginStep * 0.5, cz = oz + kOriginStep * 0.5;
        for (auto& kv : g_rt) {
            const RtSection& r = kv.second;
            if (!r.blas) continue;
            if (fabs(r.ox + 8 - cx) > reach || fabs(r.oz + 8 - cz) > reach || fabs(r.oy + 8 - cy) > reach) continue;
            MTLAccelerationStructureUserIDInstanceDescriptor d{};
            d.transformationMatrix.columns[0] = MTLPackedFloat3Make(1, 0, 0);
            d.transformationMatrix.columns[1] = MTLPackedFloat3Make(0, 1, 0);
            d.transformationMatrix.columns[2] = MTLPackedFloat3Make(0, 0, 1);
            d.transformationMatrix.columns[3] = MTLPackedFloat3Make((float)(r.ox - ox), (float)(r.oy - oy), (float)(r.oz - oz));
            d.options = MTLAccelerationStructureInstanceOptionNone;
            d.mask = 0xFF;
            d.intersectionFunctionTableOffset = 0;
            d.accelerationStructureIndex = (uint32_t)blases.count;
            d.userID = (uint32_t)inst.size();
            descs.push_back(d);
            [blases addObject:r.blas];
            t.resources.push_back(r.blas);
            RtInstanceData rd{};
            for (int g = 0; g < 3; g++) {
                if (!r.verts[g]) continue;
                rd.verts[g] = r.verts[g].gpuAddress;
                t.resources.push_back(r.verts[g]);
            }
            rd.layers = r.layers;
            inst.push_back(rd);
        }
        t.count = (uint32_t)descs.size();
        t.ox = ox; t.oy = oy; t.oz = oz;
        if (t.count) {
            t.desc = ensureBuffer(t.desc, descs.size() * sizeof descs[0], MTLResourceStorageModeShared);
            memcpy(t.desc.contents, descs.data(), descs.size() * sizeof descs[0]);
            t.inst = ensureBuffer(t.inst, inst.size() * sizeof inst[0], MTLResourceStorageModeShared);
            memcpy(t.inst.contents, inst.data(), inst.size() * sizeof inst[0]);
            td = [MTLInstanceAccelerationStructureDescriptor descriptor];
            td.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeUserID;
            td.instanceDescriptorBuffer = t.desc;
            td.instanceDescriptorStride = sizeof(MTLAccelerationStructureUserIDInstanceDescriptor);
            td.instanceCount = descs.size();
            td.instancedAccelerationStructures = blases;
            tsz = [dev accelerationStructureSizesWithDescriptor:td];
            if (!t.tlas || t.size < tsz.accelerationStructureSize) {
                t.size = tsz.accelerationStructureSize + tsz.accelerationStructureSize / 2;
                t.tlas = [dev newAccelerationStructureWithSize:t.size];
            }
        }
        NSMutableArray* keep = [NSMutableArray arrayWithObject:blases];
        for (id<MTLResource> r : t.resources) [keep addObject:r];
        t.keep = keep;
        g_sceneDirty = false;
    }
    size_t tlasScratchOffset = scratchBytes;
    if (td) scratchBytes += align256(tsz.buildScratchBufferSize);
    if (scratchBytes) g_scratch[frameSlot] = ensureBuffer(g_scratch[frameSlot], scratchBytes, MTLResourceStorageModePrivate);

    if (!jobs.empty()) {
        MTLAccelerationStructurePassDescriptor* ap = [MTLAccelerationStructurePassDescriptor accelerationStructurePassDescriptor];
        profAccel(ap, "rt blas");
        id<MTLAccelerationStructureCommandEncoder> e = [cb accelerationStructureCommandEncoderWithDescriptor:ap];
        e.label = @"rt blas";
        for (Job& j : jobs) {
            [e buildAccelerationStructure:j.as descriptor:j.desc scratchBuffer:g_scratch[frameSlot] scratchBufferOffset:j.scratchOffset];
            [buildKeep addObject:j.as];
        }
        [e endEncoding];
    }
    if (next >= 0) {
        if (td && g_tlas[next].tlas) {
            MTLAccelerationStructurePassDescriptor* ap = [MTLAccelerationStructurePassDescriptor accelerationStructurePassDescriptor];
            profAccel(ap, "rt tlas");
            id<MTLAccelerationStructureCommandEncoder> e = [cb accelerationStructureCommandEncoderWithDescriptor:ap];
            e.label = @"rt tlas";
            [e buildAccelerationStructure:g_tlas[next].tlas descriptor:td scratchBuffer:g_scratch[frameSlot] scratchBufferOffset:tlasScratchOffset];
            [e endEncoding];
        }
        g_cur = next;
    }
    TlasSlot& t = g_tlas[g_cur];
    if (g_residency) {
        if (@available(macOS 15.0, *)) {
            id<MTLResidencySet> rs = (id<MTLResidencySet>)g_residency;
            size_t kept = 0;
            for (auto& [frame, a] : g_pendingRemoval) {
                if (frame <= g_frame) { [rs removeAllocation:(id<MTLAllocation>)a]; g_residencyDirty = true; }
                else g_pendingRemoval[kept++] = {frame, a};
            }
            g_pendingRemoval.resize(kept);
            if (g_residencyDirty) { [rs commit]; g_residencyDirty = false; }
            [cb useResidencySet:rs];
        }
    }
    // keep everything this frame may touch alive until it completes
    NSArray* keep = t.keep;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { (void)keep; (void)buildKeep; }];

    if (g_optGpuStats && (g_frame % 600) == 0)
        log("rt: %u instances, %zu queued, %zu builds this frame, device memory %.0f MB", t.count, g_queue.size(), jobs.size(),
            dev.currentAllocatedSize / 1048576.0);

    if (!t.count || !t.tlas) return false;
    out.tlas = t.tlas;
    out.instances = t.inst;
    out.instanceCount = t.count;
    out.resources = g_residency ? nullptr : &t.resources;
    out.camera = simd_make_float3((float)(camX - t.ox), (float)(camY - t.oy), (float)(camZ - t.oz));
    return true;
}

// ---- entities ----

namespace {

struct EntSource {             // RtEntSource in adv.metal
    simd_float4x4 toRt;
    simd_float4x4 texMat;
    simd_float4 color;
    VertexLayout layout;
    uint32_t first, count, draw, pad;
    uint64_t vb, pad2;
};
static_assert(sizeof(EntSource) == 272, "EntSource layout");

struct EntDraw {               // RtEntDraw in adv.metal
    uint32_t tex, flags;
    float alphaRef, emissive;
    float lm[2];
    float pad[2];
};
static_assert(sizeof(EntDraw) == 32, "EntDraw layout");

constexpr uint32_t kEntVertexStride = 32;               // RtEntVertex
constexpr uint32_t kMaxEntityVertices = 1u << 20;       // 256k quads

struct EntSlot {
    id<MTLAccelerationStructure> as = nil;
    size_t asSize = 0;
    uint32_t triangles = 0;              // what `as` holds (0: nothing valid)
    id<MTLBuffer> src = nil, verts = nil, draws = nil, textures = nil, scratch = nil;
    std::vector<id<MTLResource>> resources;
    std::unordered_set<void*> buffers;   // vertex buffers the conversion reads
};
EntSlot g_ent[kFramesInFlight];
uint64_t g_entLastFrame = ~0ull;
int g_entPrev = -1;                      // slot built or refit last
uint32_t g_entSinceBuild = 0;            // refits since the last full build
constexpr uint32_t kEntRefitsPerBuild = 15;
id<MTLComputePipelineState> g_entKernel = nil;
bool g_entKernelTried = false;
id<MTLAccelerationStructure> g_entDummy = nil;
id<MTLBuffer> g_entDummyVerts = nil, g_entDummyDraws = nil, g_entDummyTex = nil;
bool g_entDummyBuilt = false;
std::vector<id<MTLResource>> g_entNoResources;

MTLPrimitiveAccelerationStructureDescriptor* entDescriptor(id<MTLBuffer> verts, uint32_t quads) {
    MTLAccelerationStructureTriangleGeometryDescriptor* gd = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    gd.vertexBuffer = verts;
    gd.vertexBufferOffset = 0;
    gd.vertexStride = kEntVertexStride;
    gd.vertexFormat = MTLAttributeFormatFloat3;
    gd.indexBuffer = quadIndices(quads);
    gd.indexBufferOffset = 0;
    gd.indexType = MTLIndexTypeUInt32;
    gd.triangleCount = quads * 2;
    gd.opaque = NO;   // alpha-tested draws are resolved in the shaders' intersection loops
    gd.allowDuplicateIntersectionFunctionInvocation = YES;
    MTLPrimitiveAccelerationStructureDescriptor* pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    pd.geometryDescriptors = @[gd];
    pd.usage = MTLAccelerationStructureUsagePreferFastBuild | MTLAccelerationStructureUsageRefit;
    return pd;
}

} // namespace

bool rtBuildEntities(id<MTLCommandBuffer> cb, const std::vector<RtEntityDraw>& in, RtEntities& out) {
    out = RtEntities();
    if (!rtAvailable()) return false;
    id<MTLDevice> dev = device();
    if (!g_entKernelTried) {
        g_entKernelTried = true;
        MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
        bool f = false;
        for (NSUInteger i = 10; i <= 12; i++) [cv setConstantValue:&f type:MTLDataTypeBool atIndex:i];
        NSError* err = nil;
        id<MTLFunction> k = [engine().library newFunctionWithName:@"rt_entity_vertices" constantValues:cv error:&err];
        if (k) g_entKernel = [dev newComputePipelineStateWithFunction:k error:&err];
        if (!g_entKernel) log("rt: entity kernel: %s", err ? err.localizedDescription.UTF8String : "missing");
    }
    if (!g_entKernel) return false;

    // placeholder for frames without entities (the shaders always have something bound)
    if (!g_entDummyBuilt) {
        g_entDummyBuilt = true;
        g_entDummyVerts = [dev newBufferWithLength:kEntVertexStride * 4 options:MTLResourceStorageModeShared];
        float* v = (float*)g_entDummyVerts.contents;
        memset(v, 0, kEntVertexStride * 4);
        for (int i = 0; i < 4; i++) { v[i * 8 + 0] = 1e7f; v[i * 8 + 1] = 1e7f; v[i * 8 + 2] = 1e7f; }
        g_entDummyDraws = [dev newBufferWithLength:sizeof(EntDraw) options:MTLResourceStorageModeShared];
        memset(g_entDummyDraws.contents, 0, sizeof(EntDraw));
        g_entDummyTex = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        memset(g_entDummyTex.contents, 0, 16);
        MTLPrimitiveAccelerationStructureDescriptor* pd = entDescriptor(g_entDummyVerts, 1);
        MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:pd];
        g_entDummy = [dev newAccelerationStructureWithSize:sz.accelerationStructureSize];
        id<MTLBuffer> scratch = [dev newBufferWithLength:std::max<size_t>(sz.buildScratchBufferSize, 256) options:MTLResourceStorageModePrivate];
        if (g_entDummy) {
            id<MTLAccelerationStructureCommandEncoder> e = [cb accelerationStructureCommandEncoder];
            e.label = @"rt entities (placeholder)";
            [e buildAccelerationStructure:g_entDummy descriptor:pd scratchBuffer:scratch scratchBufferOffset:0];
            [e endEncoding];
            id<MTLBuffer> idx = ((MTLAccelerationStructureTriangleGeometryDescriptor*)pd.geometryDescriptors[0]).indexBuffer;
            [cb addCompletedHandler:^(id<MTLCommandBuffer>) { (void)scratch; (void)idx; }];
        }
    }
    if (!g_entDummy) return false;
    out.as = g_entDummy;
    out.verts = g_entDummyVerts;
    out.draws = g_entDummyDraws;
    out.textures = g_entDummyTex;
    out.resources = &g_entNoResources;

    // one build per engine frame (a slot's buffers are free again once its frame is reused)
    uint64_t frame = engine().frameIndex;
    if (frame == g_entLastFrame) return true;
    g_entLastFrame = frame;
    EntSlot& s = g_ent[frame % kFramesInFlight];
    s.triangles = 0;   // this slot is being rewritten (or left unused this frame)
    if (in.empty()) { g_entPrev = -1; return true; }

    uint64_t t0 = g_optGpuStats ? mach_absolute_time() : 0;
    // records are written straight into this slot's shared buffers
    s.src = ensureBuffer(s.src, in.size() * sizeof(EntSource), MTLResourceStorageModeShared);
    s.draws = ensureBuffer(s.draws, in.size() * sizeof(EntDraw), MTLResourceStorageModeShared);
    EntSource* src = (EntSource*)s.src.contents;
    EntDraw* draws = (EntDraw*)s.draws.contents;
    std::vector<MTLResourceID> texIds;
    s.resources.clear();
    s.buffers.clear();
    id<MTLTexture> lastTex = nil;
    id<MTLBuffer> lastVb = nil;
    uint32_t lastTi = 0, count = 0, total = 0;
    for (const RtEntityDraw& d : in) {
        if (!d.vb || !d.tex || !d.layout || d.vertices < 4) continue;
        uint32_t n = d.vertices & ~3u;
        if (total + n > kMaxEntityVertices) break;
        if (d.tex != lastTex) {   // consecutive draws mostly share a texture
            uint32_t ti = 0;
            while (ti < s.resources.size() && s.resources[ti] != d.tex) ti++;
            if (ti == s.resources.size()) {
                s.resources.push_back(d.tex);
                texIds.push_back(d.tex.gpuResourceID);
            }
            lastTex = d.tex;
            lastTi = ti;
        }
        if (d.vb != lastVb) {
            s.buffers.insert((__bridge void*)d.vb);
            lastVb = d.vb;
        }
        EntSource& e = src[count];
        e.toRt = d.toRt;
        e.texMat = d.texMat;
        e.color = d.color;
        e.layout = *d.layout;
        e.first = total;
        e.count = n;
        e.draw = count;
        e.pad = 0;
        e.vb = d.vb.gpuAddress + d.offset;
        e.pad2 = 0;
        EntDraw& dr = draws[count];
        dr.tex = lastTi;
        dr.flags = d.alphaTest ? 1u : 0u;
        dr.alphaRef = d.alphaRef;
        dr.emissive = d.emissive;
        dr.lm[0] = d.lightmap.x;
        dr.lm[1] = d.lightmap.y;
        dr.pad[0] = dr.pad[1] = 0;
        count++;
        total += n;
    }
    if (!total) { g_entPrev = -1; return true; }
    std::vector<id<MTLResource>> buffers;
    buffers.reserve(s.buffers.size());
    for (void* b : s.buffers) buffers.push_back((__bridge id<MTLBuffer>)b);
    s.textures = ensureBuffer(s.textures, texIds.size() * sizeof(MTLResourceID), MTLResourceStorageModeShared);
    memcpy(s.textures.contents, texIds.data(), texIds.size() * sizeof(MTLResourceID));
    s.verts = ensureBuffer(s.verts, (size_t)total * kEntVertexStride, MTLResourceStorageModePrivate);

    MTLComputePassDescriptor* cp = [MTLComputePassDescriptor computePassDescriptor];
    profCompute(cp, "rt entity vertices");
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoderWithDescriptor:cp];
    ce.label = @"rt entity vertices";
    [ce setComputePipelineState:g_entKernel];
    [ce setBuffer:s.src offset:0 atIndex:0];
    uint32_t counts[2] = {count, total};
    [ce setBytes:counts length:sizeof counts atIndex:1];
    [ce setBuffer:s.verts offset:0 atIndex:2];
    [ce useResources:buffers.data() count:buffers.size() usage:MTLResourceUsageRead];
    [ce dispatchThreads:MTLSizeMake(total, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];

    MTLPrimitiveAccelerationStructureDescriptor* pd = entDescriptor(s.verts, total / 4);
    MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:pd];
    int slot = (int)(frame % kFramesInFlight);
    // Entities move every frame but mostly keep their triangles: refit last frame's
    // structure into this slot, with a full rebuild when the count changes and every
    // few frames (refits loosen the hierarchy as things move).
    EntSlot* prev = g_entPrev >= 0 && g_entPrev != slot ? &g_ent[g_entPrev] : nullptr;
    bool refit = prev && prev->as && prev->triangles == total / 2 && g_entSinceBuild < kEntRefitsPerBuild;
    size_t need = refit ? prev->asSize : sz.accelerationStructureSize;
    if (!s.as || s.asSize < need) {
        s.asSize = refit ? prev->asSize : sz.accelerationStructureSize + sz.accelerationStructureSize / 2;
        s.as = [dev newAccelerationStructureWithSize:s.asSize];
        if (!s.as) { s.asSize = 0; s.triangles = 0; return true; }
    }
    s.scratch = ensureBuffer(s.scratch, std::max<size_t>(std::max(sz.buildScratchBufferSize, sz.refitScratchBufferSize), 256),
                             MTLResourceStorageModePrivate);
    MTLAccelerationStructurePassDescriptor* ap = [MTLAccelerationStructurePassDescriptor accelerationStructurePassDescriptor];
    profAccel(ap, refit ? "rt entities refit" : "rt entities");
    id<MTLAccelerationStructureCommandEncoder> e = [cb accelerationStructureCommandEncoderWithDescriptor:ap];
    e.label = refit ? @"rt entities refit" : @"rt entities";
    if (refit) {
        [e refitAccelerationStructure:prev->as descriptor:pd destination:s.as scratchBuffer:s.scratch scratchBufferOffset:0];
        g_entSinceBuild++;
    } else {
        [e buildAccelerationStructure:s.as descriptor:pd scratchBuffer:s.scratch scratchBufferOffset:0];
        g_entSinceBuild = 0;
    }
    [e endEncoding];
    s.triangles = total / 2;
    g_entPrev = slot;
    id<MTLBuffer> idx = ((MTLAccelerationStructureTriangleGeometryDescriptor*)pd.geometryDescriptors[0]).indexBuffer;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { (void)idx; }];

    out.as = s.as;
    out.verts = s.verts;
    out.draws = s.draws;
    out.textures = s.textures;
    out.resources = &s.resources;
    out.triangles = total / 2;
    if (g_optGpuStats) {
        static double cpuMs = 0;
        static uint32_t samples = 0;
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        cpuMs += (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
        if (++samples == 600) {
            log("rt entities: %u draws, %u triangles, %zu textures, structure %.1f MB, cpu %.3f ms/frame", count, total / 2,
                s.resources.size(), s.asSize / 1048576.0, cpuMs / samples);
            cpuMs = 0;
            samples = 0;
        }
    }
    return true;
}

} // namespace m189
