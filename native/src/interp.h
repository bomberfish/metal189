// metal189: MetalFX frame interpolation (macOS 26): a generated frame between the previous
// frame and this one, presented before it.
//
// The shaders pipeline captures the world as it finished it (image, depth and camera
// motion at output resolution); at present time whatever was drawn over it since (hand,
// particles, weather, HUD, menus) becomes the UI layer MetalFX lays over the generated frame
// instead of warping it with the world.
#pragma once
#import "engine.h"
#include <simd/simd.h>

namespace m189 {

bool interpSupported();
bool interpWanted();   // the setting is on and the shaders pipeline runs

// The world capture's textures for this frame, made when needed; false when interpolation is
// off or unavailable. The world image keeps the framebuffer's size and format (Minecraft may
// render at another size than the window); depth and motion are at the screen's size.
struct InterpCapture {
    id<MTLTexture> world = nil;    // the tonemapped world, as rendered
    id<MTLTexture> depth = nil;    // Depth32Float, screen size
    id<MTLTexture> motion = nil;   // RG16Float, screen size: pixels to the previous frame's position
    int screenW = 0, screenH = 0;
};
bool interpBeginCapture(int worldW, int worldH, MTLPixelFormat worldFormat, InterpCapture& out);
// The camera the capture was made with (for MetalFX's view parameters).
void interpCaptured(const simd_float4x4& proj, const simd_float4x4& view, bool cut);

// Encodes the generated frame between the previous final frame and `finalFrame` (this frame's
// screen image) into `out` (same size and format); false when there is none this frame (no
// world capture, a cut, sizes changed). Keeps `finalFrame` as the next frame's previous.
bool interpEncode(id<MTLCommandBuffer> cb, id<MTLTexture> finalFrame, id<MTLTexture> out);
MTLTextureUsage interpOutputUsage();
double interpFrameInterval();   // seconds between rendered frames (smoothed)
void interpRelease();

} // namespace m189
