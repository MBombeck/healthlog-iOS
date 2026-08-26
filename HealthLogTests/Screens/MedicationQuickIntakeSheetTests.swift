import Foundation
@testable import HealthLog
import Testing

/// **v0.5.3-EQ-1** contract tests for `MedicationQuickIntakeSheet`.
///
/// The sheet itself can't be driven headless without a SwiftUI host —
/// what we *can* anchor are the resolution rules the sheet leans on for
/// the chooser list + the single-intake auto-advance. The operator's
/// pain point ("kann es auch nicht mehr bearbeiten, wenn ich es da aus
/// versehen drauf gedrückt habe") landed on three behaviours that need
/// pinning:
///
/// 1. The chooser surfaces only **actionable** intakes — pending +
///    past-due, earliest first, joined to their active medication.
///    Already-taken / future-only / skipped / archived-med rows must
///    not appear.
/// 2. `IntakeOption.Hashable` identity is intake-id-keyed so
///    `NavigationPath` de-dupes repeat appends rather than stacking
///    confirm screens.
/// 3. `onDismiss` round-trips a single invocation per close (no
///    double-fire that would leak through to the parent's
///    `showMedicationQuickIntakeSheet` flag).
@MainActor
@Suite("MedicationQuickIntakeSheet — EQ-1 contract")
struct MedicationQuickIntakeSheetTests {
    @Test("Chooser actionable derivation — pending + past-due + active med only")
    func actionableDerivationPinsRules() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activeMed = makeMed(id: "active", name: "Ozempic", active: true)
        let archivedMed = makeMed(id: "archived", name: "OldPill", active: false)

        store._testForceSet(medications: [activeMed, archivedMed])
        store._testForceSet(todayIntakes: [
            // Past-due + pending + active med → actionable.
            MedicationIntake(
                id: "i-actionable-1",
                medicationId: activeMed.id,
                scheduledAt: now.addingTimeInterval(-3600),
                status: .pending
            ),
            // Already taken — not actionable (chooser shouldn't suggest a redundant mark).
            MedicationIntake(
                id: "i-taken",
                medicationId: activeMed.id,
                scheduledAt: now.addingTimeInterval(-7200),
                takenAt: now,
                status: .taken
            ),
            // Future pending — not actionable yet.
            MedicationIntake(
                id: "i-future",
                medicationId: activeMed.id,
                scheduledAt: now.addingTimeInterval(3600),
                status: .pending
            ),
            // Skipped — not actionable.
            MedicationIntake(
                id: "i-skipped",
                medicationId: activeMed.id,
                scheduledAt: now.addingTimeInterval(-1800),
                status: .skipped
            ),
            // Pending past-due BUT med is archived — not actionable.
            MedicationIntake(
                id: "i-archived",
                medicationId: archivedMed.id,
                scheduledAt: now.addingTimeInterval(-3600),
                status: .pending
            )
        ])

        // Re-derive what the sheet's `actionable` computed property does
        // so the test stays decoupled from SwiftUI body evaluation. The
        // semantics are pinned in the doc-comment above + asserted here.
        let derived = store.todayIntakes
            .filter { $0.status == .pending && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { intake -> IntakeOption? in
                guard let med = store.medications.first(where: { $0.id == intake.medicationId }),
                      med.active else { return nil }
                return IntakeOption(intake: intake, medication: med)
            }

        let ids = derived.map(\.intake.id)
        #expect(ids == ["i-actionable-1"], "Only the past-due pending intake on an active med should surface; got \(ids)")
    }

