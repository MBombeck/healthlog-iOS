import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.2 H2 — standalone cadence-scaled `complianceDisplay`.**
///
/// Offline/standalone never emitted the server's cadence-scaled
/// `complianceDisplay`, so a weekly med (Trulicity) showed a misleading
/// pessimistic 7-day rate offline (the 14%/11% pathology the 30/90 ladder
/// fixes). `MedicationsRepository.complianceDisplay(…)` mirrors the server
/// `buildComplianceDisplay` ladder on-device: pick the first rung whose BOTH
/// windows hold ≥4 expected occurrences, else the widest rung. These pin the
/// rung selection per cadence so the offline card matches the online card.
@Suite("MedicationsRepository — standalone complianceDisplay ladder (H2)")
struct StandaloneComplianceDisplayTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = berlin
        return c
    }

    /// Fixed "now" so the trailing windows are deterministic.
    private static let now: Date = {
        var c = cal()
        return c.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!
    }()

    private static func dailyMed() -> Medication {
        Medication(
            id: "daily",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            createdAt: cal().date(byAdding: .day, value: -120, to: now)
        )
    }

    /// Weekly Monday-only med, created well before the window so the engine
    /// emits full history (≈4 doses in 30 days, ≈13 in 90 days).
    private static func weeklyMed() -> Medication {
        let entry = ScheduleEntry(
            cadence: .weekdays([.mon]),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        return Medication(
            id: "weekly",
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            createdAt: cal().date(byAdding: .day, value: -200, to: now)
        )
    }

    @Test("Daily med stays on the dense [7, 30] rung")
    func dailyOnSevenThirty() {
        let display = MedicationsRepository.complianceDisplay(
            medication: Self.dailyMed(),
            intakes: [],
            now: Self.now,
            calendar: Self.cal()
        )
        #expect(display.shortDays == 7)
        #expect(display.longDays == 30)
    }

    @Test("Weekly med steps up to the [30, 90] rung (Trulicity 30/90 parity)")
    func weeklyStepsUpToThirtyNinety() {
        let display = MedicationsRepository.complianceDisplay(
            medication: Self.weeklyMed(),
            intakes: [],
            now: Self.now,
            calendar: Self.cal()
        )
        // A 7-day window holds ≤1 weekly dose (< 4) → the short row steps up.
        #expect(display.shortDays == 30)
        #expect(display.longDays == 90)
    }

    @Test("Weekly compliant user reads a non-pessimistic rate on the scaled rung")
    func weeklyCompliantRateIsHonest() {
        let cal = Self.cal()
        let med = Self.weeklyMed()
        // Log a taken dose every Monday for the trailing ~12 weeks so the 30-day
        // (≈4 Mondays) window is fully compliant rather than reading ~14%.
        var intakes: [LocalIntakeSnapshot] = []
        for week in 0 ..< 12 {
            let mondayThisWeek = cal.nextDate(
                after: cal.date(byAdding: .day, value: -((week + 1) * 7), to: Self.now)!,
                matching: DateComponents(hour: 9, weekday: 2), // Monday
                matchingPolicy: .nextTime
            )!
            intakes.append(LocalIntakeSnapshot(
                externalId: "i-\(week)",
                medicationId: med.id,
                takenAt: mondayThisWeek,
                status: "taken",
                createdAt: Self.now
            ))
        }
        let display = MedicationsRepository.complianceDisplay(
            medication: med,
            intakes: intakes,
            now: Self.now,
            calendar: cal
        )
        // The scaled short window (30 days) holds ~4 Mondays; a fully-logged
        // user must read well above the pessimistic 7-day rate.
        #expect(display.shortDays == 30)
        #expect(display.short.rate >= 50)
        // Streak is threaded from the cadence-correct window.
        #expect(display.short.streak != nil)
    }

    @Test("PRN med (no schedule) returns 100% display rows on the widest rung")
    func prnEmptySchedule() {
        let med = Medication(
            id: "prn",
            name: "Naproxen",
            dose: "400 mg",
            schedule: MedicationSchedule(times: []),
            createdAt: Self.now
        )
        let display = MedicationsRepository.complianceDisplay(
            medication: med,
            intakes: [],
            now: Self.now,
            calendar: Self.cal()
        )
        // No expected doses on any rung → widest rung, rate clamps to 100.
        #expect(display.shortDays == 90)
        #expect(display.longDays == 365)
        #expect(display.short.rate == 100)
        #expect(display.long.rate == 100)
    }
}

// swiftlint:enable force_unwrapping
