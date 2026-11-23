// App-Target-Symbole (`SyncDiagnosticsReport`, `KindRow`) are not in the SPM
// library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **"Bericht kopieren".**
    ///
    /// The report is what a tester pastes into a public issue, so the test
    /// that matters most is what it leaves out: the fixture carries a reading
    /// time (`lastSeenAt`), a server `health.diagnostics` blob with an e-mail
    /// address and a server address, and none of it may reach the text.
    @Suite("W5 — Sync Diagnostics report text")
    struct SyncDiagnosticsReportTests {
        private static let now = Date(timeIntervalSince1970: 1_792_137_600) // 2026-10-16T08:00:00Z

        private static func ago(_ hours: Double) -> Date {
            now.addingTimeInterval(-hours * 3600)
        }

        /// `GET /api/integrations/healthkit` as server v1.42.4 answers it.
        private static let serverJSON = """
        {
          "entries": [],
          "lastSyncedAt": "2026-10-16T07:59:00Z",
          "lastSyncTrigger": "foreground",
          "lastBackgroundSyncAt": "2026-10-16T03:00:00Z",
          "health": {"state": "ok", "reason": "data_arriving", "since": null, "action": null,
                     "unavailable": [], "lastSuccessAt": "2026-10-16T07:59:00Z", "lastDataAt": "2026-10-16T07:59:00Z",
                     "diagnostics": {"note": "owner alex@example.com at https://health.example.com"}},
          "metricFreshness": [
            {"type": "PULSE", "lastSeenAt": "2026-10-14T03:17:42Z", "stale": false,
             "lastReceivedAt": "2026-10-16T07:59:00Z", "lastTrigger": "foreground",
             "lastNewSampleAt": "2026-10-16T07:59:00Z", "lastBackgroundAt": "2026-10-16T03:00:00Z"},
            {"type": "MEDICATION_DOSE", "lastSeenAt": "2026-10-13T21:43:11Z", "stale": false,
             "lastReceivedAt": "2026-10-16T06:05:00Z", "lastTrigger": "background",
             "lastNewSampleAt": "2026-10-16T06:05:00Z", "lastBackgroundAt": "2026-10-16T06:05:00Z"},
            {"type": "WALKING_RUNNING_DISTANCE", "lastSeenAt": "2026-10-15T22:58:13Z", "stale": true,
             "lastReceivedAt": "2026-10-16T07:59:00Z", "lastTrigger": "foreground",
             "lastNewSampleAt": "2026-10-15T23:00:00Z", "lastBackgroundAt": null}
          ]
        }
        """

        private static func input() throws -> SyncDiagnosticsReport.Input {
            let config = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: Data(serverJSON.utf8))
            var pulse = HKSyncDiagnostics.KindStats(identifier: "HKQuantityTypeIdentifierHeartRate")
            pulse.samplesReadTotal = 32
            pulse.samplesUploadedTotal = 30
            pulse.lastAnchorAdvancedAt = ago(1)
            pulse.lastObservationAt = ago(0.5)
            var log = HealthKitStatsUploadLog()
            log.lastSweep = .init(at: ago(0.1), trigger: "background", count: 0)
            log.uploads["HKQuantityTypeIdentifierStepCount"] = .init(at: ago(3), trigger: "background", count: 2)
            return SyncDiagnosticsReport.Input(
                generatedAt: now,
                build: AppBuildMetadata(marketingVersion: "1.3.0", build: "300"),
                osVersion: "26.5.0",
                serverVersion: "1.42.4",
                server: HKServerSyncHealthSummary(config: config),
                serverLoadFailed: false,
                heldGroups: [
                    OutboxHeldGroup(reason: .serverRefused(status: 422), count: 3),
                    OutboxHeldGroup(reason: .moduleDisabled("medications"), count: 1),
                    OutboxHeldGroup(reason: .retryBudgetExhausted, count: 2)
                ],
                statsLog: log,
                history: [
                    HistoryKindRow(kind: .sleep, statuses: [
                        HealthSampleHistoryStatus(
                            typeIdentifier: "HKCategoryTypeIdentifierSleepAnalysis",
                            reachedBack: Date(timeIntervalSince1970: 1_704_110_400), // 2024-01-01T12:00Z
                            isComplete: false,
                            legacyPending: false,
                            liveCaughtUp: true
                        )
                    ])
                ],
                lastCollectionTriggerAt: ago(0.5),
                lastCollectionTriggerSource: "observer",
                kinds: [
                    KindRow(kind: .pulse, stats: pulse),
                    KindRow(kind: .weight, stats: HKSyncDiagnostics.KindStats(identifier: "HKQuantityTypeIdentifierBodyMass"))
                ]
            )
        }

        @Test("The report carries build, server version, server state, per-type arrivals and the last triggers")
        func carriesTheStory() throws {
            let text = try SyncDiagnosticsReport(Self.input()).text
            #expect(text.contains("app: 1.3.0 (300)"))
            #expect(text.contains("os: iOS 26.5.0"))
            #expect(text.contains("server version: 1.42.4"))
            #expect(text.contains("state: ok (data_arriving)"))
            #expect(text.contains("delivers on its own: confirmed"))
            #expect(text.contains("last background sync: 2026-10-16T03:00:00Z"))
            #expect(text.contains("last trigger: foreground"))
            #expect(text.contains(
                "PULSE: checked 2026-10-16T07:59:00Z (foreground), new value 2026-10-16T07:59:00Z, background 2026-10-16T03:00:00Z"
            ))
            #expect(text.contains("MEDICATION_DOSE: checked 2026-10-16T06:05:00Z (background)"))
            #expect(text.contains(
                "WALKING_RUNNING_DISTANCE: checked 2026-10-16T07:59:00Z (foreground), new value 2026-10-15T23:00:00Z, background never, stale"
            ))
            #expect(text.contains("last collection trigger: 2026-10-16T07:30:00Z (observer)"))
        }

        @Test("Held entries are listed by reason with their counts")
        func heldByReason() throws {
            let text = try SyncDiagnosticsReport(Self.input()).text
            #expect(text.contains("  server refused (422): 3"))
            #expect(text.contains("  module off (medications): 1"))
            #expect(text.contains("  retry budget exhausted: 2"))
        }

        @Test("Local facts are grouped under their source and say which time they are")
        func localSections() throws {
            let text = try SyncDiagnosticsReport(Self.input()).text
            let stored = try #require(text.range(of: "[this iPhone, kept across launches]"))
            let session = try #require(text.range(of: "[this iPhone, since launch]"))
            #expect(stored.lowerBound < session.lowerBound)
            #expect(text.contains("day totals last checked: 2026-10-16T07:54:00Z (background), 0 rows"))
            #expect(text.contains("  HKQuantityTypeIdentifierStepCount: new value sent 2026-10-16T05:00:00Z (background), 2 rows"))
            #expect(text.contains("  sleep: back to 2024-01-01"))
            #expect(text.contains(
                "  pulse: read 32, uploaded 30, skipped 0, parked 0, new value 2026-10-16T07:00:00Z, checked 2026-10-16T07:30:00Z"
            ))
            // A kind with no activity since launch is left out, not listed as zero.
            #expect(!text.contains("  weight:"))
        }

        @Test("No reading time, no address, no account: nothing personal reaches the text")
        func leavesOutPersonalData() throws {
            let text = try SyncDiagnosticsReport(Self.input()).text
            // `lastSeenAt` is when a reading (or a dose) was taken.
            for taken in ["2026-10-14T03:17:42Z", "03:17:42", "2026-10-13T21:43:11Z", "2026-10-15T22:58:13Z"] {
                #expect(!text.contains(taken), "\(taken)")
            }
            #expect(!text.contains("@"))
            #expect(!text.contains("http"))
            #expect(!text.contains("example.com"))
            #expect(!text.lowercased().contains("alex"))
        }

        @Test("An unreachable server says so instead of claiming no background sync")
        func unreachableServer() throws {
            var input = try Self.input()
            input.server = nil
            input.serverLoadFailed = true
            let text = SyncDiagnosticsReport(input).text
            #expect(text.contains("[server] GET /api/integrations/healthkit\nnot reachable"))
            #expect(!text.contains("last background sync"))
        }

        @Test("INT-Q: the report ends with the session's error ids in the support-info words")
        func carriesRecentErrorIDs() throws {
            var input = try Self.input()
            #expect(SyncDiagnosticsReport(input).text.hasSuffix("\n\nrecent errors: none\n"))
            let log = RecentFailureLog()
            log.record(RecentFailure(
                at: Self.now, method: "GET", route: "/api/integrations/healthkit", status: 500,
                errorCode: "internal_error", requestId: "3f9a2c1b-7d4e-4f10-9a2b-c3d4e5f60718", kind: .status
            ))
            log.record(RecentFailure(
                at: Self.now, method: "POST", route: "/api/measurements/batch", status: 502,
                errorCode: nil, requestId: nil, kind: .status
            ))
            input.recentFailures = log.snapshot()
            let text = SyncDiagnosticsReport(input).text
            let session = try #require(text.range(of: "[this iPhone, since launch]"))
            let errors = try #require(text.range(of: "recent errors:\n"))
            #expect(session.lowerBound < errors.lowerBound)
            #expect(text.hasSuffix(RecentFailureLines.lines(log.snapshot()).joined(separator: "\n") + "\n"))
            #expect(text.contains("  2026-10-16T08:00:00Z POST /api/measurements/batch 502 no id"))
            #expect(text.contains(
                "  2026-10-16T08:00:00Z GET /api/integrations/healthkit 500 internal_error id 3f9a2c1b-7d4e-4f10-9a2b-c3d4e5f60718"
            ))
        }

        @Test("INT-Q: v1.43's lastBackfillAt decodes and the hourly backfill shows its progress")
        func carriesBackfill() throws {
            let row = try JSONDecoder.hlDefault.decode(MetricFreshness.self, from: Data(#"""
            {"type": "STEPS", "lastSeenAt": null, "stale": false, "lastReceivedAt": "2026-10-16T07:59:00Z",
             "lastTrigger": "foreground", "lastBackfillAt": "2026-10-16T07:40:00Z"}
            """#.utf8))
            #expect(row.lastBackfillAt == Date(timeIntervalSince1970: 1_792_136_400))
            #expect(SyncDiagnosticsReport.typeLine(row).hasSuffix(", backfill 2026-10-16T07:40:00Z"))
            let broken = try JSONDecoder.hlDefault.decode(
                MetricFreshness.self,
                from: Data(#"{"type": "STEPS", "lastBackfillAt": "soon"}"#.utf8)
            )
            #expect(broken.lastBackfillAt == nil, "a malformed stamp is absence")
            #expect(!SyncDiagnosticsReport.typeLine(broken).contains("backfill"))

            var input = try Self.input()
            #expect(!SyncDiagnosticsReport(input).text.contains("hourly backfill"))
            input.hourly = HourlyStatsStatus(
                backfillDaysTotal: 28, backfillDaysCompleted: 7, lastLiveUploadAt: nil,
                lastBackfillUploadAt: nil, lastLiveOutcome: nil, lastBackfillOutcome: .expired
            )
            #expect(SyncDiagnosticsReport(input).text.contains("hourly backfill: 7 of 28 days"))
        }

        @Test("Hold reasons each have their own fixed words")
        func holdWordsAreDistinct() {
            let reasons: [OutboxHoldReason] = [
                .serverRefused(status: 422), .moduleDisabled("x"), .unmappable, .refusalNotRecorded, .retryBudgetExhausted
            ]
            #expect(Set(reasons.map(SyncDiagnosticsReport.holdWord)).count == reasons.count)
        }
    }

#endif
