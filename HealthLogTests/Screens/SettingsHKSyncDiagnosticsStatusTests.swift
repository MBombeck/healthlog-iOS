// Tests App-Target-only Symbole (`KindRow`, `HKSyncDiagnostics`), die in der
// SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// Pins the FIX-2 contract: the HK sync diagnostics status classification no
    /// longer false-flags daily-stats (cumulative) kinds as "stuck".
    ///
    /// Before the fix, a cumulative kind under `enableDailyStats` looked like
    /// `samplesRead > 0 && samplesUploaded == 0` (the gate drops the foreign
    /// samples after reading them) while the REAL upload went up the HK-STATS
    /// path and bumped `statsPostedTotal`. The old `read > 0 && uploaded == 0`
    /// heuristic therefore reported "Hängt"/Stalled for steps / floors / walking
    /// even though sync worked perfectly.
    @Suite("SettingsHKSyncDiagnostics — status classification (FIX 2)")
    struct SettingsHKSyncDiagnosticsStatusTests {
        private func row(_ make: (inout HKSyncDiagnostics.KindStats) -> Void) -> KindRow {
            var stats = HKSyncDiagnostics.KindStats(identifier: "HKQuantityTypeIdentifierStepCount")
            make(&stats)
            return KindRow(kind: .steps, stats: stats)
        }

        @Test("Stats actions > 0 → healthy, NOT stalled (the daily-stats false positive)")
        func statsActionsAreHealthy() {
            let now = Date()
            let r = row { stats in
                // Cumulative kind under the daily-stats gate: reads happened,
                // the gate dropped them (uploaded == 0), but the stats path
                // posted authoritatively a while ago.
                stats.samplesReadTotal = 12
                stats.samplesUploadedTotal = 0
                stats.statsPostedTotal = 3
                stats.lastObservationAt = now.addingTimeInterval(-12 * 60 * 60)
                stats.lastStatsActionAt = now.addingTimeInterval(-12 * 60 * 60)
            }
            #expect(r.status(now: now) == .healthy)
            #expect(r.status(now: now) != .stalled)
        }

        /// #113 — this case used to be pinned as `.healthy`: five rows read, none
        /// stored, anchor moved. That is exactly how a type whose every reading
        /// the server refused showed "OK" for a month. An anchor move is proof
        /// only when nothing read is unaccounted for.
        @Test("#113: anchor moved but the reads were not stored → not healthy")
        func anchorAdvanceWithoutStoredReadsIsNotHealthy() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 5
                stats.samplesUploadedTotal = 0
                stats.lastAnchorAdvancedAt = now.addingTimeInterval(-10 * 60 * 60)
                stats.lastObservationAt = now.addingTimeInterval(-10 * 60 * 60)
            }
            #expect(r.status(now: now) != .healthy)
        }

        @Test("anchor moved with nothing read (armed, quiet) → healthy")
        func quietAnchorAdvanceIsHealthy() {
            let now = Date()
            let r = row { stats in
                stats.lastAnchorAdvancedAt = now.addingTimeInterval(-10 * 60 * 60)
                stats.lastObservationAt = now.addingTimeInterval(-10 * 60 * 60)
            }
            #expect(r.status(now: now) == .healthy)
        }

        @Test("every read handed to the daily-stats path → healthy, not stalled")
        func handedOffReadsAreHealthy() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 5
                stats.samplesHandedOffTotal = 5
                stats.lastAnchorAdvancedAt = now.addingTimeInterval(-10 * 60 * 60)
                stats.lastObservationAt = now.addingTimeInterval(-10 * 60 * 60)
            }
            #expect(r.status(now: now) == .healthy)
        }

        @Test("#113: a refused (skipped) row is a warning, even next to stored rows")
        func skippedRowsWarn() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 3
                stats.samplesUploadedTotal = 2
                stats.samplesSkippedTotal = 1
                stats.lastAnchorAdvancedAt = now
                stats.lastObservationAt = now
            }
            #expect(r.status(now: now) == .warning)
            #expect(r.statusTint == HLColor.statusWarn)
        }

        @Test("#113: a parked row is a warning")
        func parkedRowsWarn() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 1
                stats.samplesParkedTotal = 1
                stats.lastAnchorAdvancedAt = now
                stats.lastObservationAt = now
            }
            #expect(r.status(now: now) == .warning)
        }

        @Test("#113: rows in the skip register warn after a relaunch zeroed the counters")
        func registeredSkipsWarnAcrossRelaunch() {
            let r = KindRow(
                kind: .spo2,
                stats: HKSyncDiagnostics.KindStats(identifier: "HKQuantityTypeIdentifierOxygenSaturation"),
                registeredSkipCount: 2
            )
            #expect(r.status(now: Date()) == .warning)
        }

        @Test("Genuine stall: reads, no upload, no stats, stale → stalled")
        func genuineStall() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 7
                stats.samplesUploadedTotal = 0
                stats.lastObservationAt = now.addingTimeInterval(-24 * 60 * 60)
            }
            #expect(r.status(now: now) == .stalled)
        }

        @Test("Reads with fresh activity but no upload yet → idle, not stalled (in-flight)")
        func freshReadNotStalled() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 4
                stats.samplesUploadedTotal = 0
                stats.lastObservationAt = now.addingTimeInterval(-60) // 1 min ago
            }
            #expect(r.status(now: now) == .idle)
        }

        @Test("No activity at all → idle (seeded full-registry rows)")
        func noActivityIsIdle() {
            let r = row { _ in }
            #expect(r.status(now: Date()) == .idle)
        }

        @Test("Successful upload → healthy")
        func uploadIsHealthy() {
            let now = Date()
            let r = row { stats in
                stats.samplesReadTotal = 6
                stats.samplesUploadedTotal = 6
                stats.lastObservationAt = now
            }
            #expect(r.status(now: now) == .healthy)
        }
    }

#endif
