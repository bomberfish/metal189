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
