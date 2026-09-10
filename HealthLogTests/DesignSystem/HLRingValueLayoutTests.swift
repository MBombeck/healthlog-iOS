// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import CoreGraphics
    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **Public issue #6 (TestFlight build 275).** A tester on an 11-dose
    /// regimen photographed the Home compliance ring rendering "11/11" as
    /// "11/1" + "1", the second line dropping onto the "today" caption.
    ///
    /// `HLRing`'s centre value had no `lineLimit` and no `minimumScaleFactor`.
    /// Once the string outgrew the width the ring's inner area offers, an
    /// unconstrained `Text` answers by *breaking the line* — here at the "/" —
    /// and the two-line stack overflows the 92 pt ring onto the caption.
    ///
    /// **Fix round 1 — the accessibility sizes.** The value font is
    /// `side × fontRatio` with `fontRatio` a `@ScaledMetric(relativeTo: .title)`,
    /// so at accessibility type sizes the number nearly doubles while the ring
    /// stays 92 pt. Forbidding the wrap without giving the value room to shrink
    /// only trades one unreadable render for another: "11/…" says as little
    /// about an eleven-dose day as "11/1" over "1" did. These cases drive the
    /// size through SwiftUI (`.dynamicTypeSize`), which is what `@ScaledMetric`
    /// reads — a UIKit `traitOverrides.preferredContentSizeCategory` moves
    /// `.hlCaption` but leaves `fontRatio` at its default, so it cannot reach
    /// this defect at all.
    ///
    /// **Why a hosted window and not `ImageRenderer`.** The first cut of this
    /// suite measured `ImageRenderer` output and stayed green against the
    /// broken ring: the one-shot renderer resolves the overflow by *truncating*,
    /// never by the wrap the tester photographed. Only the real UIKit layout
    /// pass — a `UIHostingController` in a key window — reproduces the device
    /// behaviour, so the suite follows `SyncProgressRenderTests`' window-render
    /// pattern and hosts the ring in the dashboard row geometry it actually
    /// ships in (92 pt ring, `HLSpace.lg` gutter, phone width).
    ///
    /// Following the project's pixel-snapshot-avoidance doctrine (see
    /// `HLSkeletonSnapshotTests`, `HLSettingsToggleRowLayoutTests`) nothing here
    /// pins rasteriser pixels. Each render is reduced to three structural
    /// facts — how many **text lines** the centre stack drew, how many
    /// **full-height glyphs** the value line carries, and the ink's height —
    /// and the assertions compare those against the string that was asked for.
    /// The track is `HLText.primary @ 10 %` and stays far lighter than any
    /// glyph, so a plain darkness threshold isolates the centre text.
    ///
    /// Set `HLRING_RENDER_DIR=/tmp/hlring` to export the rendered PNGs for
    /// visual review (used by the W10 report).
    @MainActor
    @Suite("HLRing — the centre value stays on one line (public issue #6)", .serialized)
    struct HLRingValueLayoutTests {
        /// Both production callsites (`ComplianceRingCard`, `HealthScoreLoaded`)
        /// render at 92 pt — the size in the tester's screenshot.
        private static let ringSide: CGFloat = 92
        /// Phone-width canvas, tall enough that a wrapped second line overflows
        /// into it rather than being clipped by the window edge.
        private static let canvas = CGSize(width: 393, height: 220)

        /// Anything darker than this on the white backdrop counts as text ink.
        /// The track is `HLText.primary @ 10 %`; at full coverage it cannot get
        /// below ≈ 230, so it is never mistaken for a glyph.
        private nonisolated static let inkThreshold = 170

        /// A column run counts as a glyph when it reaches this share of its
        /// line's height. Digits and the "/" clear it comfortably; the three
        /// baseline dots of a truncating ellipsis do not come close.
        private nonisolated static let glyphHeightShare = 0.55

        /// What one rendered ring tells us about its centre text.
        private struct InkGeometry {
            /// One entry per contiguous band of inked rows — i.e. per drawn
            /// text line. A wrapped value shows up here directly: value plus
            /// caption is two bands, a wrapped value plus caption is three.
            let lines: Int
            /// Full-height glyph clusters on the FIRST line — the value.
            /// "11/11" draws five, a truncated "11/…" draws three.
            let valueGlyphs: Int
            /// Full-height glyph clusters on the LAST line — the caption, when
            /// there is one. "today" draws five; a truncated "tod…" draws three
            /// plus dots that never reach glyph height.
            let captionGlyphs: Int
            /// Height of the whole ink bounding box, in pixels.
            let height: Int
        }

        // MARK: - Rendering

        /// Hosts the ring in the dashboard row geometry, lets UIKit lay it out,
        /// and reduces the ink its centre text leaves to structural facts.
        @discardableResult
        private func measure(
            value: String,
            label: String?,
            typeSize: DynamicTypeSize = .large,
            dump: String? = nil
        ) throws -> InkGeometry {
            // The `ComplianceRingCard` / `HealthScoreLoaded` row: the ring on
            // the leading edge, the copy column taking the rest.
            let row = HStack(alignment: .center, spacing: HLSpace.lg) {
                HLRing(progress: 0, label: label, value: value, tint: .clear)
                    .frame(width: Self.ringSide, height: Self.ringSide)
                Spacer(minLength: 0)
            }
            .padding(HLSpace.lg)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            // `@ScaledMetric` reads this; the UIKit trait override does not
            // reach it. Fix round 1.
            .dynamicTypeSize(typeSize)

            let bounds = CGRect(origin: .zero, size: Self.canvas)
            let host = UIHostingController(rootView: row)
            host.overrideUserInterfaceStyle = .light
            let window = UIWindow(frame: bounds)
            window.overrideUserInterfaceStyle = .light
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
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

            if let dump { Self.writePNG(image, named: dump) }

            let cgImage = try #require(image.cgImage, "rendered ring has no cgImage")
            let geometry = try Self.inkGeometry(of: cgImage)
            print(
                "HLRingValueLayoutTests: value=\(value) label=\(label ?? "-") "
                    + "size=\(typeSize) lines=\(geometry.lines) "
                    + "valueGlyphs=\(geometry.valueGlyphs) captionGlyphs=\(geometry.captionGlyphs) "
                    + "inkHeight=\(geometry.height)"
            )
            return geometry
        }

        /// The rendered canvas as a darkness mask, with the two reductions
        /// the assertions need: where the text lines are, and how many
        /// full-height glyphs the first of them carries.
        private struct InkMask {
            let width: Int
            let height: Int
            private let pixels: [UInt8]

            init(_ cgImage: CGImage) throws {
                width = cgImage.width
                height = cgImage.height
                var buffer = [UInt8](repeating: 0, count: width * height * 4)
                let context = try #require(CGContext(
                    data: &buffer,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                pixels = buffer
            }

            func isInk(row: Int, column: Int) -> Bool {
                let index = (row * width + column) * 4
                return Int(pixels[index]) < inkThreshold
                    && Int(pixels[index + 1]) < inkThreshold
                    && Int(pixels[index + 2]) < inkThreshold
            }

            /// The vertical extent of the ink in one column, within `band`.
            func inkExtent(column: Int, in band: ClosedRange<Int>) -> ClosedRange<Int>? {
                var top: Int?
                var bottom: Int?
                for row in band where isInk(row: row, column: column) {
                    if top == nil { top = row }
                    bottom = row
                }
                guard let top, let bottom else { return nil }
                return top ... bottom
            }

            /// One entry per contiguous band of inked rows — i.e. per drawn
            /// text line. A blank row separates them: digits carry no descender
            /// into the caption's ascent, and a wrapped value leaves its
            /// inter-line leading empty.
            func rowBands() -> [ClosedRange<Int>] {
                var bands: [ClosedRange<Int>] = []
                var open: (top: Int, bottom: Int)?
                for row in 0 ..< height {
                    let inked = (0 ..< width).contains { isInk(row: row, column: $0) }
                    if inked {
                        open = (top: open?.top ?? row, bottom: row)
                    } else if let band = open {
                        bands.append(band.top ... band.bottom)
                        open = nil
                    }
                }
                if let band = open { bands.append(band.top ... band.bottom) }
                return bands
            }

            /// Column runs within `band` that reach `glyphHeightShare` of its
            /// height — which separates a digit from an ellipsis dot.
            func glyphRuns(in band: ClosedRange<Int>) -> Int {
                let floor = Int(Double(band.count) * glyphHeightShare)
                var glyphs = 0
                var run: (top: Int, bottom: Int)?
                for column in 0 ..< width {
                    if let extent = inkExtent(column: column, in: band) {
                        run = (
                            top: min(run?.top ?? extent.lowerBound, extent.lowerBound),
                            bottom: max(run?.bottom ?? extent.upperBound, extent.upperBound)
                        )
                    } else if let closed = run {
                        if closed.bottom - closed.top + 1 >= floor { glyphs += 1 }
                        run = nil
                    }
                }
                if let closed = run, closed.bottom - closed.top + 1 >= floor { glyphs += 1 }
                return glyphs
            }
        }

        /// Reduces the rendered canvas to the three structural facts asserted on.
        private static func inkGeometry(of cgImage: CGImage) throws -> InkGeometry {
            let mask = try InkMask(cgImage)
            let bands = mask.rowBands()
            guard let first = bands.first, let last = bands.last else {
                return InkGeometry(lines: 0, valueGlyphs: 0, captionGlyphs: 0, height: 0)
            }
            return InkGeometry(
                lines: bands.count,
                valueGlyphs: mask.glyphRuns(in: first),
                captionGlyphs: bands.count >= 2 ? mask.glyphRuns(in: last) : 0,
                height: last.upperBound - first.lowerBound + 1
            )
        }

        /// Best-effort PNG export for human review — never fails the test.
        private static func writePNG(_ image: UIImage, named name: String) {
            let directory = ProcessInfo.processInfo.environment["HLRING_RENDER_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("hlring-issue6").path
            guard let data = image.pngData() else { return }
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            guard (try? data.write(to: url)) != nil else { return }
            print("HLRingValueLayoutTests: wrote \(url.path)")
        }

        // MARK: - The wrap contract (the original report)

        @Test("an 11-dose regimen never wraps — 11/11 keeps 4/6's line count")
        func longValueNeverWraps() throws {
            let short = try measure(value: "4/6", label: nil, dump: "value-4-6")
            let long = try measure(value: "11/11", label: nil, dump: "value-11-11")
            #expect(short.lines == 1)
            #expect(
                long.lines == 1,
                "11/11 drew \(long.lines) text lines against 4/6's \(short.lines) — it wrapped."
            )
            // One line of digits versus two is close to a factor of two; the
            // slack absorbs hinting and the sub-pixel shift `minimumScaleFactor`
            // introduces once the value starts shrinking.
            #expect(
                long.height <= short.height + 4,
                "11/11 renders \(long.height) px tall against 4/6's \(short.height) px — it wrapped."
            )
        }

        @Test("the 11/11 value never lands on the 'today' caption line")
        func valueDoesNotCollideWithCaption() throws {
            // The tester's exact surface: the value with the caption beneath.
            // Two bands and no more — value, caption. A wrapped value makes three.
            let short = try measure(value: "4/6", label: "today", dump: "card-4-6")
            let long = try measure(value: "11/11", label: "today", dump: "card-11-11")
            #expect(short.lines == 2)
            #expect(
                long.lines == 2,
                "the 11/11 ring drew \(long.lines) text lines — the value stacked onto the caption."
            )
            #expect(
                long.height <= short.height + 4,
                "the 11/11 centre block is \(long.height) px tall against 4/6's \(short.height) px."
            )
        }

        // MARK: - The legibility contract (fix round 1)

        /// The value must survive intact at every type size the ring can meet.
        /// An ellipsis in a count is exactly as unreadable as the wrap was: the
        /// user of an eleven-dose regimen cannot tell 11/11 from 11/10.
        @Test(
            "11/11 keeps all five glyphs on one line at accessibility sizes",
            arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5]
        )
        func complianceValueSurvivesAccessibilitySizes(typeSize: DynamicTypeSize) throws {
            let geometry = try measure(
                value: "11/11",
                label: "today",
                typeSize: typeSize,
                dump: "card-11-11-\(typeSize)"
            )
            #expect(
                geometry.lines == 2,
                "the ring drew \(geometry.lines) text lines at \(typeSize) — value and caption is two."
            )
            #expect(
                geometry.valueGlyphs == 5,
                "the value line carries \(geometry.valueGlyphs) full-height glyphs at \(typeSize), not the five of \"11/11\" — it was truncated."
            )
            // The caption is under the same rule: "today" shrinks, it never
            // becomes "tod…". Five glyphs, at every size.
            #expect(
                geometry.captionGlyphs == 5,
                "the caption carries \(geometry.captionGlyphs) full-height glyphs at \(typeSize), not the five of \"today\" — it was truncated."
            )
        }

        @Test(
            "100 keeps all three glyphs on one line at accessibility sizes",
            arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5]
        )
        func scoreValueSurvivesAccessibilitySizes(typeSize: DynamicTypeSize) throws {
            // `HealthScoreLoaded` shares the primitive at the same 92 pt.
            let geometry = try measure(
                value: "100",
                label: "of 100",
                typeSize: typeSize,
                dump: "score-100-\(typeSize)"
            )
            #expect(
                geometry.lines == 2,
                "the score ring drew \(geometry.lines) text lines at \(typeSize) — value and caption is two."
            )
            #expect(
                geometry.valueGlyphs == 3,
                "the value line carries \(geometry.valueGlyphs) full-height glyphs at \(typeSize), not the three of \"100\" — it was truncated."
            )
            #expect(
                geometry.captionGlyphs == 5,
                "the caption carries \(geometry.captionGlyphs) full-height glyphs at \(typeSize), not the five of \"of 100\" — it was truncated."
            )
        }

        @Test("the common 4/6 case is untouched at accessibility sizes")
        func shortValueUnaffected() throws {
            // The regression guard for the fix itself: whatever keeps "11/11"
            // legible must not shrink the everyday value that always fitted.
            for typeSize in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                let geometry = try measure(
                    value: "4/6",
                    label: "today",
                    typeSize: typeSize,
                    dump: "card-4-6-\(typeSize)"
                )
                #expect(geometry.lines == 2, "4/6 drew \(geometry.lines) lines at \(typeSize).")
                #expect(
                    geometry.valueGlyphs == 3,
                    "4/6 shows \(geometry.valueGlyphs) glyphs at \(typeSize), not three."
                )
            }
        }
    }

#endif
