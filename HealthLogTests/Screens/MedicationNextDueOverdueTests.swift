import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the v1.16.4 `nextDueOverdue` additive contract (GH issue #15):
/// when `true`, `nextDueAt` may carry a PAST instant that is still an OPEN,
/// takeable slot (catch-up band open, unresolved). The client presents it as
/// overdue-but-takeable — never hides it, never spins — and the treatment
/// COMPOSES with the b162 dose-safety rule (`1e9cb915`): overdue-open
/// (`scheduledAt <= now`) = takeable; future doses stay not-pre-markable.
@Suite("Medication nextDueOverdue (v1.16.4)")
struct MedicationNextDueOverdueTests {
    private let decoder = JSONDecoder.hlDefault

    private static let now = ISO8601DateFormatter.plain
        .date(from: "2026-06-11T10:00:00Z")!
    /// 26 h overdue rolling slot — anchor passed, catch-up band still open.
    private static let overdueInstant = ISO8601DateFormatter.plain
        .date(from: "2026-06-10T08:00:00Z")!

    private func medication(
        nextDueAt: Date?,
        nextDueOverdue: Bool?,
        active: Bool = true,
        schedule: MedicationSchedule = MedicationSchedule(times: [])
    ) -> Medication {
        Medication(
            id: "med_overdue",
            name: "Trulicity",
            dose: "7,5 mg",
            schedule: schedule,
            active: active,
            nextDueAt: nextDueAt,
            nextDueOverdue: nextDueOverdue
        )
    }

    // MARK: - Wire decode

    @Test("Wire decodes nextDueOverdue=true with a PAST nextDueAt")
    func wireDecodesOverdueFlag() throws {
        let json = Data(#"""
        {
            "id": "med_1",
            "name": "Trulicity",
            "dose": "7,5 mg",
            "nextDueAt": "2026-06-10T08:00:00.000Z",
            "nextDueOverdue": true
        }
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        #expect(wire.nextDueOverdue == true)
        let domain = wire.toDomain()
        #expect(domain.nextDueOverdue == true)
        #expect(domain.nextDueAt == Self.overdueInstant)
        #expect(domain.hasOpenOverdueDose)
    }

    @Test("Absent nextDueOverdue decodes nil → not overdue (≤v1.16.3 compat)")
    func absentFlagDecodesNil() throws {
        let json = Data(#"""
        {"id": "med_1", "name": "Lisinopril", "dose": "5 mg"}
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        #expect(wire.nextDueOverdue == nil)
        #expect(wire.toDomain().hasOpenOverdueDose == false)
    }

    @Test("Flag true with nextDueAt null never claims overdue")
    func flagWithoutInstantIsIgnored() {
        let med = medication(nextDueAt: nil, nextDueOverdue: true)
        #expect(med.hasOpenOverdueDose == false)
        #expect(MedicationWindowStatus.serverOverdueFallback(
            medication: med, now: Self.now
        ) == nil)
    }

    // MARK: - Presentation: next-dose line keeps the PAST open slot

    @Test("computeNextDose returns the past open slot instead of suppressing it")
    func computeNextDoseKeepsOverdueSlot() throws {
        let med = medication(nextDueAt: Self.overdueInstant, nextDueOverdue: true)
        let next = try MedicationCard.computeNextDose(
            medication: med,
            timeZone: #require(TimeZone(identifier: "Europe/Berlin")),
            now: Self.now
        )
        #expect(next == Self.overdueInstant)
    }

    @Test("Without the flag a past nextDueAt stays suppressed (pre-v1.16.4 rule)")
    func withoutFlagPastInstantSuppressed() throws {
        let med = medication(nextDueAt: Self.overdueInstant, nextDueOverdue: nil)
        let next = try MedicationCard.computeNextDose(
            medication: med,
            timeZone: #require(TimeZone(identifier: "Europe/Berlin")),
            now: Self.now
        )
        #expect(next == nil)
    }

    @Test("Clock-skewed FUTURE instant with flag true routes through forward projection")
    func futureInstantIgnoresOverdueArm() throws {
        let future = Self.now.addingTimeInterval(3600)
        let med = medication(nextDueAt: future, nextDueOverdue: true)
        let next = try MedicationCard.computeNextDose(
            medication: med,
            timeZone: #require(TimeZone(identifier: "Europe/Berlin")),
            now: Self.now
        )
        // Entry-less med → falls back to the server future instant as before.
        #expect(next == future)
        #expect(MedicationWindowStatus.serverOverdueFallback(
            medication: med, now: Self.now
        ) == nil)
    }

    // MARK: - Presentation: overdue affordance (status pill)

    @Test("Server overdue flag surfaces the existing .late (Überfällig) affordance")
    func serverOverdueFallbackSurfacesLate() {
        let med = medication(nextDueAt: Self.overdueInstant, nextDueOverdue: true)
        #expect(MedicationWindowStatus.serverOverdueFallback(
            medication: med, now: Self.now
        ) == .late)
    }

    @Test("Inactive medication never surfaces the server overdue pill")
    func inactiveMedicationSuppressed() {
        let med = medication(
            nextDueAt: Self.overdueInstant,
            nextDueOverdue: true,
            active: false
        )
        #expect(MedicationWindowStatus.serverOverdueFallback(
            medication: med, now: Self.now
        ) == nil)
    }

    // MARK: - Composition with the b162 dose-safety rule

    @Test("Overdue-open slot is takeable; future dose stays not-pre-markable")
    func overdueComposesWithDoseSafety() {
        // The overdue-open slot materialises as a pending intake whose
        // scheduledAt <= now → quick-mark resolves ACTIONABLE (takeable).
        let overdueIntake = MedicationIntake(
            id: "intake_overdue",
            medicationId: "med_overdue",
            scheduledAt: Self.overdueInstant,
            status: .pending
        )
        #expect(MedicationQuickMarkState.resolve(
            medicationId: "med_overdue",
            todayIntakes: [overdueIntake],
            now: Self.now
        ) == .actionable(intakeId: "intake_overdue"))
        #expect(ActiveMedicationsSection.resolveDispatchDose(
            medicationId: "med_overdue",
            todayIntakes: [overdueIntake],
            now: Self.now
        )?.id == "intake_overdue")

        // b162 unchanged: a FUTURE pending dose is upcoming, not markable.
        let futureIntake = MedicationIntake(
            id: "intake_future",
            medicationId: "med_overdue",
            scheduledAt: Self.now.addingTimeInterval(4 * 3600),
            status: .pending
        )
        #expect(MedicationQuickMarkState.resolve(
            medicationId: "med_overdue",
            todayIntakes: [futureIntake],
            now: Self.now
        ) == .upcoming)
    }
}
