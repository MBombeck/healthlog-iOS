import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W-B187 a11y — pins the differentiate-without-color SHAPE channel on the
/// `HLScoreRing` signal cap dot. When `differentiateWithoutColor` is ON the dot
/// gains a shape distinction (`.ok` filled disc / `.warn` hollow ring / `.bad`
/// ringed dot) so colour-blind sighted users can tell the status apart without
/// relying on hue. When OFF the dot stays the canonical solid filled disc — the
/// default appearance must NOT change.
///
/// The pure `HLScoreRing.draw` is rendered via `ImageRenderer` into a `Canvas`
/// with the fill arc + track + ticks made transparent, so the only painted ink
/// is the cap dot — counted as opaque non-white pixels.
@MainActor
@Suite("HLScoreRing — differentiate-without-color glyph channel")
struct HLScoreRingDifferentiateTests {
    /// Renders ONLY the signal cap dot (fill/track/ticks transparent) and returns
    /// the count of opaque, non-white pixels — a proxy for the dot's drawn area.
    private func dotPixelCount(signal: HLScoreRing.HLSignal, differentiate: Bool) throws -> Int {
        let view = Canvas { ctx, size in
            HLScoreRing.draw(
                in: ctx,
                size: size,
                stroke: 12,
                fraction: 0.5,
                arcDegrees: 360,
                ticks: [],
                segments: nil,
                signal: signal,
                trackColor: .clear,
                fillColor: .clear,
                differentiateWithoutColor: differentiate
            )
        }
        .frame(width: 120, height: 120)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
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

        // Count opaque pixels that are NOT pure white → the coloured cap dot ink.
        var painted = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200
            && !(pixels[index] > 240 && pixels[index + 1] > 240 && pixels[index + 2] > 240)
        {
            painted += 1
        }
        return painted
    }

    @Test("OFF — every signal paints a solid filled dot (default appearance)")
    func defaultAppearanceUnchanged() throws {
        let ok = try dotPixelCount(signal: .ok, differentiate: false)
        let warn = try dotPixelCount(signal: .warn, differentiate: false)
        let bad = try dotPixelCount(signal: .bad, differentiate: false)
        // All three are the SAME solid disc when differentiate is OFF — they paint
        // a comparable filled area (only the hue differs, which we don't measure).
        #expect(ok > 0)
        #expect(warn > 0)
        #expect(bad > 0)
        #expect(abs(ok - warn) < ok / 2)
        #expect(abs(ok - bad) < ok / 2)
    }

    @Test("ON .ok — filled disc unchanged from the default")
    func okUnchangedWhenOn() throws {
        let off = try dotPixelCount(signal: .ok, differentiate: false)
        let on = try dotPixelCount(signal: .ok, differentiate: true)
        // .ok stays a solid filled disc in both states — the shape channel is a
        // no-op for the "in range" status.
        #expect(on > 0)
        #expect(abs(on - off) < max(4, off / 8))
    }

    @Test("ON .warn — hollow ring paints LESS than the solid disc")
    func warnHollowWhenOn() throws {
        let off = try dotPixelCount(signal: .warn, differentiate: false)
        let on = try dotPixelCount(signal: .warn, differentiate: true)
        // A stroked outline with a transparent centre covers fewer pixels than the
        // solid disc — the shape difference is real, not colour-only.
        #expect(on > 0)
        #expect(on < off)
    }

    @Test("ON .bad — ringed dot paints MORE than the solid disc")
    func badRingedWhenOn() throws {
        let off = try dotPixelCount(signal: .bad, differentiate: false)
        let on = try dotPixelCount(signal: .bad, differentiate: true)
        // The filled disc plus a concentric outer ring covers more pixels than the
        // bare disc — a distinct, monochrome-safe shape.
        #expect(on > off)
    }

    @Test("the three ON shapes are mutually distinguishable by area")
    func threeShapesDistinct() throws {
        let ok = try dotPixelCount(signal: .ok, differentiate: true)
        let warn = try dotPixelCount(signal: .warn, differentiate: true)
        let bad = try dotPixelCount(signal: .bad, differentiate: true)
        // warn (hollow) < ok (filled) < bad (ringed) — three separable footprints.
        #expect(warn < ok)
        #expect(ok < bad)
    }
}
