# metal189

A native **Metal** rendering engine for **Minecraft 1.8.9 (Forge)** on macOS.

metal189 replaces the game's OpenGL/LWJGL rendering entirely, in the spirit of
VulkanMod: a native engine owns the window, the frame, the passes, terrain storage
and every GPU resource, while vanilla code only supplies scene data (block meshing,
entity models, GUI layout). It ships two renderers and an optional ray tracing tier:

* **Baseline**: a vanilla-exact forward renderer. Fixed-function lighting, fog,
  alpha test, texture combiners, quad splitting and sampler behaviour all match
  Apple's OpenGL driver, so it looks like vanilla, only much faster.
* **Advanced** ("shaders"): a deferred PBR pipeline with shadows, a physically based
  sky, volumetric clouds and light shafts, water with refraction and reflections,
  bloom, TAA, auto exposure and LabPBR resource pack support.
* **Ray tracing** (optional): hardware-accelerated ray-traced sun shadows over the
  whole loaded world, ray-traced reflections (water, metals, polished and wet
  surfaces), ray-traced ambient occlusion and one-bounce global illumination.

It is an OptiFine replacement: if OptiFine is installed too, metal189 stays disabled
(the game runs with vanilla OpenGL and a notice on the main menu explains why).

## Requirements

* macOS 14 or newer (macOS 15+ recommended: ray tracing uses residency sets there).
* Apple silicon (the native library is universal, so x86_64 Java under Rosetta also
  works). Ray tracing runs on every Apple silicon GPU and is hardware-accelerated on
  M3 and later.
* Minecraft 1.8.9 with Forge 11.15.1.x (for example a Prism Launcher instance).

## Installing

1. Build the jar (see below) or take `build/libs/metal189-0.1.0.jar`.
2. Copy it into the instance's `mods` folder (Prism: *Edit Instance → Mods →
   Add file*, or open the instance's `.minecraft/mods` folder).
3. Remove OptiFine from the instance if it is installed.
4. Launch. The first start unpacks the native library into
   `~/Library/Caches/metal189/`.

## Using it

* **Video Settings → Shaders...** opens the rendering settings.
* **F6** toggles the advanced pipeline on or off. A second key, *Rendering Settings*
  (unbound by default), opens the settings screen; both can be rebound under
  Controls → metal189.
* Settings persist in `config/metal189.properties`.

| Setting | Default | What it does |
|---|---|---|
| Shaders | off | Advanced pipeline on/off (off = vanilla-exact renderer) |
| Shadows / Resolution / Distance | on, 4096, 112 | Sun/moon shadow map (PCF), snapped to texels |
| Bloom / Bloom Strength | on, 100% | 6-level HDR bloom with bright-source compression |
| Physical Sky | on | Rayleigh/Mie atmosphere, sun/moon discs, stars |
| Water Effects | on | Waves, refraction with absorption, SSR, Fresnel, sun glint |
| Waving Foliage | on | Plants bend from the base, leaves sway (shadows follow) |
| Temporal AA | on | Jittered TAA with variance clipping + CAS sharpening |
| Volumetric Clouds | on | Raymarched cumulus layer, cloud shadows on terrain |
| Light Shafts | on | Volumetric sun scattering through the shadow map |
| Auto Exposure | on | Eye adaptation (scene log-average luminance, on the GPU) |
| Ambient Occlusion | on | Screen-space AO (HBAO+ style, half resolution) on top of vanilla's baked AO |
| Exposure | 100% | Manual exposure bias |
| RT Shadows | off | Ray-traced sun shadows for all loaded terrain |
| RT Reflections | off | Ray-traced reflections on water, metals, polished and wet surfaces |
| RT Ambient Occlusion | off | Short-range ray-traced occlusion of indirect light (denoised) |
| RT Global Illumination | off | One-bounce ray-traced diffuse GI (sky light, sun bounce, emissive blocks), temporally accumulated |

### PBR resource packs

Packs that follow the **LabPBR** convention work out of the box: `_n` textures
(normal XY in OpenGL convention, AO, height) and `_s` textures (smoothness,
F0 / metal ids, porosity/SSS, emission) next to the block textures. When no pack
provides material textures, heuristic materials are used (foliage translucency,
metal blocks, water, emissive blocks).

## Performance

Measured on an Apple M4 Pro, render distance 16, forest scene:

| Renderer | 854x480 | 1920x1080 |
|---|---|---|
| Vanilla OpenGL (Apple's driver) | | 60-81 fps |
| metal189 baseline | ~940 fps | ~1100 fps (GPU 1.3 ms) |
| metal189 advanced (shadows, bloom, sky, water) | | ~480 fps |
| + TAA, clouds, light shafts, auto exposure | | ~320 fps |
| advanced + RT shadows + RT reflections | | ~290 fps |

With 300 mobs at 1080p the baseline renders 239 fps static / 473 fps rotating
(vanilla OpenGL: 72 / 103).

## Building

Requirements: Xcode command line tools with the Metal toolchain, a JDK 17 to run
Gradle, and a JDK 8 (Zulu 8, arm64) for the game.

```sh
export JAVA_HOME=/path/to/jdk-17
./gradlew build -x test        # native library + metallib + reobfuscated jar
```

The jar is written to `build/libs/metal189-0.1.0.jar` (with the native library and
shader library inside). For native-only changes, `cd native && make` rebuilds
`native/build/`, which test runs load directly.

## Development and testing

Tests run a separate client in `run/` (built from the Prism libraries, never the
user's instance), in a background window that never grabs the pointer:

* `tools/run-client.sh [--gl] [--jar-natives] [-Dprop=value]` launches the client
  (`--gl` runs vanilla OpenGL for reference).
* `tools/compare-scene.sh SCENE NAME` captures a scene under vanilla OpenGL and
  under metal189's baseline renderer and diffs the frames.
* `tools/look.sh NAME` (with `SCENE=...`) captures look-dev scenes with the
  advanced pipeline into `captures/NAME/montage.png`.
* `tools/perf.sh SCENE W H name:"jvm args" ...` benchmarks configurations.
* Scene scripts live in `tests/scenes/` (world creation, teleports, commands,
  captures, fps measurement, runtime config changes).

Useful properties: `-Dmetal189.shaders=true|false`,
`-Dmetal189.shaderFeatures=<bits>`, `-Dmetal189.gpuStats=true` (per-pass GPU
timings), `-Dmetal189.advDebug=<view>` (1 no fog, 2 albedo, 3 normals, 4 lighting,
5 shadow map, 6 RT shadows).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the engine is put together.

## Compatibility notes

* Mods that call OpenGL directly go through metal189's GL compatibility layer,
  which covers what vanilla and Forge use; mods with custom GL shaders or exotic
  GL features may not render correctly.
* OptiFine is not supported (metal189 replaces it).
