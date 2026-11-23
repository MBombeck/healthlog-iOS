import SwiftUI

/// A past course: correct its first and
/// last day, or delete it.
///
/// Pushed on the medication page's own navigation stack instead of presented
/// as a sheet: the frozen privacy census of presentations admits no new
/// presenter (`validate-phase06-presentation-inventory.sh`), and a pushed page
/// needs none. The delete question is asked in place for the same reason (as
/// on the symptom page). The days are calendar days anchored at UTC midnight,
/// so the pickers run in UTC and name the stored day in every device zone.
struct MedicationCourseEditPage: View {
    let course: MedicationCourse
    let model: MedicationCoursesModel

    @Environment(\.dismiss) private var dismiss
    @State private var startsOn: Date
    @State private var endsOn: Date
    @State private var isWorking = false
    @State private var errorText: String?

    init(course: MedicationCourse, model: MedicationCoursesModel) {
        self.course = course
        self.model = model
        let start = course.startDay ?? CourseWindowRow.today()
        _startsOn = State(initialValue: start)
        _endsOn = State(initialValue: course.endDay ?? start)
    }

    var body: some View {
        Form {
            Section {
                DatePicker(selection: $startsOn, displayedComponents: [.date]) {
                    HLRowTitle("med.schedule.course.startsOn")
                }
                .environment(\.timeZone, CourseWindowRow.anchorTimeZone)
                .accessibilityIdentifier("med.courses.edit.startsOn")
                DatePicker(selection: $endsOn, displayedComponents: [.date]) {
                    HLRowTitle("med.schedule.course.endsOn")
                }
                .environment(\.timeZone, CourseWindowRow.anchorTimeZone)
                .accessibilityIdentifier("med.courses.edit.endsOn")
                if !Self.isRangeValid(startsOn: startsOn, endsOn: endsOn) {
                    HLFormErrorText(String(localized: "med.schedule.course.invalidRange"))
                        .font(.hlCaption)
                }
            } footer: {
                Text("med.courses.edit.footer")
                    .font(.hlCaption)
            }
            .hlFormRowSurface()
            if let errorText {
                Section { HLFormErrorText(errorText) }
                    .hlFormRowSurface()
            }
            deleteSection
        }
        .hlPageMargins()
        .navigationTitle(Text("med.courses.edit.title"))
        .navigationBarTitleDisplayMode(.inline)
        // A pushed edit page: the check mark in the bar of the stack it is in,
        // the page goes back once the course is saved.
        .hlConfirmBar(.save(isEnabled: canSave) { await save() }, identifier: "med.courses.edit.save")
    }

    private var canSave: Bool {
        !isWorking && Self.isRangeValid(startsOn: startsOn, endsOn: endsOn)
            && Self.body(startsOn: startsOn, endsOn: endsOn) != Self.body(of: course)
    }

    private var deleteSection: some View {
        Section {
            // A course goes for good: the button asks first.
            HLDeleteButton(
                "med.courses.delete.action",
                form: .row,
                action: .confirmed(title: "med.courses.delete.question") { await delete() }
            )
            .disabled(isWorking)
            .accessibilityIdentifier("med.courses.edit.delete")
        }
        .hlFormRowSurface()
    }

    // MARK: - Writes

    /// `true` when the course is saved and the page may go back.
    private func save() async -> Bool {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        let body = Self.body(startsOn: startsOn, endsOn: endsOn)
        do {
            try await model.update(course, startsOn: body.startsOn, endsOn: body.endsOn)
            return true
        } catch {
            errorText = MedicationCoursesModel.message(for: error)
            return false
        }
    }

    private func delete() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await model.delete(course)
            dismiss()
        } catch {
            errorText = MedicationCoursesModel.message(for: error)
        }
    }

    // MARK: - Pure helpers

    nonisolated static func isRangeValid(startsOn: Date, endsOn: Date) -> Bool {
        MedicationCadenceLogic.courseDay(endsOn) >= MedicationCadenceLogic.courseDay(startsOn)
    }

    /// The PATCH body for two picked days (UTC-anchored, see the type note).
    nonisolated static func body(startsOn: Date, endsOn: Date) -> UpdateMedicationCourseBody {
        UpdateMedicationCourseBody(
            startsOn: MedicationCadenceLogic.courseDay(startsOn),
            endsOn: MedicationCadenceLogic.courseDay(endsOn)
        )
    }

    /// The course as served, in the same shape, so an untouched form saves nothing.
    nonisolated static func body(of course: MedicationCourse) -> UpdateMedicationCourseBody {
        UpdateMedicationCourseBody(startsOn: course.startsOn, endsOn: course.endsOn ?? course.startsOn)
    }
}
