import Foundation
@testable import HealthLog
import Testing

/// Opening the medication editor and changing nothing leaves nothing to
/// discard: the prefill already follows the cadence picker's rules, so the
/// change handler that runs after it finds nothing to trim.
@Suite("Edit medication opens unchanged")
struct EditMedicationOpenStateTests {
    private func prnWithGrace() -> Medication {
        Medication(
            id: "srv-prn",
            name: "Naproxen",
            dose: "400 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .asNeeded,
                timesOfDay: [],
                reminderGraceMinutes: 45,
                windowStart: TimeOfDay(hour: 8, minute: 0)
            )])
        )
    }

    @Test("A PRN medication with a stored grace opens with no times and grace off")
    func prnOpensConstrained() {
        let state = EditMedicationFormState(from: prnWithGrace())
        #expect(state.cadenceKind == .asNeeded)
        #expect(state.editorTimes.isEmpty)
        #expect(state.editorGraceEnabled == false)
    }

    @Test("The picker's rule finds nothing to change after the prefill")
    func prefillIsAlreadyConstrained() {
        let state = EditMedicationFormState(from: prnWithGrace())
        let afterRule = EditMedicationFormState.constrainedTimes(state.editorTimes, kind: state.cadenceKind)
        #expect(afterRule == state.editorTimes, "opening must not read as an edit")
    }

    @Test("A daily medication keeps its times and grace")
    func dailyKeepsEverything() {
        let medication = Medication(
            id: "srv-daily",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)],
                reminderGraceMinutes: 30,
                windowStart: TimeOfDay(hour: 8, minute: 0)
            )])
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.editorTimes.count == 2)
        #expect(state.editorGraceEnabled)
    }
}
