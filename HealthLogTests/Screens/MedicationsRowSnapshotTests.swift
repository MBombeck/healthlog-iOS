import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// **v0.5.5.1** snapshot lock for the `MedicationQuickMarkButton` and
/// `ActiveMedicationRow` presentation contracts. SwiftUI bodies are
/// intentionally not introspected — instead we snapshot the pure-state
/// descriptors that feed the view's render path. The button's body
/// reads from `MedicationQuickMarkState.presentationDescriptor()`; the
/// row composes `ActiveMedicationDisplayState.badgeTitle` plus the
/// schedule projection. A regression in either contract surfaces as a
/// snapshot diff, even if the View body changes shape underneath.
///
/// The dump-of-value style matches `AchievementDetailSheetTests` (and
/// the rest of the design-system snapshot suite). Pixel-level snapshots
/// are intentionally avoided: SDK version drift produces noise that
/// hides real regressions.
@Suite("MedicationQuickMarkButton + ActiveMedicationRow snapshots")
struct MedicationsRowSnapshotTests {
    // MARK: - Quick-mark button — four state snapshots

    /// `.actionable(intakeId:)` — visual 32pt chip + 44pt HIG hit-target
    /// + outline circle symbol + actionable tap-hint. The brief calls
    /// out this combination explicitly: the hit-target widens past the
    /// visual edge ONLY in this state (W-UX2 phantom-44pt contract).
    @Test("Snapshot — quick-mark button .actionable (visual 32pt, hit 44pt)")
    func actionableStateSnapshot() {
        let descriptor = MedicationQuickMarkState.actionable(intakeId: "i-1")
            .presentationDescriptor()
        assertSnapshot(
            of: dump(of: descriptor),
            as: .lines,
            named: "quick-mark-actionable"
        )
        // Pin the W-UX2 contract numerically so a refactor that moves
        // the constants triggers two failures (snapshot + assertion)
        // instead of a silent shift.
        #expect(descriptor.visualSize == 32.0)
        #expect(descriptor.hitTarget == 44.0)
        #expect(descriptor.isActionable)
    }

    /// `.notScheduledToday` — visual chip stays 32pt (no phantom inset),
    /// hit-target collapses to the same 32pt, symbol is hidden.
    @Test("Snapshot — quick-mark button .notScheduledToday (visual 32pt, hit 32pt)")
    func notScheduledTodayStateSnapshot() {
        let descriptor = MedicationQuickMarkState.notScheduledToday
            .presentationDescriptor()
        assertSnapshot(
            of: dump(of: descriptor),
            as: .lines,
            named: "quick-mark-not-scheduled-today"
        )
        // W-UX2: phantom-44pt collapse — non-actionable states never
        // widen past the 32pt visual chip.
        #expect(descriptor.visualSize == 32.0)
        #expect(descriptor.hitTarget == 32.0)
        #expect(descriptor.isSymbolHidden)
        #expect(!descriptor.isActionable)
    }

    /// `.takenToday` — filled-check symbol, 32pt collapsed hit-target,
    /// disabled (operator has already logged today's dose).
    @Test("Snapshot — quick-mark button .takenToday (visual 32pt, hit 32pt)")
    func takenTodayStateSnapshot() {
        let descriptor = MedicationQuickMarkState.takenToday
            .presentationDescriptor()
        assertSnapshot(
            of: dump(of: descriptor),
            as: .lines,
            named: "quick-mark-taken-today"
        )
        #expect(descriptor.symbolName == "checkmark.circle.fill")
        #expect(descriptor.hitTarget == 32.0)
        #expect(descriptor.isDisabled)
    }

    /// `.upcoming` — dotted-outline circle, 32pt collapsed hit-target,
    /// the "not yet" feedback the operator learns without copy.
    @Test("Snapshot — quick-mark button .upcoming (visual 32pt, hit 32pt)")
    func upcomingStateSnapshot() {
        let descriptor = MedicationQuickMarkState.upcoming
            .presentationDescriptor()
        assertSnapshot(
            of: dump(of: descriptor),
            as: .lines,
            named: "quick-mark-upcoming"
        )
        #expect(descriptor.symbolName == "circle.dotted")
        #expect(descriptor.hitTarget == 32.0)
        #expect(descriptor.isDisabled)
    }

    // MARK: - Active-medication row — state-chip rendering snapshots

    /// `.aktiv` — implicit baseline; chip is suppressed.
    @Test("Snapshot — active medication row .aktiv (no chip rendered)")
    func aktivRowSnapshot() {
        let snapshot = ActiveMedicationRowSnapshot(
            medication: Self.makeMedication(id: "m1", name: "Lisinopril", active: true),
            displayState: .aktiv
        )
        assertSnapshot(
            of: dump(of: snapshot),
            as: .lines,
            named: "row-aktiv-no-chip"
        )
        #expect(snapshot.displayState.badgeTitle == nil)
    }

    /// `.pausiert` — non-baseline lifecycle; localized "Pausiert" chip
    /// surfaces. (Currently the model has no Pausiert wire-state; the
    /// enum case + chip render contract are pinned here so the future
    /// server-side roll-out has a stable iOS landing zone.)
    @Test("Snapshot — active medication row .pausiert (chip visible)")
    func pausiertRowSnapshot() {
        let snapshot = ActiveMedicationRowSnapshot(
            medication: Self.makeMedication(id: "m2", name: "Pantoprazol", active: true),
            displayState: .pausiert
        )
        assertSnapshot(
            of: dump(of: snapshot),
            as: .lines,
            named: "row-pausiert-chip"
        )
        #expect(snapshot.displayState.badgeTitle == "Pausiert")
    }

    /// `.beendet` — archived rows (active=false) collapse here on the
    /// row's surface; chip surfaces the localized "Beendet" label.
    @Test("Snapshot — active medication row .beendet (chip visible)")
    func beendetRowSnapshot() {
        let snapshot = ActiveMedicationRowSnapshot(
            medication: Self.makeMedication(id: "m3", name: "Metformin", active: false),
            displayState: .beendet
        )
        assertSnapshot(
            of: dump(of: snapshot),
            as: .lines,
            named: "row-beendet-chip"
        )
        #expect(snapshot.displayState.badgeTitle == "Beendet")
    }

    // MARK: - Helpers

    private static func makeMedication(id: String, name: String, active: Bool) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: "5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)]
            ),
            active: active
        )
    }

    private func dump(of value: some Any) -> String {
        var output = ""
        Swift.dump(value, to: &output)
        return output
    }
}

/// Test-only descriptor that captures the inputs `ActiveMedicationRow`
/// renders from. We dump this value (not the View body) so the
/// snapshot stays stable across SDK bumps — `assertSnapshot` over the
/// raw Mirror dump of a SwiftUI view would otherwise pick up internal
/// Apple-private fields that drift between Xcode versions.
///
/// **Not private** because `Swift.dump(_:)` prefixes private nested
/// types with the enclosing-context's memory address (`"(unknown
/// context at $11...)"`) on first use — that address changes between
/// runs and breaks snapshot stability. Module-internal placement keeps
/// the dump deterministic without exposing the helper to non-test
/// targets (the entire file lives under `HealthLogTests`).
struct ActiveMedicationRowSnapshot {
    let medication: Medication
    let displayState: ActiveMedicationDisplayState

    var scheduleSummary: String {
        ActiveMedicationsSection.scheduleSummary(medication.schedule)
    }

    var badgeTitle: String? {
        displayState.badgeTitle
    }
}
