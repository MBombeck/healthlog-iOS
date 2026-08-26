import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.14.x ring-0% regression — pins that the `HLScoreRing` fill arc is drawn on
/// the FIRST static paint, independent of the appear-sweep animation.
///
/// The bug: `animatedFraction` started at `0` and the fill depended ENTIRELY on a
/// `withAnimation` sweep in `.onAppear`, which does not run in a one-shot
/// `ImageRenderer` (nor reliably in the lazy Insights grid) — so the ring rendered
/// as an empty track regardless of value (b162/b163 fixed the wrong layer).
///
/// The fix seeds `animatedFraction` from the real `fraction` at init. These tests
/// render the ring with `ImageRenderer` (which never runs the appear-sweep) and
/// count the fill-colour pixels: a non-zero fraction MUST paint a substantial arc,
/// a larger fraction MUST paint a longer arc, and `fraction: 0` MUST paint none.
@MainActor
@Suite("HLScoreRing — fill arc renders on first paint (no animation)")
struct HLScoreRingRenderTests {
    /// Renders a ring with an opaque black fill on white and returns the count of
    /// near-black pixels — a proxy for the drawn fill-arc length.
    private func filledPixelCount(fraction: Double) throws -> Int {
        let view = HLScoreRing(fraction: fraction, fillColor: .black, trackColor: .clear)
            .frame(width: 100, height: 100)
            .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "ring failed to render")
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

        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] < 64
            && pixels[index + 1] < 64 && pixels[index + 2] < 64 && pixels[index + 3] > 200
        {
            dark += 1
        }
        return dark
    }

    @Test("a non-zero fraction paints a substantial fill arc on first paint")
    func nonZeroFractionDraws() throws {
        let filled = try filledPixelCount(fraction: 0.72)
        // The arc stroke alone is hundreds of px at 100×100 — the regression
        // rendered exactly 0. Anything well above 0 proves the arc draws.
        #expect(filled > 200)
    }

    @Test("a larger fraction paints a longer arc than a smaller one")
    func largerFractionDrawsMore() throws {
        let small = try filledPixelCount(fraction: 0.20)
        let large = try filledPixelCount(fraction: 0.90)
        #expect(small > 0)
        #expect(large > small)
    }

    @Test("fraction 0 paints no fill arc (the calm/insufficient gate)")
    func zeroFractionDrawsNothing() throws {
        // With a transparent track and a zero fill, no near-black pixels remain.
        #expect(try filledPixelCount(fraction: 0) == 0)
    }

    /// Counts near-pure-red pixels — a proxy for the centre value/label being
    /// drawn in the override colour. Red is distinct from the black fill arc and
    /// the white background, so it isolates the centre text ink.
    private func redPixelCount(centreValueColor: Color?, centreLabelColor: Color?) throws -> Int {
        let view = HLScoreRing(
            fraction: 0.72,
            value: "72",
            label: "Bereit",
            fillColor: .black,
            trackColor: .clear,
            centreValueColor: centreValueColor,
            centreLabelColor: centreLabelColor
        )
        .frame(width: 140, height: 140)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "ring failed to render")
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
            && pixels[index + 1] < 80 && pixels[index + 2] < 80 && pixels[index + 3] > 200
        {
            red += 1
        }
        return red
    }

    @Test("centre value/label colour override is applied to the centre text")
    func centreColourOverrideApplied() throws {
        // With the override the "72"/"Bereit" are painted in red → many red px;
        // without it (default HLText ink) there are effectively none.
        let withOverride = try redPixelCount(centreValueColor: .red, centreLabelColor: .red)
        let withoutOverride = try redPixelCount(centreValueColor: nil, centreLabelColor: nil)
        #expect(withOverride > 50)
        #expect(withoutOverride == 0)
    }
}
