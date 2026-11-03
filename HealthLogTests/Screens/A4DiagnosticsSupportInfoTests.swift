// App-target symbols (`SupportInfoReport`, `ServerFreshnessFacts`) are not in
// the SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **A4 (iOS 1.4) — sync diagnostics and support info.**
    ///
    /// `AppleHealthMetricFreshnessEntry.lastEnteredHereAt` (server v1.43.7,
    /// `docs/api/openapi.yaml` at `v1.43.10`): "show both as the server sends
    /// them and do not recompute `stale`". And the rest of #134 in
    /// "Support-Info kopieren": time zone, enabled modules, every AI capability
    /// with `available` / `reason`, `ai.usage.level`, and the Apple Health block.
    @Suite("A4: entered here, support info (#134, #146)")
    struct A4DiagnosticsSupportInfoTests {
        private static let now = Date(timeIntervalSince1970: 1_792_141_923) // 2026-10-16T09:12:03Z

        static let freshnessJSON = #"""
        {"type":"BLOOD_PRESSURE_SYS","lastSeenAt":"2026-10-16T09:10:00.000Z","stale":false,
         "lastReceivedAt":"2026-10-15T07:00:00.000Z","lastTrigger":"background",
         "lastNewSampleAt":"2026-10-15T07:00:00.000Z","lastBackgroundAt":"2026-10-15T07:00:00.000Z",
         "lastEnteredHereAt":"2026-10-16T09:10:00.000Z"}
        """#

        @Test("lastEnteredHereAt decodes and gets its own line; lastSeenAt and stale stay the server's")
        func enteredHere() throws {
            let row = try JSONDecoder.hlDefault.decode(MetricFreshness.self, from: Data(Self.freshnessJSON.utf8))
            let entered = try #require(row.lastEnteredHereAt)
            #expect(row.lastSeenAt == entered, "v1.43.9: lastSeenAt is the newer of the two, as sent")
            #expect(!row.stale)
            let facts = ServerFreshnessFacts(row: row)
            let expected = String(localized: "settings.hkdiag.freshness_entered_here \(ServerFreshnessFacts.relative(entered))")
            #expect(facts.enteredHereLabel == expected)
            #expect(facts.detailLines.last == expected)
            // A type the server does not write back carries no such line.
            let plain = MetricFreshness(type: "HEART_RATE", lastSeenAt: Self.now, stale: true)
            #expect(ServerFreshnessFacts(row: plain).enteredHereLabel == nil)
        }

        @Test("the copied Sync Diagnostics line leaves the entry time out, like lastSeenAt")
        func reportKeepsReadingTimesOut() throws {
            let row = try JSONDecoder.hlDefault.decode(MetricFreshness.self, from: Data(Self.freshnessJSON.utf8))
            #expect(!SyncDiagnosticsReport.typeLine(row).contains("09:10"))
        }

        // MARK: - Support info

        static let ai = AIAccountBlock(
            capabilities: [
                .coach: AICapabilityState(available: true, reason: nil, onDeviceAllowed: true),
                .briefing: AICapabilityState(available: false, reason: .operatorDisabled, onDeviceAllowed: false)
            ],
            usage: AIUsageState(level: .standard, options: [])
        )

        static func input(
            zone: String? = "Europe/Berlin",
            modules: [String: Bool]? = ["illness": true, "cycle": false, "labs": true],
            ai: AIAccountBlock? = ai,
            health: HKServerSyncHealthSummary? = nil,
            healthFailed: Bool = false
        ) -> SupportInfoReport.Input {
            SupportInfoReport.Input(
                generatedAt: now,
                build: AppBuildMetadata(marketingVersion: "1.4.0", build: "301"),
                osVersion: "27.0.0",
                deviceClass: "iPhone",
                appLanguage: "de",
                server: ServerVersionInfo(version: "1.43.10", buildSha: "421aacf"),
                lastKnownServerVersion: nil,
                failures: [],
                timeZone: zone,
                modules: modules,
                ai: ai,
                appleHealth: health,
                appleHealthLoadFailed: healthFailed
            )
        }

        @Test("time zone, modules on, every AI capability and the usage level")
        func accountLines() {
            let text = SupportInfoReport(Self.input()).text
            #expect(text.contains("\ntime zone: Europe/Berlin\n"))
            #expect(text.contains("\nmodules on: illness, labs\n"))
            #expect(text.contains("\nai usage level: standard\n"))
            #expect(text.contains("\nai coach: available\n"))
            #expect(text.contains("\nai briefing: unavailable (operator_disabled)\n"))
            #expect(text.contains("\nai documentAi: not reported\n"))
            #expect(SupportInfoReport.accountLines(Self.input()).count == 3 + AICapabilityKey.allCases.count)
        }

        @Test("before the first load, and on an older server, it says so")
        func notLoaded() {
            let text = SupportInfoReport(Self.input(zone: nil, modules: nil, ai: nil, healthFailed: true)).text
            #expect(text.contains("\ntime zone: unknown\n"))
            #expect(text.contains("\nmodules: not loaded\n"))
            #expect(text.contains("\nai: not reported\n"))
            #expect(text.contains("[server] GET /api/integrations/healthkit\nnot reachable\n"))
        }

        @Test("the Apple Health block is the Sync Diagnostics one, with since")
        func appleHealthBlock() throws {
            let row = try JSONDecoder.hlDefault.decode(MetricFreshness.self, from: Data(Self.freshnessJSON.utf8))
            let health = HKServerSyncHealthSummary(
                verdict: .fresh,
                since: Self.now,
                lastSyncTrigger: "background",
                lastBackgroundSyncAt: Self.now,
                freshness: [row]
            )
            let text = SupportInfoReport(Self.input(health: health)).text
            #expect(text.contains("legacy verdict: fresh since 2026-10-16T09:12:03Z\n"))
            #expect(text.contains("last background sync: 2026-10-16T09:12:03Z\n"))
            #expect(text.contains("  BLOOD_PRESSURE_SYS: checked 2026-10-15T07:00:00Z (background)"))
            #expect(!text.contains("09:10"), "no reading time")
        }

        @Test("nothing personal rides in on a server string; plain ASCII")
        func redaction() {
            let hostile = SupportInfoReport(Self.input(
                zone: "Zara/Quillfeather@example.org",
                modules: ["zara.quillfeather@example.org": true, "Zara Quillfeather": true, "mood": true],
                ai: nil
            )).text
            for leak in ["zara", "Zara", "Quillfeather", "@", "example"] {
                #expect(!hostile.contains(leak), "leaked \(leak)")
            }
            #expect(hostile.contains("\nmodules on: mood\n"))
            #expect(hostile.contains("\ntime zone: unknown\n"))
            let text = SupportInfoReport(Self.input()).text
            let isASCII = text.unicodeScalars.allSatisfy(\.isASCII)
            #expect(isASCII)
            for glyph in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}"] {
                #expect(!text.contains(glyph))
            }
        }
    }
#endif
