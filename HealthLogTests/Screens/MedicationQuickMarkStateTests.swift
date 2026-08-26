import Foundation
@testable import HealthLog
import Testing

/// Predicate-level coverage for `MedicationQuickMarkState.resolve` — the
/// pure-function helper that drives the quick-mark-taken button on
/// `MedicationsScreen` rows. SwiftUI button-bodies are tested by their
/// inputs (the resolved state) and the unit-tests below exhaustively
/// cover the resolution rules so a future regression in
/// MedicationsScreen.swift cannot silently change the surfaced state.
@Suite("MedicationQuickMarkState — resolver predicates")
struct MedicationQuickMarkStateTests {
    private let now = Date(timeIntervalSince1970: 1_714_550_400) // pin

    private func intake(
        id: String,
        medId: String = "med-1",
        offset: TimeInterval,
        status: IntakeStatus,
        takenAt: Date? = nil
    ) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medId,
            scheduledAt: now.addingTimeInterval(offset),
            takenAt: takenAt,
            status: status,
            snoozedUntil: nil
        )
    }

    // MARK: - .notScheduledToday

    @Test("Empty todayIntakes resolves to .notScheduledToday")
    func emptyResolvesToNotScheduled() {
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [],
            now: now
        )
        #expect(state == .notScheduledToday)
    }

    @Test("Today list with no rows for the target med resolves to .notScheduledToday")
    func disjointMedResolvesToNotScheduled() {
        let other = intake(id: "evt-x", medId: "med-OTHER", offset: -3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [other],
            now: now
        )
        #expect(state == .notScheduledToday)
    }

    @Test("Only-skipped today entries resolve to .notScheduledToday")
    func onlySkippedResolvesToNotScheduled() {
        let skipped = intake(id: "evt-1", offset: -7200, status: .skipped)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [skipped],
            now: now
        )
        #expect(state == .notScheduledToday)
    }

    @Test("Only-snoozed today entries resolve to .notScheduledToday")
    func onlySnoozedResolvesToNotScheduled() {
        let snoozed = intake(id: "evt-1", offset: -1800, status: .snoozed)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [snoozed],
            now: now
        )
        #expect(state == .notScheduledToday)
    }

    // MARK: - .takenToday

    @Test("Any taken intake today wins over later-pending ones")
    func takenTakesPrecedenceOverPending() {
        let taken = intake(id: "evt-1", offset: -7200, status: .taken, takenAt: now.addingTimeInterval(-7000))
        let stillPending = intake(id: "evt-2", offset: 3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [taken, stillPending],
            now: now
        )
        #expect(state == .takenToday)
    }

    @Test("Single taken intake resolves to .takenToday")
    func singleTakenResolvesToTakenToday() {
        let taken = intake(id: "evt-1", offset: -1800, status: .taken, takenAt: now.addingTimeInterval(-1700))
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [taken],
            now: now
        )
        #expect(state == .takenToday)
    }

    // MARK: - .actionable

    @Test("Single past-due pending intake resolves to .actionable with that id")
    func pastDuePendingIsActionable() {
        let pending = intake(id: "evt-7", offset: -3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [pending],
            now: now
        )
        #expect(state == .actionable(intakeId: "evt-7"))
    }

    @Test("Earliest past-due pending wins when multiple past-due rows exist")
    func earliestPastDueWins() {
        let earlier = intake(id: "evt-A", offset: -10800, status: .pending)
        let later = intake(id: "evt-B", offset: -3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [later, earlier], // reversed input order
            now: now
        )
        #expect(state == .actionable(intakeId: "evt-A"))
    }

    @Test("Past-due pending takes precedence over future-pending")
    func pastDuePendingBeatsFuture() {
        let pastPending = intake(id: "evt-A", offset: -1800, status: .pending)
        let futurePending = intake(id: "evt-B", offset: 3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [pastPending, futurePending],
            now: now
        )
        #expect(state == .actionable(intakeId: "evt-A"))
    }

    @Test("Intake scheduledAt == now is treated as actionable (boundary)")
    func exactlyNowIsActionable() {
        let boundary = intake(id: "evt-now", offset: 0, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [boundary],
            now: now
        )
        #expect(state == .actionable(intakeId: "evt-now"))
    }

    // MARK: - .upcoming

    @Test("Only-future-pending today intake resolves to .upcoming")
    func futurePendingResolvesToUpcoming() {
        let future = intake(id: "evt-future", offset: 3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [future],
            now: now
        )
        #expect(state == .upcoming)
    }

    @Test("Future-pending alongside an earlier skip still resolves to .upcoming")
    func futurePendingWithEarlierSkip() {
        let skipped = intake(id: "evt-A", offset: -7200, status: .skipped)
        let future = intake(id: "evt-B", offset: 3600, status: .pending)
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [skipped, future],
            now: now
        )
        #expect(state == .upcoming)
    }

    // MARK: - Multi-med isolation

    @Test("Resolver scopes strictly to the target medication-id")
    func multipleMedIsolation() {
        let myActionable = intake(id: "evt-M1", medId: "med-1", offset: -1800, status: .pending)
        let otherTaken = intake(id: "evt-M2", medId: "med-2", offset: -3600, status: .taken)
        let state1 = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: [myActionable, otherTaken],
            now: now
        )
        let state2 = MedicationQuickMarkState.resolve(
            medicationId: "med-2",
            todayIntakes: [myActionable, otherTaken],
            now: now
        )
        #expect(state1 == .actionable(intakeId: "evt-M1"))
        #expect(state2 == .takenToday)
    }

    // MARK: - Default-now overload smoke

    @Test("Resolver default-now overload compiles and returns a valid state")
    func defaultNowOverloadSmoke() {
        let state = MedicationQuickMarkState.resolve(
            medicationId: "med-1",
            todayIntakes: []
        )
        #expect(state == .notScheduledToday)
    }

    // MARK: - UX-H2 hit-target contract

    @Test("QuickMarkButton hit-target meets HIG 44 pt minimum (UX-H2)")
    func hitTargetMatchesHIG() {
        // Apple HIG explicitly requires interactive controls to expose a
        // 44 × 44 pt minimum tap-target. The visual chip is intentionally
        // smaller (32 pt) so the row layout matches the pill-icon column
        // next to it, but the tap-target must extend past the visual edge.
        #expect(MedicationQuickMarkButton.minHitTarget >= 44.0)
        #expect(MedicationQuickMarkButton.visualSize == 32.0)
        // Visual chip strictly smaller than the hit-target — otherwise the
        // surrounding padding doesn't expand the hit area.
        #expect(MedicationQuickMarkButton.visualSize < MedicationQuickMarkButton.minHitTarget)
    }
}
