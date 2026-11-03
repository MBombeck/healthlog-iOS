// App-Target-Symbole (`ServerFreshnessFacts`, `KindRow`, the diagnostics
// screen) are not in the SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **W5 (1.3.0, #126 1.4, HealthLog#586, #1173) — one story.**
    ///
    /// Pins the derivation, not localized text: which time a row states (last
    /// check or last new value), where a fact comes from, and that the two
    /// cards that used to contradict each other for pulse now say two facts.
    /// Fixtures follow `AppleHealthMetricFreshnessEntry` in
    /// `docs/api/openapi.yaml` at server tag `v1.42.4`.
    @Suite("W5 — Sync Diagnostics tells one story")
    @MainActor
    struct SyncDiagnosticsStoryTests {
        private static let now = Date(timeIntervalSince1970: 1_792_137_600) // 2026-10-16T08:00:00Z

        private static func ago(_ hours: Double) -> Date {
            now.addingTimeInterval(-hours * 3600)
        }

        // MARK: - Decoding (v1.42.4)

        @Test("`lastBackgroundAt` and the `MEDICATION_DOSE` entry decode; a broken value is absence")
        func decodesBackgroundArrivalAndDoses() throws {
            let json = Data("""
            {
              "entries": [],
              "metricFreshness": [
                {"type": "PULSE", "lastSeenAt": "2026-10-16T07:50:00Z", "stale": false,
                 "lastReceivedAt": "2026-10-16T07:59:30Z", "lastTrigger": "foreground",
                 "lastNewSampleAt": "2026-10-16T07:59:30Z", "lastBackgroundAt": "2026-10-16T03:00:00Z"},
                {"type": "MEDICATION_DOSE", "lastSeenAt": "2026-10-16T06:00:00Z", "stale": false,
                 "lastReceivedAt": "2026-10-16T06:05:00Z", "lastTrigger": "background",
                 "lastNewSampleAt": "2026-10-16T06:05:00Z", "lastBackgroundAt": "2026-10-16T06:05:00Z"},
                {"type": "STEPS_FUTURE", "lastSeenAt": "2026-10-16T06:00:00Z", "stale": false,
                 "lastBackgroundAt": "not a date"},
                {"type": "WORKOUTS", "lastSeenAt": "2026-10-15T18:00:00Z", "stale": false}
              ]
            }
            """.utf8)
            let config = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: json)
            let rows = try #require(config.metricFreshness)
            #expect(rows.count == 4)
            #expect(rows[0].lastBackgroundAt == ISO8601DateFormatter().date(from: "2026-10-16T03:00:00Z"))
            #expect(rows[1].type == "MEDICATION_DOSE")
            #expect(rows[1].lastTrigger == "background")
            #expect(rows[2].lastBackgroundAt == nil)
            #expect(rows[3].lastBackgroundAt == nil)
        }

        @Test("`MEDICATION_DOSE` reads as its own name, not as a shouted identifier")
        func medicationDoseHasAName() {
            let name = HKSyncDiagnosticsVocabulary.freshnessType("MEDICATION_DOSE")
            #expect(name == String(localized: "settings.hkdiag.freshness.medication_dose"))
            #expect(name != HKSyncDiagnosticsVocabulary.prettifiedTypeKey("MEDICATION_DOSE"))
            #expect(ServerFreshnessFacts(row: MetricFreshness(type: "medication_dose")).isMedicationDose)
        }

        // MARK: - Server rows: checked vs new value

        @Test("HealthLog#1173: distance checked a minute ago with nothing new reads as checked, not as stale")
        func uncheckedChangeIsNotStale() {
            let row = MetricFreshness(
                type: "WALKING_RUNNING_DISTANCE",
                lastSeenAt: Self.ago(9),
                lastReceivedAt: Self.ago(0.02),
                lastTrigger: "background",
                lastNewSampleAt: Self.ago(9)
            )
            let facts = ServerFreshnessFacts(row: row)
            #expect(facts.lastChecked == Self.ago(0.02))
            #expect(facts.lastNewValue == Self.ago(9))
            #expect(facts.lastCheckFoundNothingNew)
            #expect(facts.detailLines.count == 2)
            #expect(facts.detailLines.first == facts.checkedLabel)
        }

        @Test("A receipt that brought the new value is one fact, not two")
        func sameBatchIsNotNothingNew() {
            let row = MetricFreshness(
                type: "PULSE",
                lastReceivedAt: Self.ago(1),
                lastTrigger: "background",
                lastNewSampleAt: Self.ago(1).addingTimeInterval(-20)
            )
            #expect(!ServerFreshnessFacts(row: row).lastCheckFoundNothingNew)
        }

        @Test("HealthLog#586: opening the app no longer hides the earlier background arrival")
        func backgroundArrivalSurvivesAnAppOpen() {
            let opened = MetricFreshness(
                type: "ACTIVITY_STEPS",
                lastReceivedAt: Self.ago(0.01),
                lastTrigger: "foreground",
                lastNewSampleAt: Self.ago(0.01),
                lastBackgroundAt: Self.ago(5)
            )
            let facts = ServerFreshnessFacts(row: opened)
            #expect(facts.separateBackgroundArrival == Self.ago(5))
            #expect(facts.backgroundLabel != nil)
            #expect(facts.detailLines.count == 3)

            // When the last check WAS the background arrival, one line says it.
            let background = MetricFreshness(
                type: "ACTIVITY_STEPS",
                lastReceivedAt: Self.ago(5),
                lastTrigger: "background",
                lastNewSampleAt: Self.ago(5),
                lastBackgroundAt: Self.ago(5)
            )
            #expect(ServerFreshnessFacts(row: background).separateBackgroundArrival == nil)
        }

        @Test("An older server without arrival fields gives no invented line")
        func olderServerSaysNothing() {
            let row = MetricFreshness(type: "PULSE", lastSeenAt: Self.ago(2))
            let facts = ServerFreshnessFacts(row: row)
            #expect(facts.detailLines.isEmpty)
            #expect(!facts.lastCheckFoundNothingNew)
        }

        // MARK: - The pulse contradiction (#126 1.4)

        @Test("Day totals and pulse: the server's line for the same type sits next to the local record")
        func pulseIsTwoFactsNotAContradiction() {
            let freshness = [
                MetricFreshness(type: "PULSE", lastReceivedAt: Self.ago(5), lastTrigger: "background"),
                MetricFreshness(type: "walking_running_distance", lastReceivedAt: Self.ago(1), lastTrigger: "foreground")
            ]
            // Local record has nothing for pulse (it went up as single readings).
            let local = SettingsHKSyncDiagnosticsScreen.statsSentLabel(nil)
            #expect(local == String(localized: "settings.hkdiag.stats.none_sent"))
            #expect(local != String(localized: "settings.hkdiag.never"))
            let pulse = SettingsHKSyncDiagnosticsScreen.statsServerLine(
                "HKQuantityTypeIdentifierHeartRate",
                freshness: freshness
            )
            #expect(pulse != nil)
            // Case and separators do not matter for the match.
            #expect(SettingsHKSyncDiagnosticsScreen.statsServerLine(
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                freshness: freshness
            ) != nil)
            // No server row, no server line; never a guess.
            #expect(SettingsHKSyncDiagnosticsScreen.statsServerLine(
                "HKQuantityTypeIdentifierStepCount",
                freshness: freshness
            ) == nil)
            #expect(SettingsHKSyncDiagnosticsScreen.statsServerLine(
                "HKQuantityTypeIdentifierHeartRate",
                freshness: nil
            ) == nil)
        }

        @Test("Every summed type and the pulse row of the card have a server type to read")
        func everyStatsRowMapsToTheServer() {
            for identifier in SettingsHKSyncDiagnosticsScreen.statsUploadIdentifiers {
                #expect(HealthSampleReplayFloor.serverType[identifier] != nil, "\(identifier)")
            }
        }

        // MARK: - Session rows

        private func row(
            _ kind: MetricKind = .steps,
            sweep: Date? = nil,
            _ make: (inout HKSyncDiagnostics.KindStats) -> Void
        ) -> KindRow {
            var stats = HKSyncDiagnostics.KindStats(identifier: kind.rawValue)
            make(&stats)
            return KindRow(kind: kind, stats: stats, lastSweepAt: sweep)
        }

        @Test("A summed kind whose sweep found nothing new is checked, not silent for nine hours")
        func sweepWithoutChangeIsACheck() {
            let r = row(sweep: Self.ago(0.05)) { stats in
                stats.statsPostedTotal = 1
                stats.lastStatsActionAt = Self.ago(9)
            }
            #expect(r.timeFact == .newValue(Self.ago(9), checkedSince: Self.ago(0.05)))
            #expect(r.lastTouchedAt == Self.ago(0.05))
        }

        @Test("Checked only, new value only, and nothing since launch")
        func timeFacts() {
            #expect(row { _ in }.timeFact == .none)
            #expect(row { $0.lastObservationAt = Self.ago(1) }.timeFact == .checkedOnly(Self.ago(1)))
            let uploaded = row(.pulse) { stats in
                stats.samplesUploadedTotal = 3
                stats.lastAnchorAdvancedAt = Self.ago(2)
                stats.lastObservationAt = Self.ago(2).addingTimeInterval(10)
            }
            #expect(uploaded.timeFact == .newValue(Self.ago(2), checkedSince: nil))
        }

        @Test("An anchor move without a stored reading is not a new value")
        func anchorAloneIsNotANewValue() {
            let r = row(.pulse) { stats in
                stats.lastAnchorAdvancedAt = Self.ago(1)
                stats.lastObservationAt = Self.ago(1)
            }
            #expect(r.lastNewValueAt == nil)
            #expect(r.timeFact == .checkedOnly(Self.ago(1)))
        }
    }

#endif
