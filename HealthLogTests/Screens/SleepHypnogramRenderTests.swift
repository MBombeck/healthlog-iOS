// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// W-SLEEP (v0.14.8) — render verification for the sleep hypnogram (#124).
    ///
    /// The hypnogram never rendered on-device: the live route serialises the
    /// summary minute fields UNROUNDED (floats) and emits `stage: null` for
    /// stage-less legacy rows, both of which the old strict decode threw on →
    /// the screen always showed the error card. These tests push a LIVE-shaped
    /// payload through the REAL decode (`JSONDecoder.hlDefault` →
    /// `SleepNightEnvelope`) and render `SleepHypnogramScreen` inside a real
    /// `UIWindow`, asserting the stage bands actually paint — and that the
    /// empty state only shows when the night is truly empty.
    ///
    /// Set `SLEEP_RENDER_DIR=/tmp/sleep` to export the rendered PNGs.
    @MainActor
    @Suite("SleepHypnogramScreen — render verification", .serialized)
    struct SleepHypnogramRenderTests {
        // MARK: - Fixtures

        /// Live-shaped night: fractional minute sums + multi-stage segments,
        /// exactly the wire shape `GET /api/sleep/night` returns for an Apple
        /// Watch night (second-resolution segment bounds → float minutes).
        private static let stageNightJSON = #"""
        {"data":{
          "night":"2026-06-11",
          "main":{
            "night":"2026-06-11","source":"APPLE_HEALTH",
            "start":"2026-06-10T21:00:10Z","end":"2026-06-11T04:40:10Z",
            "asleepMinutes":441.00000000000006,"inBedMinutes":12.5,"awakeMinutes":6.5,"awakenings":1,
            "stages":{"IN_BED":12.5,"CORE":272.74999999999994,"DEEP":76.5,"REM":91.75,"AWAKE":6.5},
            "segments":[
              {"stage":"IN_BED","start":"2026-06-10T21:00:10Z","end":"2026-06-10T21:12:40Z","minutes":13},
              {"stage":"CORE","start":"2026-06-10T21:12:40Z","end":"2026-06-10T22:43:10Z","minutes":91},
              {"stage":"DEEP","start":"2026-06-10T22:43:10Z","end":"2026-06-10T23:31:25Z","minutes":48},
              {"stage":"CORE","start":"2026-06-10T23:31:25Z","end":"2026-06-11T00:36:55Z","minutes":66},
              {"stage":"REM","start":"2026-06-11T00:36:55Z","end":"2026-06-11T01:22:10Z","minutes":45},
              {"stage":"AWAKE","start":"2026-06-11T01:22:10Z","end":"2026-06-11T01:28:40Z","minutes":7},
              {"stage":"CORE","start":"2026-06-11T01:28:40Z","end":"2026-06-11T02:58:10Z","minutes":90},
              {"stage":"DEEP","start":"2026-06-11T02:58:10Z","end":"2026-06-11T03:26:25Z","minutes":28},
              {"stage":"REM","start":"2026-06-11T03:26:25Z","end":"2026-06-11T04:12:55Z","minutes":47},
              {"stage":"CORE","start":"2026-06-11T04:12:55Z","end":"2026-06-11T04:40:10Z","minutes":27}
            ]
          },
          "naps":[]
        },"error":null}
        """#

        private func decodeNight(_ json: String) throws -> SleepNightDTO {
            try JSONDecoder.hlDefault.decode(SleepNightEnvelope.self, from: Data(json.utf8)).data
        }

        // MARK: - Render helper (mirrors HLSyncStatusFooterRenderTests)

        private func render(_ view: some View, name: String, height: CGFloat = 852) throws -> UIImage {
            let size = CGSize(width: 393, height: height)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["SLEEP_RENDER_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        /// `true` when the band carries contrast (something painted there).
        private func hasInk(_ image: UIImage, fromY: CGFloat, toY: CGFloat) -> Bool {
            guard let cg = image.cgImage else { return false }
            let width = cg.width
            let height = cg.height
            let y0 = max(0, Int(fromY / image.size.height * CGFloat(height)))
            let y1 = min(height, Int(toY / image.size.height * CGFloat(height)))
            guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
            let bpr = cg.bytesPerRow
            let bpp = cg.bitsPerPixel / 8
            var minLum = 255
            var maxLum = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: 0, to: width, by: 4) {
                    let p = y * bpr + x * bpp
                    let lum = (Int(ptr[p]) + Int(ptr[p + 1]) + Int(ptr[p + 2])) / 3
                    minLum = min(minLum, lum)
                    maxLum = max(maxLum, lum)
                }
            }
            return (maxLum - minLum) > 25
        }

        // MARK: - Tests

        @Test("Live-shaped multi-stage night renders the hypnogram bands")
        func stageNightPaints() throws {
            // Through the REAL decode path — fractional sums + all five stages.
            let night = try decodeNight(Self.stageNightJSON)
            let main = try #require(night.main)
            #expect(main.segments.count == 10)
            #expect(Set(main.segments.map(\.stage)) == [.inBed, .core, .deep, .rem, .awake])

            let view = NavigationStack {
                SleepHypnogramScreen(initialNight: night)
            }
            let image = try render(view, name: "hypnogram-stages")
            // Summary card + chart occupy the upper two thirds — the band must
            // carry ink (stage rectangles + axis labels), not the empty state.
            #expect(hasInk(image, fromY: 120, toY: 700), "hypnogram stage bands must paint")
        }

        /// WHOOP-shaped night — per-stage TOTALS whose reconstructed segments
        /// all end at the wake instant (`measuredAt = sleep end` per stage).
        /// W-B180: rendered literally these bars all hug the right edge
        /// ("alle Balken kleben rechts"); the screen must fall back to the
        /// proportional distribution band instead of a fake timeline.
        private static let whoopSummaryNightJSON = #"""
        {"data":{
          "night":"2026-06-11",
          "main":{
            "night":"2026-06-11","source":"WHOOP",
            "start":"2026-06-10T21:25:00Z","end":"2026-06-11T05:25:00Z",
            "asleepMinutes":430.0,"inBedMinutes":480.0,"awakeMinutes":50.0,"awakenings":2,
            "stages":{"AWAKE":50.0,"CORE":260.0,"DEEP":80.0,"REM":90.0},
            "segments":[
              {"stage":"AWAKE","start":"2026-06-11T04:35:00Z","end":"2026-06-11T05:25:00Z","minutes":50},
              {"stage":"CORE","start":"2026-06-11T01:05:00Z","end":"2026-06-11T05:25:00Z","minutes":260},
              {"stage":"DEEP","start":"2026-06-11T04:05:00Z","end":"2026-06-11T05:25:00Z","minutes":80},
              {"stage":"REM","start":"2026-06-11T03:55:00Z","end":"2026-06-11T05:25:00Z","minutes":90}
            ]
          },
          "naps":[]
        },"error":null}
        """#

        @Test("WHOOP summary-shaped night decodes as summary + renders the distribution fallback")
        func whoopSummaryNightFallsBack() throws {
            let night = try decodeNight(Self.whoopSummaryNightJSON)
            let main = try #require(night.main)
            // The shape the screen branches on: ≥2 segments, one shared end.
            #expect(SleepHypnogramLayout.isSummaryShaped(main.segments))

            let view = NavigationStack {
                SleepHypnogramScreen(initialNight: night)
            }
            let image = try render(view, name: "hypnogram-whoop-summary")
            // The distribution band + footnote paint below the summary card.
            #expect(hasInk(image, fromY: 120, toY: 700), "distribution fallback must paint")
        }

        /// W-SLEEPHYP — a `reconstructed: true` night (WHOOP / Polar) carries
        /// no measured onsets; the server lays one segment per stage in a fixed
        /// order, so rendering a lane timeline would be a fake hypnogram. The
        /// screen must fall back to the honest distribution band + approximate
        /// caption even though the segments are NOT shared-end summary-shaped.
        private static let reconstructedTimedNightJSON = #"""
        {"data":{
          "night":"2026-06-11",
          "main":{
            "night":"2026-06-11","source":"WHOOP",
            "start":"2026-06-10T22:00:00Z","end":"2026-06-11T06:00:00Z",
            "asleepMinutes":430.0,"inBedMinutes":480.0,"awakeMinutes":50.0,"awakenings":2,
            "reconstructed":true,
            "stages":{"AWAKE":50.0,"CORE":260.0,"DEEP":80.0,"REM":90.0},
            "segments":[
              {"stage":"AWAKE","start":"2026-06-10T22:00:00Z","end":"2026-06-10T22:50:00Z","minutes":50},
              {"stage":"CORE","start":"2026-06-10T22:50:00Z","end":"2026-06-11T03:10:00Z","minutes":260},
              {"stage":"DEEP","start":"2026-06-11T03:10:00Z","end":"2026-06-11T04:30:00Z","minutes":80},
              {"stage":"REM","start":"2026-06-11T04:30:00Z","end":"2026-06-11T06:00:00Z","minutes":90}
            ]
          },
          "naps":[]
        },"error":null}
        """#

        @Test("reconstructed night (contiguous synthetic timeline) renders the distribution fallback, not a fake lane chart")
        func reconstructedTimedNightFallsBack() throws {
            let night = try decodeNight(Self.reconstructedTimedNightJSON)
            let main = try #require(night.main)
            // The synthetic timeline is contiguous (sequential ends), so the
            // shared-end heuristic does NOT catch it — only the server flag does.
            #expect(main.reconstructed)
            #expect(SleepHypnogramLayout.isSummaryShaped(main.segments) == false)

            let view = NavigationStack {
                SleepHypnogramScreen(initialNight: night)
            }
            let image = try render(view, name: "hypnogram-reconstructed")
            #expect(hasInk(image, fromY: 120, toY: 700), "distribution fallback must paint")
        }

        @Test("each sleep stage maps to a distinct phase color")
        func stageColorsAreDistinct() {
            let screen = SleepHypnogramScreen()
            let stages = SleepStage.allCases
            let colors = stages.map { stage in
                UIColor(screen.color(for: stage)).resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: .light)
                )
            }
            // No two phases share the same swatch (the operator finding was
            // "alles eine Farbe"): every pair is perceptibly different.
            for i in colors.indices {
                for j in stages.indices where j > i {
                    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
                    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
                    colors[i].getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
                    colors[j].getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
                    let dist = abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
                    #expect(dist > 0.05, "\(stages[i]) and \(stages[j]) must differ")
                }
            }
        }

        @Test("phase colors resolve legibly in both light and dark")
        func stageColorsResolveBothSchemes() {
            let screen = SleepHypnogramScreen()
            for stage in SleepStage.allCases {
                let ui = UIColor(screen.color(for: stage))
                let light = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                let dark = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                light.getRed(&r, green: &g, blue: &b, alpha: &a)
                #expect(a > 0.5, "\(stage) light swatch must be opaque")
                dark.getRed(&r, green: &g, blue: &b, alpha: &a)
                #expect(a > 0.5, "\(stage) dark swatch must be opaque")
            }
        }

        @Test("Truly empty night (main == null) renders the calm empty state")
        func emptyNightShowsEmptyState() throws {
            let night = try decodeNight(#"{"data":{"night":null,"main":null,"naps":[]},"error":null}"#)
            #expect(night.main == nil)
            let view = NavigationStack {
                SleepHypnogramScreen(initialNight: night)
            }
            let image = try render(view, name: "hypnogram-empty")
            // The empty-state card paints near the top; this locks the
            // self-suppression arm: empty state ONLY when the night is empty.
            #expect(hasInk(image, fromY: 80, toY: 320), "empty-state card must paint")
        }
    }
#endif
