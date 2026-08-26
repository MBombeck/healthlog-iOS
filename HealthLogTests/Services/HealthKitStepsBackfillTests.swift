import Foundation
@testable import HealthLog
import Testing

// v0.7.0 W-STEPS — pure-helper coverage for the steps-backfill cascade.
//
// Pins the three pure decision points behind the operator-reported
// "Schritte alle Daten zeigt nichts" fix:
//
//   - `AppContainer.dailyStatsLookbackForNextSweep` — the one-shot
//     window-aware backfill gate (Layer 2).
//   - `MeasurementsRepository.seriesDays(forLimit:)` — the limit → days
//     translation for the cumulative series routing (Layer 3).
//   - `MetricKind.prefersSeriesForRecent` — which kinds route through the
//     series path (Layer 3).
#if !SWIFT_PACKAGE

    @Suite("v0.7.0 W-STEPS — steps backfill cascade")
    struct HealthKitStepsBackfillTests {
        // MARK: - Layer 2: daily-stats one-shot backfill gate

        private func freshDefaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "w-steps.\(UUID().uuidString)"))
        }

        @Test("First sweep after onboarding honors the persisted .allTime window")
        func firstSweepHonorsAllTimeWindow() throws {
            let keychain = InMemoryKeychain()
            try? keychain.setString("user-allTime", forKey: KeychainKey.userID)
            let defaults = try freshDefaults()
            HealthKitBackfillWindowStore.persist(.allTime, keychain: keychain, defaults: defaults)

            let first = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(first == AppContainer.allTimeLookbackDays, ".allTime → ~10y one-shot backfill")
        }

        @Test("Sweep stays incremental only after the one-shot is marked complete")
        func secondSweepIsIncremental() throws {
            let keychain = InMemoryKeychain()
            try? keychain.setString("user-incremental", forKey: KeychainKey.userID)
            let defaults = try freshDefaults()
            HealthKitBackfillWindowStore.persist(.oneYear, keychain: keychain, defaults: defaults)

            // v0.7.1 M-3 — the lookup is now a pure read: it keeps returning
            // the wide window until the sweep actually completes and the flag
            // is marked. Pre-fix it burned the flag on the first read, so an
            // interrupted sweep silently skipped the backfill forever.
            let first = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(first == 365, "first sweep = .oneYear window")
            let stillPending = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(stillPending == 365, "read is pure — still wide until the sweep completes")

            AppContainer.markDailyStatsAllTimeBackfillCompleted(keychain: keychain, defaults: defaults)

            let second = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(second == AppContainer.incrementalLookbackDays, "after completion = 7-day catch-up")
            let third = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(third == AppContainer.incrementalLookbackDays, "stays incremental — one-shot never repeats")
        }

        @Test("An interrupted first sweep re-arms the all-time backfill (M-3)")
        func interruptedSweepReArms() throws {
            let keychain = InMemoryKeychain()
            try? keychain.setString("user-interrupted", forKey: KeychainKey.userID)
            let defaults = try freshDefaults()
            HealthKitBackfillWindowStore.persist(.allTime, keychain: keychain, defaults: defaults)

            // Simulate a first sweep that read the wide span but was killed
            // before it could mark completion — the next launch must still
            // hand out the wide span, not silently degrade to incremental.
            let first = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(first == AppContainer.allTimeLookbackDays)
            // (no markDailyStatsAllTimeBackfillCompleted — sweep was interrupted)
            let retry = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(retry == AppContainer.allTimeLookbackDays, "interrupted sweep re-arms the one-shot backfill")
        }

        @Test("No persisted window falls back to the incremental window")
        func noWindowFallsBackIncremental() throws {
            let keychain = InMemoryKeychain()
            try? keychain.setString("user-nowindow", forKey: KeychainKey.userID)
            let defaults = try freshDefaults()
            // No `persist(...)` — pre-onboarding shape.
            let lookback = AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
            #expect(lookback == AppContainer.incrementalLookbackDays)
        }

        @Test("The one-shot gate is per-User partitioned")
        func gateIsPerUser() throws {
            let keychain = InMemoryKeychain()
            let defaults = try freshDefaults()

            try? keychain.setString("alice", forKey: KeychainKey.userID)
            HealthKitBackfillWindowStore.persist(.ninetyDays, keychain: keychain, defaults: defaults)
            #expect(AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults) == 90)
            // Complete alice's one-shot the way the sweep hook would.
            AppContainer.markDailyStatsAllTimeBackfillCompleted(keychain: keychain, defaults: defaults)
            #expect(AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults) == 7)

            // Switching user re-arms the one-shot for the new partition.
            try? keychain.setString("bob", forKey: KeychainKey.userID)
            HealthKitBackfillWindowStore.persist(.allTime, keychain: keychain, defaults: defaults)
            #expect(
                AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults)
                    == AppContainer.allTimeLookbackDays,
                "bob's first sweep is not gated by alice's completed flag"
            )
        }

        @Test("Window → lookback translation covers every case")
        func windowToLookbackTranslation() {
            #expect(AppContainer.lookbackDays(for: .sevenDays) == 7)
            #expect(AppContainer.lookbackDays(for: .thirtyDays) == 30)
            #expect(AppContainer.lookbackDays(for: .ninetyDays) == 90)
            #expect(AppContainer.lookbackDays(for: .oneYear) == 365)
            #expect(AppContainer.lookbackDays(for: .allTime) == AppContainer.allTimeLookbackDays)
        }

        // MARK: - Layer 3: limit → series-days translation

        @Test("seriesDays maps the .all-range wide limit to the full history")
        func seriesDaysAllRange() {
            #expect(MeasurementsRepository.seriesDays(forLimit: 2000) == 3650)
            #expect(MeasurementsRepository.seriesDays(forLimit: 5000) == 3650)
        }

        @Test("seriesDays keeps non-.all limits at ≥1y, floored at 365")
        func seriesDaysDefaultPage() {
            #expect(MeasurementsRepository.seriesDays(forLimit: 400) == 400, "default page ≈ 13 months")
            #expect(MeasurementsRepository.seriesDays(forLimit: 50) == 365, "floors at 365 for small limits")
            #expect(MeasurementsRepository.seriesDays(forLimit: 1000) == 1000)
        }

        // MARK: - Layer 3: series-routing predicate

        @Test(".steps prefers the series path; display-cumulative stays steps-only")
        func prefersSeriesForRecentPredicate() {
            #expect(MetricKind.steps.prefersSeriesForRecent == true)
            #expect(MetricKind.sleep.prefersSeriesForRecent == false, "sleep stays on the recent page")
            #expect(MetricKind.weight.prefersSeriesForRecent == false)
            #expect(MetricKind.bloodPressure.prefersSeriesForRecent == false)
            // The tile-display `isCumulative` contract is untouched.
            #expect(MetricKind.steps.isCumulative == true)
            #expect(MetricKind.sleep.isCumulative == false)
        }
    }

#endif // !SWIFT_PACKAGE
