import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W-B187 a11y — pins the reduce-transparency SOLID fallback in
/// `HLMaterialBackground`, the single source of truth used by the consent sheets
/// (`AIConsentSheet` / `BYOConsentSheet`) and the offline `ReachabilityBanner`.
///
/// With `accessibilityReduceTransparency` ON the helper must paint an OPAQUE
/// solid colour (so legally/safety-relevant text stays legible). With it OFF it
/// paints the translucent material — the default appearance is preserved.
///
/// The env-driven branch is rendered via the env-independent
/// `HLMaterialBackground.resolved(reduceTransparency:…)` builder (the
/// `accessibilityReduceTransparency` key is read-only and cannot be written via
/// `.environment(_:_:)`). A distinctive solid fallback colour (`.red`) is
/// injected so it can be detected unambiguously in the rendered bitmap.
@MainActor
@Suite("HLMaterialBackground — reduce-transparency solid fallback")
struct HLMaterialBackgroundTests {
    /// Renders the resolved background over white and returns the count of
    /// strongly-red pixels — non-zero only when the opaque red solid is painted.
    private func solidPixelCount(reduceTransparency: Bool) throws -> Int {
        let view = HLMaterialBackground.resolved(
            reduceTransparency: reduceTransparency,
            material: .regularMaterial,
            solidColor: .red
        )
        .frame(width: 80, height: 80)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "background failed to render")
        let cg = try #require(image.cgImage, "no cgImage")

        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 180
            && pixels[index + 1] < 90 && pixels[index + 2] < 90 && pixels[index + 3] > 200
        {
            red += 1
        }
        return red
    }

    @Test("ON — paints the opaque solid fallback (legible under reduce-transparency)")
    func solidFallbackWhenReduceTransparency() throws {
        let red = try solidPixelCount(reduceTransparency: true)
        // The full 80×80 frame is filled with the red solid → a large red area.
        #expect(red > 2000)
    }

    @Test("OFF — paints the translucent material, not the solid colour")
    func materialWhenTransparencyAllowed() throws {
        let red = try solidPixelCount(reduceTransparency: false)
        // The material over white never resolves to the strongly-red solid tone.
        #expect(red == 0)
    }

    // MARK: - The same policy, now ahead of Liquid Glass availability

    /// The preference is the only input left, and it must win: on, the
    /// surface is opaque; off, it is glass.
    @Test("Reduce Transparency resolves to the opaque surface, otherwise glass")
    func preferenceDecidesTheSurface() {
        #expect(HLSurfaceOpacity.resolve(reduceTransparency: true) == .opaque)
        #expect(HLSurfaceOpacity.resolve(reduceTransparency: false) == .glass)
        #expect(HLSurfaceOpacity.Resolution.allCases.count == 2, "restate this contract if the vocabulary grows")
    }

    /// The glass helper's own painting seam, driven exactly like
    /// `HLMaterialBackground.resolved` — the preference paints the opaque
    /// fallback.
    @Test("the glass surface paints its opaque fallback under Reduce Transparency")
    func glassSurfacePaintsFallbackUnderReduceTransparency() throws {
        let painted = try glassPixelCount(reduceTransparency: true)
        #expect(painted > 2000)
    }

    /// Renders the glass seam over white and counts strongly-red pixels — the
    /// injected fallback colour, which only appears when the solid fill painted.
    private func glassPixelCount(reduceTransparency: Bool) throws -> Int {
        let view = HLGlassEffect.apply(
            Color.clear.frame(width: 80, height: 80),
            in: Rectangle(),
            variant: .regular,
            fallback: .red,
            reduceTransparency: reduceTransparency
        )
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "glass surface failed to render")
        let cg = try #require(image.cgImage, "no cgImage")

        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try #require(CGContext(
            data: &pixels,
            width: cg.width,
            height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        var red = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 180
            && pixels[index + 1] < 90 && pixels[index + 2] < 90 && pixels[index + 3] > 200
        {
            red += 1
        }
        return red
    }
}
