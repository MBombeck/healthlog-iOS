#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// b182 (TILESFX wave) — EXPERIMENTAL chromatic-rim prism for the Insights score
// ring (P5x). A `[[ stitchable ]]` `.layerEffect`: per pixel, measure the signed
// distance to the ring stroke, build a thin `smoothstep` band (zero in the flat
// interior so the centre number is never touched), then sample the rasterised
// ring 3x with the R/G/B sample positions pushed apart RADIALLY — white rim
// pixels split into faint green/yellow/blue/red like a lens fringe. Own ~30-line
// shader, no vendored dependency (technique learned from krispuckett/SwiftUIShaders
// + Inferno's RGB-split layer effect).
//
//   center    — ring centre in view space (pt)
//   radius    — stroke centreline radius (pt)
//   thickness — stroke width (pt) → the band half-width
//   off       — radial fringe push (pt) at the rim peak
//   chroma    — per-channel spread (R pushed out, B pulled in)
//   time      — animation clock; slowly rotates the fringe direction
//
// Does NOT render in the Simulator / ImageRenderer — judge on a physical device.
[[ stitchable ]]
half4 insightsRingPrism(float2 pos, SwiftUI::Layer layer,
                        float2 center, float radius, float thickness,
                        float off, float chroma, float time) {
    float2 v = pos - center;
    float dist = length(v);
    // 1 on the stroke rim, 0 in the flat interior / well outside → early-out keeps
    // almost every pixel at a single tap. W-B187 — the band half-width is HALF the
    // stroke (`thickness * 0.5`), not the full stroke, so the chromatic fringe rides
    // ONLY the real white stroke band (radius ± stroke/2) instead of spilling a full
    // stroke proud of it on each side. The SwiftUI `RingFilledArcMask` clips the arc;
    // this keeps the colour off the flat interior / exterior at the source too.
    float band = smoothstep(thickness * 0.5, 0.0, abs(dist - radius));
    if (band <= 0.001) {
        return layer.sample(pos);
    }
    // Radial direction, slowly rotated for an ambient prism sweep.
    float2 dir = v / max(dist, 1e-3);
    float a = time * 0.5;
    float ca = cos(a);
    float sa = sin(a);
    dir = float2(dir.x * ca - dir.y * sa, dir.x * sa + dir.y * ca);
    float k = off * band;
    // Push R out, keep G centred, pull B in → the per-channel lens fringe.
    half4 cR = layer.sample(pos + dir * (k * (1.0 + chroma)));
    half4 cG = layer.sample(pos);
    half4 cB = layer.sample(pos - dir * (k * (1.0 - chroma)));
    return half4(cR.r, cG.g, cB.b, cG.a);
}
