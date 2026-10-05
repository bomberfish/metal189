# metal189 architecture

metal189 replaces Minecraft 1.8.9's OpenGL renderer with a native Metal engine,
in the spirit of VulkanMod: the engine owns the frame, the passes, the terrain
system and all GPU resources. Vanilla Java code is used only as a source of
scene data (block meshing, entity animation, GUI layout).

## Layers

```
 Minecraft / Forge (Java)            <- unchanged game logic
   |  ASM patches (metal189.core)
   v
 metal189 Java side
   platform/   window, keyboard, mouse (replaces LWJGL Display/Keyboard/Mouse)
   capture/    GlStateManager / Tessellator / GL11 shim -> scene items
   terrain/    chunk build conversion + section upload + visibility
   world/      frame driver replacing EntityRenderer.renderWorldPass
   engine/     JNI bridge: command stream, vertex arenas, resources
   |  one command stream + vertex arena per frame (direct memory)
   v
 libmetal189.dylib (Objective-C++)
   platform    NSWindow + CAMetalLayer + input events
   engine      device, frame ring, textures, meshes, render targets
   scene       draw items, terrain sections (GPU-resident), environment
   pipelines   baseline (vanilla-exact forward) | advanced (deferred PBR,
               shadows, bloom, ...) | ray tracing (acceleration structures)
```

## Frame model

Java records the whole frame into a command stream: environment and camera
parameters, terrain layer draws, and captured draw items. Each item carries its
phase (sky, terrain layer, entities, particles, weather, translucent, hand,
UI...), a render-state snapshot, textures, a transform and geometry (a static
mesh or a range in the per-frame vertex arena). At `Display.update()` the
native side encodes and submits the frame.

* Baseline pipeline: executes items in capture order with shaders that
  reproduce vanilla's fixed-function results exactly (lightmap, fog, alpha
  test, entity lighting, texture combiners).
* Advanced pipeline: routes the same items into engine passes: shadow maps
  (terrain + entities replayed from the light), G-buffer, deferred PBR
  lighting, forward translucents, sky/clouds, post (bloom, tonemap, TAA...).
* Ray tracing: terrain sections double as BLAS sources.

## Terrain

Vanilla's block renderers still produce quads (so AO, smooth lighting and
tinting are exact), but the output is converted into the engine's own vertex
format (with normals and material ids) and uploaded into GPU-resident section
buffers. Drawing, culling, sorting and shadow rendering are done by the engine.

## Conventions

* Offscreen render targets store rows in GL order (row 0 = bottom), so texture
  coordinates written for GL keep working. Only the drawable is Metal-oriented.
* GL clip-space z [-1,1] is remapped to Metal [0,1] in the vertex stage.

## Advanced pipeline (native/src/advanced.mm, native/shaders/adv.metal)

The world segment of the command stream (between the WORLD_BEGIN and WORLD_END
phase markers) is scanned twice. The first scan collects what the engine renders
itself: terrain layer lists, opaque entity/block-entity draws (QUADS in the
entity phase without blending), the environment record and the target. The second
scan replays everything else (hand, particles, weather, GUI-in-world) with the
baseline executor on top of the result, skipping sky draws, vanilla clouds and
consumed entity draws.

Pass order per frame:

1. **RT scene** (optional): pending section BLAS builds, TLAS rebuild if needed.
2. **Shadow map**: every resident section within reach (not only the visible
   ones) plus collected entities, orthographic projection snapped to texels.
3. **G-buffer**: albedo+AO, normal+emission, light (block/sky/material/roughness),
   exact linear depth, LabPBR specular; Halton-jittered for TAA.
4. **Sky-view LUT** (single-scattering atmosphere, mipmapped for ambient) and the
   **cloud map** (direction-space raymarch of the cloud layer, checkerboarded and
   temporally accumulated).
5. **Deferred lighting**: Cook-Torrance sun/moon light with PCF or ray-traced
   shadows, cloud shadows, split-sum sky reflection, sky ambient, block light,
   emission, fog/haze; sky pixels get atmosphere + clouds + discs + stars.
   Its rays are traced in passes of their own before it (a ray-tracing variant of
   the lighting shader runs everything slower): sun shadows and the held light's
   visibility (`sun_trace_fragment`), reflections (`refl_trace_fragment`), and
   ray-traced block light (`blocklight_trace_fragment`): the voxel volume's light
   properties give a list of light-giving blocks, binned per 8-block cell
   (`light_list_kernel`, `light_grid_kernel`, rebuilt when blocks change); each
   pixel picks two of its cell's lights in proportion to what they would give it
   and traces a shadow ray to a random point of each (tinted by stained glass along
   the way), then the result is accumulated over frames and blurred. Ray-traced sky
   light takes how much sky a point sees from the GI rays (the share that escape)
   instead of the lightmap.
6. **Translucent terrain** (water, glass, ice) forward-shaded over copies of the
   opaque scene: refraction, absorption, SSR or ray-traced reflections.
7. **Light shafts** (half-res shadow-map raymarch) added to HDR.
8. **TAA** resolve, **auto exposure** (compute), **bloom**, **tonemap** (ACES, CAS
   sharpening, vignette) into Minecraft's framebuffer.

Materials come from Materials.java (per block-state id tables uploaded once; the
state id is stamped into the high bytes of each terrain vertex's lightmap shorts)
and, when a resource pack provides them, from LabPBR atlases built in
PbrAtlas.java with the block atlas' layout.

## Ray tracing (native/src/raytrace.mm)

* One primitive acceleration structure per terrain section with a triangle
  geometry per render layer (solid layer opaque; cutout layers alpha-tested in the
  shaders' intersection-query loops). Built when a section is uploaded, closest
  first, under a per-frame budget; the BLAS keeps the vertex buffers it was built
  from so hit shading stays consistent until the rebuild.
* The TLAS lives in ray-tracing space (world coordinates relative to an origin
  that follows the camera in 128-block steps) and is rebuilt only when sections
  change or the origin moves, into a ring slot no in-flight frame can be reading.
* Allocations are kept resident through an MTLResidencySet (macOS 15+), with
  `useResources` as the fallback.
* Shaders use inline `intersection_query` (no intersection function tables): shadow
  rays accept any hit; reflection rays take the closest alpha-tested hit and shade
  it from the section's vertex data (texture, vertex colour, lightmap, sun with a
  shadow ray).

## Auxiliary world segments

`Phases.worldBegin` marks a world render as the main view only when it targets
Minecraft's own framebuffer. Other `renderWorldPass` calls (mods' picture-in-picture
cameras, mirrors) are recorded as `PH_WORLD_BEGIN_AUX` segments: the engine draws
them with the baseline executor and the advanced pipeline neither collects nor
filters them, also when they are nested inside the main segment. This keeps the
main view's G-buffer sizes and temporal histories (TAA, GI, clouds) stable.

## Baseline details worth knowing

* Lines wider than 1 px (`glLineWidth`, e.g. the 2 px block outline) are expanded
  into quads by `ff_line_vertex`, widened along the minor axis like GL's
  non-antialiased lines; this matches Apple's GL pixel for pixel.
* Texture sampling parameters are per-draw state (vanilla toggles mipmapping on the
  block atlas between layers), GL_CLAMP is border clamp, alpha test uses 8-bit fixed
  point, fog is per vertex, quads split along v1-v3: all as Apple's GL does.

## Settings

User settings live in `config/metal189.properties` (metal189.config.Config) and are
applied through world/Pipeline.java, which turns them into the native feature bits
and runtime parameters. `-Dmetal189.shaders` and `-Dmetal189.shaderFeatures`
override the file (tests).
