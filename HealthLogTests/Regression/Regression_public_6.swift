#if !SWIFT_PACKAGE
    import CoreGraphics
    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **REG (1.5) — public #6 (mbreitkreuz): the compliance ring overflowed
    /// with a two-digit count.**
    ///
    /// The tester's case was 11/11; `HLRingValueLayoutTests` pins that one at
    /// every type size. The table asks for the next two: a full twelve-dose day
    /// (12/12) and a day with one dose more than planned (13/12, a ratio above
    /// one). Both keep value and caption on two lines with all five glyphs, and
    /// the ring draws 13/12 exactly like 12/12: full, never past the circle.
    ///
    /// Same method as `HLRingValueLayoutTests` (a hosted window, ink bands
    /// instead of pixel snapshots), reduced to what these cases read.
    @MainActor
    @Suite("REG public #6: the ring holds 12 of 12 and 13 of 12", .serialized)
    struct Regression_public_6 {
        private static let side: CGFloat = 92
        private static let canvas = CGSize(width: 393, height: 220)
        private nonisolated static let inkThreshold = 170

        private func render(progress: Double, value: String?, label: String?, tint: Color) throws -> CGImage {
            let row = HStack(alignment: .center, spacing: HLSpace.lg) {
                HLRing(progress: progress, label: label, value: value, tint: tint)
                    .frame(width: Self.side, height: Self.side)
                Spacer(minLength: 0)
            }
            .padding(HLSpace.lg)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light)

            let bounds = CGRect(origin: .zero, size: Self.canvas)
            let host = UIHostingController(rootView: row)
            host.overrideUserInterfaceStyle = .light
            let window = UIWindow(frame: bounds)
            window.overrideUserInterfaceStyle = .light
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 2
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            return try #require(image.cgImage)
        }

        private static func pixels(_ image: CGImage) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(
                data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }

        /// Text lines (bands of inked rows) and the full-height glyphs on the
        /// first one, as in `HLRingValueLayoutTests`.
        private static func lines(_ image: CGImage) throws -> (count: Int, valueGlyphs: Int) {
            let buffer = try pixels(image)
            let width = image.width, height = image.height
            func ink(_ row: Int, _ col: Int) -> Bool {
                let i = (row * width + col) * 4
                return Int(buffer[i]) < inkThreshold && Int(buffer[i + 1]) < inkThreshold && Int(buffer[i + 2]) < inkThreshold
            }
            var bands: [ClosedRange<Int>] = []
            var open: Int?
            for row in 0 ..< height {
                let inked = (0 ..< width).contains { ink(row, $0) }
                if inked, open == nil { open = row }
                if !inked, let top = open {
                    bands.append(top ... row - 1)
                    open = nil
                }
            }
            if let top = open { bands.append(top ... height - 1) }
            guard let first = bands.first else { return (0, 0) }
            let floor = Int(Double(first.count) * 0.55)
            var glyphs = 0
            var run: (top: Int, bottom: Int)?
            for col in 0 ... width {
                let extent: (Int, Int)? = col < width
                    ? first.filter { ink($0, col) }.reduce(nil) { acc, row in (acc?.0 ?? row, row) }
                    : nil
                if let extent {
                    run = (min(run?.top ?? extent.0, extent.0), max(run?.bottom ?? extent.1, extent.1))
                } else if let closed = run {
                    if closed.bottom - closed.top + 1 >= floor { glyphs += 1 }
                    run = nil
                }
            }
            return (bands.count, glyphs)
        }

        @Test("12/12 and 13/12 stay one value line over the caption, all five glyphs", arguments: [(12, 12), (13, 12)])
        func countFits(taken: Int, scheduled: Int) throws {
            let snapshot = ComplianceSnapshot(scheduledToday: scheduled, takenToday: taken)
            let value = "\(snapshot.takenToday)/\(snapshot.scheduledToday)"
            // The track is a 10 % tint and stays below the ink threshold; a
            // clear tint keeps the arc out of the text measurement entirely.
            let image = try render(progress: snapshot.ratio, value: value, label: "today", tint: .clear)
            let measured = try Self.lines(image)
            #expect(measured.count == 2, "\(value) drew \(measured.count) text lines; value and caption is two")
            #expect(measured.valueGlyphs == 5, "\(value) kept \(measured.valueGlyphs) of its five glyphs on the value line")
        }

        @Test("a day over plan draws the ring full, exactly like a complete day")
        func overPlanIsClamped() throws {
            let full = ComplianceSnapshot(scheduledToday: 12, takenToday: 12)
            let over = ComplianceSnapshot(scheduledToday: 12, takenToday: 13)
            #expect(over.ratio > 1)
            let fullImage = try render(progress: full.ratio, value: nil, label: nil, tint: .black)
            let overImage = try render(progress: over.ratio, value: nil, label: nil, tint: .black)
            #expect(try Self.pixels(fullImage) == Self.pixels(overImage), "13 of 12 drew a different ring than 12 of 12")
        }
    }
#endif
