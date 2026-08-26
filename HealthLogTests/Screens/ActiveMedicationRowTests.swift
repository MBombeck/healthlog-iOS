import Foundation
@testable import HealthLog
import Testing

/// Contract tests for the W-MEDS-VISUAL-IMPL row component (Issue #7).
/// SwiftUI bodies are notoriously awkward to introspect in unit tests,
/// so this suite anchors on the pure presentation logic that the row
/// reads from its inputs — `ActiveMedicationDisplayState.badgeTitle`,
/// `ActiveMedicationsSection.scheduleSummary` and the
/// `ActiveMedicationDisplayState.from(medication:)` mapping. A change
/// to the SwiftUI body cannot regress the contract without one of these
/// derivations also moving.
@Suite("ActiveMedicationRow — display-state contract")
struct ActiveMedicationRowDisplayStateTests {
    private static var medicationCardSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Screens/Medications/ActiveMedicationRow.swift")
    }

    @Test("Aktiv state suppresses the badge title (chip not rendered)")
    func aktivHasNoBadge() {
        let state = ActiveMedicationDisplayState.aktiv
        #expect(state.badgeTitle == nil, "Aktiv is implicit — no chip should render")
    }

    @Test("Pausiert state surfaces the localised Pausiert badge title")
    func pausiertHasBadge() {
        let state = ActiveMedicationDisplayState.pausiert
        #expect(state.badgeTitle == "Pausiert")
    }

    @Test("Beendet state surfaces the localised Beendet badge title")
    func beendetHasBadge() {
        let state = ActiveMedicationDisplayState.beendet
        #expect(state.badgeTitle == "Beendet")
    }

    @Test("`from(medication:)` collapses active=true to .aktiv (no chip)")
    func activeMedicationCollapsesToAktiv() {
        let med = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: []),
            active: true
        )
        #expect(ActiveMedicationDisplayState.from(medication: med) == .aktiv)
        #expect(ActiveMedicationDisplayState.from(medication: med).badgeTitle == nil)
    }

    @Test("`from(medication:)` maps active=false to .beendet (chip renders)")
    func archivedMedicationMapsToBeendet() {
        let med = Medication(
            id: "med-2",
            name: "Metformin",
            dose: "500 mg",
            schedule: MedicationSchedule(times: []),
            active: false
        )
        #expect(ActiveMedicationDisplayState.from(medication: med) == .beendet)
        #expect(ActiveMedicationDisplayState.from(medication: med).badgeTitle == "Beendet")
    }

    @Test("Category and overdue state share one adaptive accessibility-ordered row")
    func categoryAndOverdueShareAdaptiveRow() throws {
        let source = try String(contentsOf: Self.medicationCardSource, encoding: .utf8)

        #expect(source.contains("categoryStatusRow(windowStatus: status)"))
        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains("accessibilityCategoryStatusLabel"))
        #expect(!source.contains("categoryPill\n                    // v0.11 #24"))
    }
}

@Suite("ActiveMedicationsSection — schedule preview formatting")
struct ActiveMedicationsSectionScheduleTests {
    @Test("Single scheduled time renders as 'HH:mm' without separator")
    func singleTime() {
        let schedule = MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        #expect(ActiveMedicationsSection.scheduleSummary(schedule) == "08:00")
    }

    @Test("Multiple times join with the brief's `·` separator")
    func multipleTimesUseMiddotSeparator() {
        let schedule = MedicationSchedule(times: [
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 20, minute: 0)
        ])
        #expect(ActiveMedicationsSection.scheduleSummary(schedule) == "08:00 · 20:00")
    }

    @Test("Times are sorted ascending regardless of input order")
    func timesSortedAscending() {
        let schedule = MedicationSchedule(times: [
            TimeOfDay(hour: 22, minute: 30),
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 13, minute: 15)
        ])
        #expect(ActiveMedicationsSection.scheduleSummary(schedule) == "08:00 · 13:15 · 22:30")
    }

    @Test("Empty schedule yields an empty string (no separator artefacts)")
    func emptyScheduleYieldsEmptyString() {
        let schedule = MedicationSchedule(times: [])
        #expect(ActiveMedicationsSection.scheduleSummary(schedule).isEmpty)
    }
}
