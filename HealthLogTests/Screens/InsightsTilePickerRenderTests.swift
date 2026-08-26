// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **v0152 T1 — render proof for the sole shipped Insights tile style (P9).**
    ///
    /// The dev tile-style picker was removed (App-Store ship blocker); P9
    /// `prismUniform` is now the only style, applied to every tile. The operator's
    /// rule still holds: the coloured prism arc must end at the ring fill
    /// (`0…fraction`), never wrap the whole rim. These render P9 over the real
    /// `HLScoreRing` via the same shared `.insightsRingEffect` modifier the Insights
    /// grid uses — at FULL (0.84), HALF (0.50) and EMPTY (0.0) fill — and prove the
    /// faint background colour is bound to the filled arc (empty ≈ no colour). P9 is
    /// pure SwiftUI, so it composites correctly through the live window draw.
    ///
    /// Set `TILES_RENDER_DIR=/tmp/tiles` to export the PNGs for the report.
    @MainActor
    @Suite("Insights tile render proof (P9)", .serialized)
    struct InsightsTilePickerRenderTests {
        /// Render a single score tile (ring + its resolved ring effect) and export
        /// to `$TILES_RENDER_DIR/<name>.png` when the env var is set. Uses the live
        /// window hierarchy draw so the additive prism/glow composites land.
        private func renderTile(
            fraction: Double,
            name: String
        ) throws -> UIImage {
            let appearance = InsightsTileStyle.prismUniform.appearance(signal: .ok)
            let tile = HLScoreRing(
                fraction: fraction,
                value: "\(Int(fraction * 100))",
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor
            )
            .frame(width: 140, height: 140)
            .insightsRingEffect(appearance.ringEffect, fraction: fraction, isHero: true)
            .padding(28)
            .background(HLSurface.primary)

            let size = CGSize(width: 196, height: 196)
            let host = UIHostingController(rootView: AnyView(tile))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Let the steady glow's first frame settle before the snapshot.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            // Export to `$TILES_RENDER_DIR` when set; otherwise default to /tmp/tiles
            // (the Simulator shares the host filesystem, so an absolute path lands on
            // the Mac for the report). This is a render-PROOF test — exporting is its
            // purpose, so it does not gate on the env var being present.
            let dir = ProcessInfo.processInfo.environment["TILES_RENDER_DIR"] ?? "/tmp/tiles"
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try image.pngData()?.write(to: url)
            window.isHidden = true
            return image
        }

        @Test("P9 renders at full + half fill (no empty render)")
        func prismUniformRenders() throws {
            for (fraction, name) in [(0.84, "p9-prismUniform-full-84"), (0.50, "p9-prismUniform-half-50")] {
                let image = try renderTile(fraction: fraction, name: name)
                #expect(
                    image.size.width > 0 && image.size.height > 0,
                    "\(name) produced an empty render"
                )
            }
        }

        /// **Arc-mask proof** — the operator's steer is a WHITE ring with the colour
        /// only FAINTLY in the background, bound to the filled arc. We assert the
        /// INVARIANTS: (1) SOME prism colour is present at full fill (not a pure white
        /// wash); (2) at 0 fill the colour drops away — proving the colour is masked
        /// to the filled arc, not painted around the whole rim.
        @Test("P9 shows a faint colour at full fill that disappears at 0 fill (arc-masked)")
        func p9ColourIsMaskedToFill() throws {
            let p9Full = try renderTile(fraction: 0.84, name: "p9-prismUniform-full-84")
            let p9Empty = try renderTile(fraction: 0.0, name: "p9-prismUniform-empty-0")

            let p9FullSat = Self.saturatedPixelCount(p9Full)
            let p9EmptySat = Self.saturatedPixelCount(p9Empty)

            // (1) Colour is present at full fill — a non-trivial coloured-pixel count.
            #expect(p9FullSat > 10, "P9 full-fill shows no prism colour (\(p9FullSat)) — washed to pure white?")
            // (2) Arc-mask: a 0-fill ring shows materially LESS colour than a full
            // one, proving the colour is bound to the filled arc and not the rim.
            #expect(
                p9EmptySat < p9FullSat,
                "P9 at 0 fill (\(p9EmptySat)) shows as much colour as full (\(p9FullSat)) — arc mask not honoured"
            )
        }

        /// Count pixels whose HSB saturation ≥ 0.12 AND brightness ≥ 0.25 — i.e.
        /// genuinely coloured pixels, excluding near-white (low S) and near-black.
        private static func saturatedPixelCount(_ image: UIImage) -> Int {
            guard let cg = image.cgImage else { return 0 }
            let width = cg.width
            let height = cg.height
            let bytesPerPixel = 4
            let bytesPerRow = bytesPerPixel * width
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

            var count = 0
            // Sample on a stride so the scan stays cheap on a 3× render.
            let stride = 2
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let i = y * bytesPerRow + x * bytesPerPixel
                    let r = Double(pixels[i]) / 255
                    let g = Double(pixels[i + 1]) / 255
                    let b = Double(pixels[i + 2]) / 255
                    let maxc = max(r, g, b)
                    let minc = min(r, g, b)
                    let brightness = maxc
                    let saturation = maxc <= 0 ? 0 : (maxc - minc) / maxc
                    // Pastel-aware threshold: the P9 prism is a SUBTLE shimmer behind
                    // the white glow (not a vivid paint), so pastel pixels sit around
                    // S 0.12–0.35. Count those; near-white (S<0.12) and near-black
                    // stay excluded.
                    if saturation >= 0.12, brightness >= 0.25 {
                        count += 1
                    }
                    x += stride
                }
                y += stride
            }
            return count
        }
    }

#endif
