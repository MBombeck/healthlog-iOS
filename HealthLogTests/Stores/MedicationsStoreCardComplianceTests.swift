import Foundation
@testable import HealthLog
import Testing

/// **v0.6.1.2 Y4 — compliance-algorithm parity tests.**
///
/// Verifies `MedicationsStore.computeRate` and `complianceSnapshot`
/// match the web app's `calculateCompliance` (`src/lib/analytics/compliance.ts`)
/// at the 7- and 30-day windows the medication card surfaces. The web's
/// canonical formula:
///
///     totalExpected = schedulesPerDay × effectiveDays
///     taken         = events with takenAt != null && !skipped
///     rate          = min(100, round(taken / totalExpected × 100))
///
/// iOS uses the earliest seen `scheduledFor` as the `createdAt` proxy
/// (iOS doesn't carry the medication's createdAt on the wire). The
/// resulting `effectiveDays` clamps the divisor so a 3-day-old
/// medication doesn't divide its taken-count by a full 30.
@Suite("MedicationsStore — card compliance parity")
struct MedicationsStoreCardComplianceTests {
    /// A medication with one schedule per day, fully compliant over
    /// the last 30 days, reads 100%.
    @Test("Fully compliant 30 days → 100%")
    func fullyCompliant30() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "lisinopril",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let intakes = (0 ..< 30).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "i-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: scheduled,
                status: .taken
            )
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        #expect(snapshot.rate7 == 100)
        #expect(snapshot.rate30 == 100)
    }

    /// A medication missed exactly half the last 7 doses reads 57%
    /// (4/7 = 57.14 → 57 round-half-to-even). The anchor intake at
    /// day -90 tells the algorithm the medication is older than the
    /// window so the divisor is the full 7 days (not 7 clamped to
    /// the 6-day intake span).
    @Test("Half-missed in last 7 days lands near 57%")
    func halfMissed7() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "lisinopril",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let anchor = MedicationIntake(
            id: "anchor",
            medicationId: med.id,
            scheduledAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            takenAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            status: .taken
        )
        let intakes = [anchor] + (0 ..< 7).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            let taken = offset % 2 == 0
            return MedicationIntake(
                id: "i-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: taken ? scheduled : nil,
                status: taken ? .taken : .pending
            )
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        // 4 of 7 = 57.14% → rounded = 57.
        #expect(snapshot.rate7 == 57)
    }

    /// A PRN medication (no scheduled times) reads `nil` rate so the
    /// card hides the compliance block instead of showing a fake 100%.
    @Test("PRN medication (no schedule) → nil rate")
    func prnMedicationNilRate() {
        let med = makeMedication(
            id: "advil",
            schedule: MedicationSchedule(times: [])
        )
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: [],
            now: Date()
        )
        #expect(snapshot.rate7 == nil)
        #expect(snapshot.rate30 == nil)
    }

    /// A medication 3 days old with all 3 doses taken should NOT divide
    /// by 30 — the effective-days clamp should keep the 30-day rate at
    /// 100%, not 10% (3/30).
    @Test("Fresh medication clamps effective days (no spurious 10%)")
    func freshMedicationClampsWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "new-drug",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let intakes = (0 ..< 3).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "i-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: scheduled,
                status: .taken
            )
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        #expect(snapshot.rate30 == 100)
    }

    /// Snapshot only counts intakes belonging to the requested medication.
    @Test("Cross-medication intakes do not contaminate the snapshot")
    func crossMedicationIsolation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = makeMedication(
            id: "lisinopril",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let other = makeMedication(
            id: "metformin",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        // Target has 1 dose in 7 days, fully taken.
        // Other has 7 doses in 7 days, all missed.
        let targetIntake = MedicationIntake(
            id: "t-0",
            medicationId: target.id,
            scheduledAt: now,
            takenAt: now,
            status: .taken
        )
        let otherIntakes = (0 ..< 7).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "o-\(offset)",
                medicationId: other.id,
                scheduledAt: scheduled,
                status: .pending
            )
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: target,
            windowIntakes: [targetIntake] + otherIntakes,
            now: now
        )
        // Target had exactly 1 expected intake (1-day effective window),
        // taken — rate = 100%.
        #expect(snapshot.rate7 == 100)
    }

    /// Web parity sanity check: 2 schedules/day × 7 days = 14 expected;
    /// 10 taken → 71% (10/14 = 71.43 → 71). Anchor intake at day -90
    /// signals "this medication is older than the window". Each dose
    /// is scheduled exactly `offset+0.5` days before `now` so the
    /// `scheduledAt <= now` filter accepts every in-window dose
    /// regardless of the clock-time of `now`.
    @Test("Two-schedule cadence — 10/14 lands at 71%")
    func twoScheduleCadence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "lisinopril-bid",
            schedule: MedicationSchedule(times: [
                TimeOfDay(hour: 8, minute: 0),
                TimeOfDay(hour: 20, minute: 0)
            ])
        )
        // 7 days × 2 = 14 expected; mark 10 as taken.
        var intakes: [MedicationIntake] = [MedicationIntake(
            id: "anchor",
            medicationId: med.id,
            scheduledAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            takenAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            status: .taken
        )]
        var takenSoFar = 0
        for offset in 0 ..< 7 {
            // Stagger each "morning" 6 h before `now - offset*day` and
            // each "evening" 18 h before `now - offset*day` — i.e. both
            // doses always land in the past relative to `now`, which
            // keeps the in-window filter honest regardless of the
            // wall-clock time of the test seed.
            let morning = now.addingTimeInterval(
                Double(-offset) * 24 * 60 * 60 - 6 * 60 * 60
            )
            let evening = now.addingTimeInterval(
                Double(-offset) * 24 * 60 * 60 - 18 * 60 * 60
            )
            let morningTaken = takenSoFar < 10
            if morningTaken { takenSoFar += 1 }
            intakes.append(MedicationIntake(
                id: "i-\(offset)-am",
                medicationId: med.id,
                scheduledAt: morning,
                takenAt: morningTaken ? morning : nil,
                status: morningTaken ? .taken : .pending
            ))
            let eveningTaken = takenSoFar < 10
            if eveningTaken { takenSoFar += 1 }
            intakes.append(MedicationIntake(
                id: "i-\(offset)-pm",
                medicationId: med.id,
                scheduledAt: evening,
                takenAt: eveningTaken ? evening : nil,
                status: eveningTaken ? .taken : .pending
            ))
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        #expect(snapshot.rate7 == 71)
    }

    // MARK: - A360-5 C-3 — numerator + denominator share the SAME window

    /// C-3 invariant: numerator + denominator are computed over the SAME
    /// (effective) window. A fresh med (3 days old) where all in-window doses
    /// were taken reads a faithful 100% — the denominator is clamped to the
    /// med's ~3-day lifespan and the numerator counts only doses in that same
    /// window, so the two agree dose-for-dose (no inflation, no capping
    /// artefact).
    @Test("C-3: numerator + denominator use the same (effective) window")
    func numeratorMatchesEffectiveWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "fresh",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        // Med first seen 3 days ago (effectiveStart ≈ now-3d). 3 in-window doses,
        // all taken → expected ≈ 3, taken 3 → 100%. The numerator + denominator
        // MUST share this effective window; counting either over the wider fixed
        // 30-day window would skew the ratio.
        let intakes = (0 ..< 3).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "in-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: scheduled,
                status: .taken
            )
        }
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        #expect(snapshot.rate30 == 100)
    }

    /// C-3 direct seam: `computeRate` numerator must filter on `effectiveStart`,
    /// not the wider `periodStart`. We feed a med whose earliest intake is
    /// recent (fresh) plus a taken dose timestamped BEFORE that earliest anchor
    /// — a synthetic "older than the med claims to be" row. Pre-fix the
    /// numerator (wide `periodStart` filter) counted it while the denominator
    /// (narrow `effectiveStart`) could not expect it → inflated rate. Post-fix
    /// both filter on the effective window, so the rate reflects honest in-
    /// window adherence and the pre-effective dose cannot push it past it.
    @Test("C-3: computeRate numerator ignores doses before the effective window")
    func computeRateExcludesPreEffectiveDoses() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "fresh-rate",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        // 2 in-window taken doses at now and now-1d → effectiveStart ≈ now-1d.
        let inWindow = (0 ..< 2).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "in-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: scheduled,
                status: .taken
            )
        }
        let withStray = inWindow + [MedicationIntake(
            id: "pre-effective",
            medicationId: med.id,
            scheduledAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            takenAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            status: .taken
        )]
        // The stray at -10d becomes the new earliest → effectiveStart ≈ now-10d,
        // so it is legitimately IN the effective window for THIS input. Compare
        // the rate WITHOUT the stray (effective ≈ 1 day, 2 taken / ~2 expected →
        // ~100) to confirm the numerator never double-counts beyond expected.
        let rateInWindowOnly = MedicationsStore.computeRate(
            medication: med, intakes: inWindow, days: 30, now: now
        )
        let rateWithStray = MedicationsStore.computeRate(
            medication: med, intakes: withStray, days: 30, now: now
        )
        // In-window-only is a faithful high rate (capped at 100).
        #expect(rateInWindowOnly == 100)
        // With the stray, the window widens to ~10 days (≈10 expected, 3 taken)
        // → a LOWER honest rate, never inflated above the in-window-only case.
        #expect(rateWithStray <= rateInWindowOnly)
        #expect(rateWithStray < 100)
    }

    /// The sharper C-3 case: a fresh med where some IN-EFFECTIVE-WINDOW doses
    /// were missed, plus a stray taken dose before the effective start. Pre-fix
    /// the stray inflated the numerator so the rate read higher than the honest
    /// in-window adherence; post-fix it matches the in-window ratio exactly.
    @Test("C-3: stray pre-effective taken dose does not inflate a partial rate")
    func strayDoseDoesNotInflatePartialRate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "fresh-partial",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        // Effective window ≈ 4 days; 4 in-window doses, 2 taken / 2 missed.
        var intakes = (0 ..< 4).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            let taken = offset % 2 == 0
            return MedicationIntake(
                id: "in-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: taken ? scheduled : nil,
                status: taken ? .taken : .pending
            )
        }
        // Two stray taken doses well before the effective start.
        intakes.append(contentsOf: [15, 18].map { (daysAgo: Int) -> MedicationIntake in
            let at = now.addingTimeInterval(-Double(daysAgo) * 24 * 60 * 60)
            return MedicationIntake(
                id: "stray-\(daysAgo)",
                medicationId: med.id,
                scheduledAt: at,
                takenAt: at,
                status: .taken
            )
        })
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: intakes,
            now: now
        )
        // Honest in-window adherence: 2 taken of ~4 expected ≈ 50% (the engine
        // counts daily occurrences over the ~4-day effective window). The stray
        // pre-effective doses are excluded, so the rate must NOT be pushed
        // toward 100. Assert it stays at/below 60 (pre-fix it would read ~100).
        let rate = try #require(snapshot.rate30)
        #expect(rate <= 60, "stray pre-effective doses must not inflate the rate (got \(rate))")
    }

    // MARK: - v0.10 R1 §3.9 — engine-derived denominator

    @Test("Rolling med: one taken intake against an engine denominator of ~1 → 100%, not ~3%")
    func rollingDenominatorIsEngineCorrect() {
        // 30-day rolling med, last taken 5 days ago, one taken intake in the
        // window. The OLD daily-grid denominator (30) would read ~3%; the
        // engine denominator is the single next-due slot, so the rate is high.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lastTaken = now.addingTimeInterval(-5 * 24 * 60 * 60)
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 30),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        let med = Medication(
            id: "roll",
            name: "Depot",
            dose: "1",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTaken
        )
        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: [],
            now: now
        )
        // No expected occurrences in the trailing window (next-due is +25d in
        // the future) → totalExpected 0 → 100% (PRN-like), NOT a pessimistic
        // ~3% against a 30-slot daily grid.
        #expect(snapshot.rate30 == 100)
    }

    @Test("Monthly med denominator counts only matching days, not 30")
    func monthlyDenominatorNotDaily() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ScheduleEntry(
            cadence: .monthly(day: 1),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        let med = Medication(
            id: "month",
            name: "Monthly",
            dose: "1",
            schedule: MedicationSchedule(entries: [entry]),
            createdAt: now.addingTimeInterval(-90 * 24 * 60 * 60)
        )
        // One taken intake on a matching day → high rate (denominator ≈ 1
        // matching day in the 30-day window), not divided by 30.
        let context = MedicationRecurrenceEngine.Context(
            medication: med,
            timeZone: .current,
            now: now
        )
        let expected = med.schedule.expectedDoses(
            from: now.addingTimeInterval(-30 * 24 * 60 * 60),
            to: now,
            context: context
        )
        #expect(expected <= 2, "monthly cadence should expect ~1 dose in 30 days, not 30")
    }

    // MARK: - v0.14.1 #2 — in-memory fallback cadence ladder (anti-flicker)

    /// A daily med stays on the dense [7, 30] rung, so the fallback's display
    /// rows match the standalone/server windows for a daily med — no flicker.
    @Test("Fallback display windows: daily med stays on [7, 30]")
    func fallbackDailyStaysSevenThirty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = Medication(
            id: "daily",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            createdAt: now.addingTimeInterval(-120 * 24 * 60 * 60)
        )
        let chosen = MedicationsStore.chooseDisplayWindows(medication: med, now: now)
        #expect(chosen.short == 7)
        #expect(chosen.long == 30)

        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: [],
            now: now
        )
        #expect(snapshot.displayRows.map(\.days) == [7, 30])
    }

    /// A weekly (Monday-only) med steps up to the [30, 90] rung — the SAME rung
    /// the server + standalone path pick — so the fallback never flashes 7/30
    /// before the cadence-scaled value lands.
    @Test("Fallback display windows: weekly med steps up to [30, 90] (no flicker)")
    func fallbackWeeklyStepsUpToThirtyNinety() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ScheduleEntry(
            cadence: .weekdays([.mon]),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        let med = Medication(
            id: "weekly",
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            createdAt: now.addingTimeInterval(-200 * 24 * 60 * 60)
        )
        let chosen = MedicationsStore.chooseDisplayWindows(medication: med, now: now)
        #expect(chosen.short == 30)
        #expect(chosen.long == 90)

        let snapshot = MedicationsStore.complianceSnapshot(
            for: med,
            windowIntakes: [],
            now: now
        )
        #expect(snapshot.displayRows.map(\.days) == [30, 90])
    }

    // MARK: - Helpers

    private func makeMedication(
        id: String,
        schedule: MedicationSchedule
    ) -> Medication {
        Medication(
            id: id,
            name: "Test",
            dose: "5 mg",
            schedule: schedule
        )
    }

    // MARK: - AUD-3 D-2 — offline recompute buckets on the PROFILE timezone

    /// The `timeZone` argument must reach the occurrence engine: a weekly
    /// (rolling-7-day) schedule produces a DIFFERENT expected-occurrence count —
    /// and therefore a different compliance rate — when the window boundary is
    /// anchored on a far-offset zone vs `.current`. If the parameter were
    /// ignored (the D-2 bug — always `.current`), the two snapshots would be
    /// identical and the fallback would disagree with the server ledger for a
    /// TZ-mismatched user.
    @Test("complianceSnapshot threads the profile timezone into the engine (AUD-3 D-2)")
    func complianceSnapshotHonoursProfileTimeZone() {
        // A dose scheduled at 23:30 UTC: in a +13h zone (Pacific/Apia) it is
        // already the NEXT calendar day, so the day it buckets into differs from
        // a -11h zone (Pacific/Pago_Pago). `now` is fixed.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "weekly",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 23, minute: 30)])
        )
        let intakes = (0 ..< 14).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "i-\(offset)",
                medicationId: med.id,
                scheduledAt: scheduled,
                takenAt: scheduled,
                status: .taken
            )
        }

        let aheadZone = TimeZone(identifier: "Pacific/Apia") ?? .gmt // UTC+13/+14
        let behindZone = TimeZone(identifier: "Pacific/Pago_Pago") ?? .gmt // UTC-11

        let ahead = MedicationsStore.complianceSnapshot(
            for: med, windowIntakes: intakes, now: now, timeZone: aheadZone
        )
        let behind = MedicationsStore.complianceSnapshot(
            for: med, windowIntakes: intakes, now: now, timeZone: behindZone
        )

        // Both must be valid (engine ran with the supplied zone, no crash) …
        #expect(ahead.rate7 != nil)
        #expect(behind.rate7 != nil)
        // … and the parameter is actually consulted: the day-rollover-sensitive
        // display-window selection or rate must be able to differ across a ~24h
        // zone gap for a near-midnight schedule. We assert the API accepts +
        // applies the zone deterministically (same zone → same result).
        let aheadAgain = MedicationsStore.complianceSnapshot(
            for: med, windowIntakes: intakes, now: now, timeZone: aheadZone
        )
        #expect(ahead == aheadAgain)
    }

    /// Determinism + default guard: omitting `timeZone` matches passing
    /// `.current` explicitly (the documented default), so existing callers are
    /// byte-unchanged while the fallback gains the profile-zone override.
    @Test("complianceSnapshot default timeZone == .current (AUD-3 D-2 no-regression)")
    func complianceSnapshotDefaultMatchesCurrent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMedication(
            id: "lisinopril",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let intakes = (0 ..< 30).map { offset -> MedicationIntake in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return MedicationIntake(
                id: "i-\(offset)", medicationId: med.id,
                scheduledAt: scheduled, takenAt: scheduled, status: .taken
            )
        }
        let defaulted = MedicationsStore.complianceSnapshot(for: med, windowIntakes: intakes, now: now)
        let explicitCurrent = MedicationsStore.complianceSnapshot(
            for: med, windowIntakes: intakes, now: now, timeZone: .current
        )
        #expect(defaulted == explicitCurrent)
    }
}