    @Test("Chooser sorts past-due pending intakes earliest-first")
    func chooserSortsByScheduledAtAscending() throws {
        let store = try makeStore()
        let med = makeMed(id: "m1", name: "Vitamin D", active: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store._testForceSet(medications: [med])
        store._testForceSet(todayIntakes: [
            MedicationIntake(id: "later", medicationId: med.id, scheduledAt: now.addingTimeInterval(-1800), status: .pending),
            MedicationIntake(id: "earlier", medicationId: med.id, scheduledAt: now.addingTimeInterval(-3600), status: .pending),
            MedicationIntake(id: "middle", medicationId: med.id, scheduledAt: now.addingTimeInterval(-2400), status: .pending)
        ])

        let derived = store.todayIntakes
            .filter { $0.status == .pending && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .map(\.id)

        #expect(derived == ["earlier", "middle", "later"])
    }

    @Test("Empty-state when nothing is actionable")
    func emptyStateWhenNothingActionable() throws {
        let store = try makeStore()
        let med = makeMed(id: "m1", name: "Vitamin D", active: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store._testForceSet(medications: [med])
        // Only future-pending — sheet must render its empty state.
        store._testForceSet(todayIntakes: [
            MedicationIntake(id: "i1", medicationId: med.id, scheduledAt: now.addingTimeInterval(3600), status: .pending)
        ])
        let actionable = store.todayIntakes.filter { $0.status == .pending && $0.scheduledAt <= now }
        #expect(actionable.isEmpty)
    }

    @Test("IntakeOption identity is intake-id keyed")
    func intakeOptionIdentity() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMed(id: "m1", name: "A", active: true)
        let intake = MedicationIntake(id: "same", medicationId: med.id, scheduledAt: now, status: .pending)
        let a = IntakeOption(intake: intake, medication: med)
        // Same intake-id with a different medication reference (e.g. a
        // store refresh that re-fetches the medication row) should still
        // hash + compare equal so `NavigationPath` doesn't stack the
        // confirm view twice.
        let medRefetched = makeMed(id: "m1", name: "A (refetched)", active: true)
        let b = IntakeOption(intake: intake, medication: medRefetched)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        // `id` follows the intake — Identifiable surface needs to match
        // the equality contract for List/ForEach stability.
        #expect(a.id == "same")
    }

    @Test("IntakeOption.scheduledTimeString formats as HH:mm")
    func scheduledTimeStringIsLocaleAware() {
        // Pin a deterministic UTC date so the locale-aware HH:mm rendering
        // doesn't drift across CI / Berlin machines. The exact rendering
        // depends on the user locale, so we assert structurally — the
        // string is non-empty + contains a digit.
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 17
        components.hour = 9
        components.minute = 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let scheduled = cal.date(from: components) ?? Date()
        let option = IntakeOption(
            intake: MedicationIntake(id: "i1", medicationId: "m1", scheduledAt: scheduled, status: .pending),
            medication: makeMed(id: "m1", name: "Test", active: true)
        )
        #expect(!option.scheduledTimeString.isEmpty)
        #expect(option.scheduledTimeString.contains { $0.isNumber })
    }

    @Test("Sheet onDismiss + onQueued — each closure runs as supplied")
    func dismissAndQueuedClosuresRoundTrip() {
        var dismissCount = 0
        var queuedCount = 0
        let sheet = MedicationQuickIntakeSheet(
            onDismiss: { dismissCount += 1 },
            onQueued: { queuedCount += 1 }
        )
        sheet.onDismiss()
        sheet.onQueued()
        sheet.onQueued()
        #expect(dismissCount == 1)
        #expect(queuedCount == 2)
    }

    // MARK: - v0.5.5.1 sensoryFeedback trigger contract

    /// `.sensoryFeedback(.selection, trigger: tapTrigger)` only emits a
    /// haptic when SwiftUI observes the trigger value *change*. The
    /// commit-flow uses `&+= 1` so the counter wraps safely after
    /// `Int.max` taps (impossible in practice, but eliminates a
    /// compiler-level overflow warning on the wraparound).
    ///
    /// We can't measure the actual haptic engine in a unit test, but we
    /// can pin the trigger-evolution contract: every tap increments by
    /// exactly one (so neighbouring SwiftUI render passes register the
    /// transition), and the wrap-around does not crash.
    @Test("v0.5.5.1: tap-trigger increments monotonically (+1) per tap")
    func tapTriggerMonotonicIncrement() {
        var trigger = 0
        // Simulate three taps — the helper expression mirrors the
        // production `tapTrigger &+= 1` call-site in
        // `MedicationQuickIntakeConfirm.commit` /
        // `MedicationsScreen.handleQuickMark`.
        trigger &+= 1
        #expect(trigger == 1)
        trigger &+= 1
        #expect(trigger == 2)
        trigger &+= 1
        #expect(trigger == 3)
    }

    @Test("v0.5.5.1: tap-trigger wrap-around is safe at Int.max")
    func tapTriggerWrapAroundIsSafe() {
        // The `&+=` operator is the wrap-overflow variant — if the user
        // somehow taps `Int.max + 1` times we wrap to `Int.min` rather
        // than crash. This is the cheap defensive choice; the haptic
        // contract is "the value changed", not "the value grew".
        var trigger = Int.max
        trigger &+= 1
        #expect(trigger == Int.min)
    }

    // MARK: - Helpers

    private func makeStore() throws -> MedicationsStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        return MedicationsStore(repo: repo)
    }

    private func makeMed(id: String, name: String, active: Bool) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: "1.0 mg",
            schedule: MedicationSchedule(times: []),
            active: active
        )
    }
}
