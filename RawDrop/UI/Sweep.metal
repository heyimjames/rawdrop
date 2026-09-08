#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// A soft band of amber light crossing the tile diagonally, once every 1.6s.
// Applied only to the tile whose RAW is being copied right now.
[[ stitchable ]] half4 sweep(float2 position, half4 color, float2 size, float time) {
    float t = fract(time / 1.6);
    float diagonal = (position.x + position.y) / max(size.x + size.y, 1.0);
    float band = diagonal - (t * 1.8 - 0.4);
    float glow = exp(-band * band * 90.0);
    half3 amber = half3(1.0, 0.78, 0.18);
    half3 lit = color.rgb + amber * half(glow) * 0.5h * color.a;
    return half4(lit, color.a);
}

// One pass of white light across a surface, driven by progress 0→1 instead
// of a clock. Used once, on the RAW card as it lands on first open.
// `intensity` lets the same highlight follow a drag: the lamp stays still,
// the card moves under it, and the light fades as the card settles.
[[ stitchable ]] half4 glint(float2 position, half4 color, float2 size, float progress, float intensity) {
    float diagonal = (position.x + position.y) / max(size.x + size.y, 1.0);
    float band = diagonal - (progress * 1.8 - 0.4);
    float glow = exp(-band * band * 140.0) * intensity;
    half3 lit = color.rgb + half3(1.0h) * half(glow) * 0.42h * color.a;
    return half4(lit, color.a);
}
