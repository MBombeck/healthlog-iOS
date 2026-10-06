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
                    let start = startsOn ?? Self.today()
                    startsOn = start
                    endsOn = start
                }
            }

        DatePicker(
            "med.schedule.course.startsOn",
            selection: startsBinding,
            displayedComponents: [.date]
        )
        // #115 1.5 — course days are UTC-midnight day anchors; show them in UTC
        // so the picker names the stored day on every device zone.
        .environment(\.timeZone, Self.anchorTimeZone)
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
                .environment(\.timeZone, Self.anchorTimeZone)
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
            get: { startsOn ?? Self.today() },
            set: { startsOn = Self.normalized($0) }
        )
    }

    private var endsBinding: Binding<Date> {
        Binding(
            get: { endsOn ?? startsOn ?? Self.today() },
            set: { endsOn = Self.normalized($0) }
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
                    endsOn = startsOn ?? Self.today()
                }
            }
        )
    }

    // MARK: - #115 1.5 — course days as day anchors

    /// Course `startsOn`/`endsOn` arrive as server `YYYY-MM-DD` decoded to UTC
    /// midnight (`JSONDecoder.hlDefault`). The row keeps that one
    /// representation for everything it holds, reads and writes: the pickers
    /// run in UTC, a pick is normalised to its UTC midnight, and the save path
    /// serialises with ``MedicationCadenceLogic/courseDay(_:)``. Before, the
    /// row mixed device-local midnights with UTC anchors: west of UTC an
    /// untouched stored start showed — and on a schedule save was re-sent as —
    /// the day before.
    nonisolated static let anchorTimeZone: TimeZone = ProfileDay.utcCalendar.timeZone

    /// "Today" for a new course: the ACCOUNT's today (the day the server's
    /// recurrence counts from), as a day anchor.
    nonisolated static func today(now: Date = .now, timeZone: TimeZone = ProfileDay.timeZone) -> Date {
        ProfileDay.anchor(for: now, timeZone: timeZone)
    }

    /// A picked date (the UTC picker hands back an instant inside the chosen
    /// UTC day) → that day's anchor.
    nonisolated static func normalized(_ picked: Date) -> Date {
        ProfileDay.utcCalendar.startOfDay(for: picked)
    }

    private var isRangeValid: Bool {
        guard let startsOn, let endsOn else { return true }
        return endsOn >= startsOn
    }
}
