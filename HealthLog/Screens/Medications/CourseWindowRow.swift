import SwiftUI

/// v0.10 R1 §3.7 — course-window editor. Mirrors the web oracle
/// (`src/components/medications/scheduling/CourseWindowRow.tsx`): a `startsOn`
/// date picker, an `endsOn` date picker gated by a "No end date" toggle, and
/// the `oneShot` toggle. One-shot forces `endsOn == startsOn` and hides the end
/// picker (the cadence picker hides its recurrence rows separately).
///
/// `Form`-friendly: the caller wraps it in a `Section`. Validation
/// (`endsOn ≥ startsOn`) is surfaced inline; the save invariant is enforced by
/// `MedicationCadenceLogic.isCadenceValid`.
struct CourseWindowRow: View {
    @Binding var startsOn: Date?
    @Binding var endsOn: Date?
    @Binding var isOneShot: Bool

    var body: some View {
        Toggle("med.schedule.course.oneShot.toggle", isOn: $isOneShot)
            .onChange(of: isOneShot) { _, oneShot in
                if oneShot {
                    // One-shot requires a start date; default to today, and
                    // collapse the window to a single day.
                    let start = startsOn ?? Calendar.current.startOfDay(for: .now)
                    startsOn = start
                    endsOn = start
                }
            }

        DatePicker(
            "med.schedule.course.startsOn",
            selection: startsBinding,
            displayedComponents: [.date]
        )
        .onChange(of: startsOn) { _, newStart in
            // Keep the one-shot end pinned to the start date.
            if isOneShot, let newStart { endsOn = newStart }
        }

        if !isOneShot {
            Toggle("med.schedule.course.noEndDate", isOn: noEndBinding)
            if endsOn != nil {
                DatePicker(
                    "med.schedule.course.endsOn",
                    selection: endsBinding,
                    displayedComponents: [.date]
                )
                if !isRangeValid {
                    HLFormErrorText(String(localized: "med.schedule.course.invalidRange"))
                        .font(.hlCaption)
                }
            }
        } else {
            Text("med.schedule.course.oneShot.caption")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
    }

    // MARK: - Bindings

    /// `startsOn` defaults to today when the user first touches the picker, so
    /// the wheel never renders empty. A nil start means "active from creation"
    /// (the server's implicit default); touching the picker sets it.
    private var startsBinding: Binding<Date> {
        Binding(
            get: { startsOn ?? Calendar.current.startOfDay(for: .now) },
            set: { startsOn = Calendar.current.startOfDay(for: $0) }
        )
    }

    private var endsBinding: Binding<Date> {
        Binding(
            get: { endsOn ?? startsOn ?? Calendar.current.startOfDay(for: .now) },
            set: { endsOn = Calendar.current.startOfDay(for: $0) }
        )
    }

    /// "No end date" ON ⇔ `endsOn == nil`. Turning it OFF seeds `endsOn` from
    /// the start date so the date picker has a value to show.
    private var noEndBinding: Binding<Bool> {
        Binding(
            get: { endsOn == nil },
            set: { noEnd in
                if noEnd {
                    endsOn = nil
                } else {
                    endsOn = startsOn ?? Calendar.current.startOfDay(for: .now)
                }
            }
        )
    }

    private var isRangeValid: Bool {
        guard let startsOn, let endsOn else { return true }
        return endsOn >= startsOn
    }
}
