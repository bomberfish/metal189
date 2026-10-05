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

**Required**

* A Mac with Apple silicon (M1 or later).
* macOS 14 Sonoma or newer (the shaders are Metal 3.1).
* Minecraft 1.8.9 with Forge 11.15.1.x (for example a Prism Launcher instance) and a
  Java 8 runtime. An arm64 Java 8 such as Zulu 8 is best; x86_64 Java under Rosetta
  also runs, since the native library is universal.
* No OptiFine in the same instance (metal189 replaces it).

**Recommended: macOS 26 or newer.** Several features need it, mostly MetalFX:

| Feature | Needs |
|---|---|
| Baseline renderer, shaders pipeline, MetalFX spatial and temporal upscaling | macOS 14 |
| Ray tracing (shadows, reflections, AO, GI, entities) | macOS 14; macOS 15 or newer recommended (residency sets) |
| MetalFX Denoised upscaling (ray-reconstruction-style denoiser) | macOS 26 |
| MetalFX Frame Interpolation | macOS 26 |

On older macOS versions those settings switch themselves off.

**Which chip for what**

* **Any Apple silicon:** the baseline renderer and the full shaders pipeline,
  including world-space reflections and GI, which need no ray tracing hardware.
* **M3 or later** for ray-traced effects at playable frame rates (hardware-accelerated
  ray tracing). M1 and M2 can turn them on, but they run in software and are slow;
  the presets only enable ray tracing on chips that accelerate it.
* **M5 or later** for the MetalFX denoiser and frame interpolation. Both are neural
  networks; on earlier chips they cost more than they save (on an M4 Pro at 1440p the
  denoiser takes about 23 ms a frame and interpolation about 12 ms per generated
  frame), so they are off by default.

Intel Macs are not supported.

## Installing

1. Download the jar from the [releases page](https://github.com/bomberfish/metal189/releases),
   or build it (see below).
2. Copy it into the instance's `mods` folder (Prism: *Edit Instance → Mods →
   Add file*, or open the instance's `.minecraft/mods` folder).
3. Remove OptiFine from the instance if it is installed.
4. Launch. The first start unpacks the native library into
   `~/Library/Caches/metal189/`.

## Using it

* **Video Settings → Rendering...** opens the rendering settings.
* **K** toggles the advanced pipeline on or off. A second key, *Rendering Settings*
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

Apple M4 Pro, render distance 16, forest scene (two views), measured 2026-10-03 on a
machine under other load (load average ~8):

| Renderer | 854x480 | 1920x1080 | 2560x1440 |
|---|---|---|---|
| Vanilla OpenGL (Apple's driver) | | 71-88 fps | |
| metal189 baseline (vanilla-exact) | 964-1234 fps | 911-1107 fps | 865-1073 fps |
| metal189 advanced, default settings* | | 245-247 fps | 169-172 fps |
| advanced + RT shadows, reflections, AO and GI | | 124-137 fps | |

\* shadows, bloom, physical sky, water, TAA, volumetric clouds, light shafts, auto
exposure and SSAO. Shadows, bloom, sky and water alone run at about 480 fps at 1080p.

300 mobs in view at 1080p: baseline 228 fps static / 506 fps rotating (vanilla
OpenGL: 83 / 136).

## Building

Requirements: Xcode command line tools with the Metal toolchain, a JDK 17 to run
Gradle, and a JDK 8 (Zulu 8, arm64) for the game.

```sh
export JAVA_HOME=/path/to/jdk-17
./gradlew build -x test        # native library + metallib + reobfuscated jar
```

The jar is written to `build/libs/metal189-<version>.jar` (with the native library
and shader library inside; the `-dev` jar next to it is the deobfuscated build). For native-only changes, `cd native && make` rebuilds
`native/build/`, which test runs load directly.

### iOS (experimental)

`./gradlew iosJar` builds `build/libs/metal189-<version>-ios.jar`: the same mod with an
arm64 iOS native library (iOS 17+, ad-hoc signed) and an iOS shader library, for
launchers that run Forge 1.8.9 on iOS. It unpacks its natives inside the app's
container (`$HOME/Library/Caches/metal189`). Tested under Amethyst on an iPad Pro (M5,
iPadOS 27): 120 fps (the display's limit) at 2816×1940, 42–47 fps with shaders.

Under [Amethyst](https://github.com/AngelAuraMC/Amethyst-iOS) (the maintained
PojavLauncher fork) it draws into the launcher's own game surface and takes input from
its controls (touch, virtual mouse, on-screen and hardware keyboards, mouse and
gamepad), as a Vulkan game would: it asks Amethyst's GLFW for no OpenGL context and
registers GLFW callbacks. Mouse grab is passed back so the launcher switches its
controls between menus and the game. The profile needs a renderer whose surface is a
Metal layer (not the OSMesa/Zink one); the GL renderer itself goes unused.

Elsewhere it draws into a full-screen Metal view over the launcher's window and takes
input from touch (in menus a finger is the mouse; in game a drag looks around, a tap is
a left click and a two-finger tap a right click), a hardware keyboard, and an iPad mouse
or trackpad.

iOS only loads signed code: `IOS_SIGN_IDENTITY="<identity>" ./gradlew iosJar` signs the
library for the launcher's team (otherwise it is ad-hoc signed, and loads only while the
launcher bypasses library validation).

#### Amethyst on a device over USB, with JIT from a Mac

1. Sign Amethyst for development (get-task-allow) with a profile that grants the
   increased memory limit, swapping in a Java 8 with the iOS 27 JIT fixes, patched:

       tools/amethyst-jvm-fix.py jre8/lib/server/libjvm.dylib
       JRE8=jre8 tools/amethyst-sign.sh amethyst.ipa dev.mobileprovision "<identity>" signed.ipa
       xcrun devicectl device install app --device <udid> Payload/AngelAuraAmethyst.app

   (Java 8 from angelauramc-openjdk-build f03a5a05 or later; Amethyst's July builds carry
   an older one whose JIT faults on iOS 27.)
2. Put `metal189-<version>-ios.jar` in the instance's `mods`, and give Java these
   arguments (Amethyst settings): `-XX:+PreferInterpreterNativeStubs
   -XX:ReservedCodeCacheSize=128m -XX:InitialCodeCacheSize=128m
   -XX:CompressedClassSpaceSize=128m`, with at most about 1.5 GB of memory (the process
   gets about 4 GB of address space in all).
3. `tools/amethyst-jit.py --play "<profile>"` launches Amethyst, attaches Xcode's lldb,
   presses Play and serves Amethyst's JIT requests (what StikDebug does on the device),
   then detaches. Without `--play`, tap Play yourself once it says it is attached.

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

* Mods that call OpenGL directly go through metal189's GL layer, which covers what
  vanilla and Forge use, plus common direct calls (wide lines, constant blend
  colours, framebuffers). Mods with custom GLSL shaders may not render correctly.
* Mods that render the world a second time into their own framebuffer (picture-in-
  picture cameras, mirrors) work; those extra views use the vanilla-exact renderer
  so they cannot disturb the main view's temporal effects.
* Input is LWJGL-exact, except that Ctrl+left click is a left click (macOS turns it
  into a right click under LWJGL). The *Ctrl+Click* setting on the Input page brings
  LWJGL's behaviour back. mcmouser is not needed.
* OptiFine is not supported (metal189 replaces it); with both installed, metal189
  stays off and says so on the main menu.
