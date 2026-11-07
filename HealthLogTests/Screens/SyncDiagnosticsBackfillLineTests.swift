// App-Target-Symbole (`ServerFreshnessFacts`) are not in the SPM library; the
// SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **SYNC-TRIG (1.5, #138, server v1.43)** — "History last filled in"
    /// per type, from `metricFreshness[].lastBackfillAt`.
    ///
    /// Fixtures follow `AppleHealthMetricFreshnessEntry` and the
    /// `syncTrigger: "backfill"` rule in the server's OpenAPI at v1.47.0: a
    /// backfill moves `lastBackfillAt` only, never `lastReceivedAt`,
    /// `lastTrigger`, `lastBackgroundAt` or the account's `lastSyncedAt`.
    @Suite("SYNC-TRIG — Sync Diagnostics: last history catch-up per type")
    @MainActor
    struct SyncDiagnosticsBackfillLineTests {
        /// The read right after a history catch-up of steps at 07:40: the live
        /// stamps still say yesterday evening's background run.
        static let afterBackfill = Data("""
        {
          "entries": [],
          "lastSyncedAt": "2026-10-15T20:00:00Z",
          "lastSyncTrigger": "background",
          "metricFreshness": [
            {"type": "STEPS", "lastSeenAt": "2026-10-15T19:58:00Z", "stale": false,
             "lastReceivedAt": "2026-10-15T20:00:00Z", "lastTrigger": "background",
             "lastNewSampleAt": "2026-10-15T20:00:00Z", "lastBackgroundAt": "2026-10-15T20:00:00Z",
             "lastBackfillAt": "2026-10-16T07:40:00Z"},
            {"type": "PULSE", "lastSeenAt": "2026-10-16T07:50:00Z", "stale": false,
             "lastReceivedAt": "2026-10-16T07:59:30Z", "lastTrigger": "foreground",
             "lastNewSampleAt": "2026-10-16T07:59:30Z"}
          ]
        }
        """.utf8)

        static func date(_ text: String) -> Date? {
            ISO8601DateFormatter().date(from: text)
        }

        @Test("server with the field: the line is there, and the live stamps stay where the server left them")
        func lineWithField() throws {
            let config = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: Self.afterBackfill)
            #expect(config.lastSyncedAt == Self.date("2026-10-15T20:00:00Z"), "a catch-up does not move lastSyncedAt")
            let rows = try #require(config.metricFreshness)
            let steps = ServerFreshnessFacts(row: rows[0])
            let backfill = try #require(Self.date("2026-10-16T07:40:00Z"))

            #expect(steps.lastChecked == Self.date("2026-10-15T20:00:00Z"), "the last check is still the live one")
            #expect(steps.lastNewValue == Self.date("2026-10-15T20:00:00Z"))
            #expect(steps.backfillLabel == String(
                localized: "settings.hkdiag.freshness_backfill \(ServerFreshnessFacts.relative(backfill))"
            ))
            #expect(steps.detailLines.last == steps.backfillLabel, "the catch-up reads last, after the live facts")
            #expect(steps.detailLines.count == 3, "checked, new value, catch-up; the background run is the last check")
        }

        @Test("server without the field (before v1.43, or a type never caught up): no line")
        func noLineWithoutField() throws {
            let config = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: Self.afterBackfill)
            let pulse = try ServerFreshnessFacts(row: #require(config.metricFreshness)[1])
            #expect(pulse.backfillLabel == nil)
            #expect(pulse.detailLines == [pulse.checkedLabel, pulse.newValueLabel].compactMap { $0 })

            let older = try JSONDecoder.hlDefault.decode(MetricFreshness.self, from: Data(#"""
            {"type": "STEPS", "lastSeenAt": "2026-10-15T19:58:00Z", "stale": false}
            """#.utf8))
            #expect(ServerFreshnessFacts(row: older).backfillLabel == nil)
            #expect(ServerFreshnessFacts(row: older).detailLines.isEmpty)
        }

        @Test("a malformed stamp is absence, never a broken row")
        func malformedIsAbsence() throws {
            let broken = try JSONDecoder.hlDefault.decode(
                MetricFreshness.self,
                from: Data(#"{"type": "STEPS", "lastBackfillAt": "yesterday"}"#.utf8)
            )
            #expect(ServerFreshnessFacts(row: broken).backfillLabel == nil)
        }

        @Test("the text exists in German and English and says history, not a technical word")
        func catalogText() {
            let key = "settings.hkdiag.freshness_backfill %@"
            for (language, expected) in [("de", "Verlauf zuletzt nachgetragen %@"), ("en", "History last filled in %@")] {
                let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
                let text = bundle?.localizedString(forKey: key, value: nil, table: nil)
                #expect(text == expected, "\(language)")
            }
        }

        // MARK: - Pictures (Regel 9)

        /// Steps the way the server reports them after a catch-up at 07:40,
        /// relative to now so the captions read like on a device.
        static func stepsRow(withBackfill: Bool) -> MetricFreshness {
            let now = Date()
            return MetricFreshness(
                type: "ACTIVITY_STEPS",
                lastSeenAt: now.addingTimeInterval(-12 * 3600),
                lastReceivedAt: now.addingTimeInterval(-11 * 3600),
                lastTrigger: "background",
                lastNewSampleAt: now.addingTimeInterval(-11 * 3600),
                lastBackgroundAt: now.addingTimeInterval(-11 * 3600),
                lastBackfillAt: withBackfill ? now.addingTimeInterval(-20 * 60) : nil
            )
        }

        static func card(_ row: MetricFreshness) -> some View {
            ServerFreshnessRow(row: row, seenText: ServerFreshnessFacts.relative(row.lastSeenAt ?? Date()))
                .padding(HLSpace.md)
                .frame(width: 393, alignment: .leading)
                .background(Color(uiColor: .systemBackground))
        }

        /// Renders `view` at its own height; writes `<name>-<lang>.png` into
        /// `$SYNCTRIG_RENDER_DIR` when set (never into the checkout).
        static func render(_ view: some View, name: String, dark: Bool, xxxl: Bool) throws -> UIImage {
            let styled = view
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, xxxl ? .accessibility5 : .large)
            let host = UIHostingController(rootView: AnyView(styled))
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            // The row alone, edge to edge: no status-bar inset pushing it down.
            host.safeAreaRegions = []
            let fitting = host.sizeThatFits(in: CGSize(width: 393, height: 2000))
            let size = CGSize(width: 393, height: max(1, ceil(fitting.height)))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            if let dir = ProcessInfo.processInfo.environment["SYNCTRIG_RENDER_DIR"] {
                let language = Bundle.main.preferredLocalizations.first ?? "base"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(language).png")
                try image.pngData()?.write(to: url)
            }
            return image
        }

        @Test("before and after: the row grows by exactly the catch-up line, light, dark and XXXL")
        func pictures() throws {
            for (dark, xxxl, suffix) in [(false, false, "light"), (true, false, "dark"), (false, true, "xxxl")] {
                let before = try Self.render(
                    Self.card(Self.stepsRow(withBackfill: false)),
                    name: "freshness-before-\(suffix)", dark: dark, xxxl: xxxl
                )
                let after = try Self.render(
                    Self.card(Self.stepsRow(withBackfill: true)),
                    name: "freshness-after-\(suffix)", dark: dark, xxxl: xxxl
                )
                #expect(after.size.height > before.size.height, "\(suffix): one more line")
            }
        }
    }
#endif
