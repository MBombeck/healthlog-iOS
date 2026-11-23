import CoreGraphics
@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// The Coach composer's action row: send stands there only with text, and
/// the mic and send are drawn as circles of one size in one tap area, at
/// rest, while dictating and while the coach answers.
@MainActor
@Suite("Coach composer, action row contract")
struct CoachComposerContractTests {
    /// The circle both buttons draw, in points.
    private static let circle: CGFloat = 36
    private static let scale: CGFloat = 3

    // MARK: - Send

    @Test("send is absent without text and there with text")
    func sendOnlyWithText() {
        #expect(!CoachComposerRules.showsSend(draft: "", isResponding: false))
        #expect(!CoachComposerRules.showsSend(draft: "  \n ", isResponding: false))
        #expect(CoachComposerRules.showsSend(draft: "Wie habe ich geschlafen?", isResponding: false))
    }

    @Test("while the coach answers send stays in place but cannot be tapped")
    func sendWhileResponding() {
        #expect(CoachComposerRules.showsSend(draft: "", isResponding: true))
        #expect(!CoachComposerRules.canSend(draft: "", isResponding: true))
        #expect(!CoachComposerRules.canSend(draft: "Noch eine Frage", isResponding: true))
        #expect(CoachComposerRules.canSend(draft: "Noch eine Frage", isResponding: false))
    }

    // MARK: - Circles

    @Test("mic at rest, mic while dictating and send draw the same circle", arguments: [
        ColorScheme.light, .dark
    ])
    func sameCircle(scheme: ColorScheme) throws {
        let micAtRest = try drawnBox(CoachComposerRules.micStyle(isActive: false), "mic.fill", scheme, enabled: true)
        let micActive = try drawnBox(CoachComposerRules.micStyle(isActive: true), "waveform", scheme, enabled: true)
        let send = try drawnBox(CoachComposerRules.sendStyle, "arrow.up", scheme, enabled: true)
        let sendDimmed = try drawnBox(CoachComposerRules.sendStyle, "arrow.up", scheme, enabled: false)
        let micDimmed = try drawnBox(CoachComposerRules.micStyle(isActive: false), "mic.fill", scheme, enabled: false)
        let expected = Self.circle * Self.scale
        for box in [micAtRest, micActive, send, sendDimmed, micDimmed] {
            #expect(abs(box.width - expected) <= 2, "circle width \(box.width) px, want \(expected)")
            #expect(abs(box.height - expected) <= 2, "circle height \(box.height) px, want \(expected)")
            // Centred in the 44 pt tap area, so two buttons side by side
            // share one centre line.
            #expect(abs(box.midX - HLHitTarget.minimum * Self.scale / 2) <= 1.5)
            #expect(abs(box.midY - HLHitTarget.minimum * Self.scale / 2) <= 1.5)
        }
    }

    @Test("both buttons have the 44 pt tap area and a 36 pt circle")
    func metrics() {
        #expect(CoachComposerDisc.diameter == Self.circle)
        #expect(HLHitTarget.minimum - CoachComposerDisc.diameter == 2 * HLSpace.xs)
    }

    // MARK: - One row

    @Test("the circles meet the middle of the text line, at every text size", arguments: [
        UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge
    ])
    func circlesOnTheLine(size: UIContentSizeCategory) {
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: size)
        )
        let centre = CoachComposerMetrics.lineCentreAboveBaseline(ascender: font.ascender, descender: font.descender)
        // Halfway between the top of the glyph box and its bottom.
        #expect(abs((font.ascender - centre) - (centre - font.descender)) < 0.001)
        // Above the baseline, below the cap height's top.
        #expect(centre > 0 && centre < font.ascender)
    }

    @Test("the last line is the bottom one, also when the field scrolls past its limit")
    func lastLine() {
        let line = CoachComposerMetrics.Line(isEmpty: false, ascender: 16, descender: -4, lineHeight: 21)
        // Two lines, baseline of the second 5 pt above the bottom.
        #expect(line.lastLineCentre(height: 42, centre: 21, lastBaseline: 37) == CGFloat(31))
        // Scrolled: the reported baseline belongs to a line further up; the
        // bottom line's baseline is the descender above the bottom.
        #expect(line.lastLineCentre(height: 63, centre: 31.5, lastBaseline: 37) == CGFloat(53))
        // Empty: the prompt's one line sits on the middle.
        let empty = CoachComposerMetrics.Line(isEmpty: true, ascender: 16, descender: -4, lineHeight: 21)
        #expect(empty.lastLineCentre(height: 21, centre: 10.5, lastBaseline: 21) == CGFloat(10.5))
    }

    @Test("the circle stands as far from the top, the bottom and the trailing edge")
    func equalInset() {
        // The row pads the tap area by inset minus the tap margin on those
        // three sides.
        let tapMargin = (HLHitTarget.minimum - CoachComposerDisc.diameter) / 2
        #expect(CoachComposerMetrics.discInset == HLSpace.sm)
        #expect(CoachComposerMetrics.discInset - tapMargin == HLSpace.xs)
        // One line: 36 pt circle plus the inset above and below.
        #expect(CoachComposerDisc.diameter + 2 * CoachComposerMetrics.discInset == 52)
    }

    // MARK: - Helpers

    /// The box of the pixels a disc draws, at 3x, in pixels of its
    /// 44 × 44 pt image.
    private func drawnBox(
        _ style: CoachComposerDisc.Style,
        _ symbol: String,
        _ scheme: ColorScheme,
        enabled: Bool
    ) throws -> CGRect {
        let view = CoachComposerDisc(systemImage: symbol, style: style)
            .disabled(!enabled)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage)
        return try Self.opaqueBox(of: image)
    }

    private static func opaqueBox(of image: CGImage) throws -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        #expect(CGFloat(width) == HLHitTarget.minimum * scale, "tap area width")
        #expect(CGFloat(height) == HLHitTarget.minimum * scale, "tap area height")
        guard maxX >= minX else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
