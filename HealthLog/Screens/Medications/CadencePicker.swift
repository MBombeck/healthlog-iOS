import SwiftUI

/// The medication cadence picker. Mirrors the web oracle
/// (`src/components/medications/scheduling/CadencePicker.tsx`): one kind picker
/// driving conditional sub-controls (weekday chips, interval steppers,
/// day-of-month, yearly date, rolling-days, cyclic on/off weeks + anchor). The
/// rolling + cyclic rows carry explainers + live previews — they are the
/// headline features of this release.
///
/// Designed to live inside a `Form`: the caller wraps it in `Section`s. The
/// view is stateless over its `@Binding`s — the parent owns `kind` + `sub` so
/// the picker remembers sub-control input across kind switches (the web
/// component's `subControls` contract).
struct CadencePicker: View {
    @Binding var kind: CadenceKind
    @Binding var sub: CadenceSubControls

    var body: some View {
        // The weekday chips belong to "How often" and share its row, so no
        // row gap opens between the question and its answer.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Picker(selection: $kind) {
                ForEach(CadenceKind.allCases) { kind in
                    Text(Self.kindLabelKey(kind)).tag(kind)
                }
            } label: {
                HLRowTitle("med.schedule.cadence.label")
            }
            if kind == .weekdays {
                CadenceWeekdayChips(selection: $sub.weekdays)
            }
        }
        subControls
    }

    // MARK: - Conditional sub-controls

    @ViewBuilder
    private var subControls: some View {
        switch kind {
        case .daily, .weekdays:
            EmptyView()
        case .everyNWeeks:
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.intervalWeeks.label",
                value: $sub.intervalWeeks,
                range: 1 ... 52,
                unitKey: "med.schedule.cadence.intervalWeeks.suffix"
            )
            CadenceWeekdayChips(selection: $sub.weekdays)
        case .monthly:
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.dayOfMonth.label",
                value: $sub.dayOfMonth,
                range: 1 ... 31,
                unitKey: nil
            )
        case .everyNMonths:
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.intervalMonths.label",
                value: $sub.intervalMonths,
                range: 1 ... 12,
                unitKey: "med.schedule.cadence.intervalMonths.suffix"
            )
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.dayOfMonth.label",
                value: $sub.dayOfMonth,
                range: 1 ... 31,
                unitKey: nil
            )
        case .yearly:
            DatePicker(
                selection: $sub.yearlyDate,
                displayedComponents: [.date]
            ) {
                HLRowTitle("med.schedule.cadence.yearly.date.label")
            }
        case .rolling:
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.rollingDays.label",
                value: $sub.rollingDays,
                range: 1 ... 365,
                unitKey: "med.schedule.cadence.rollingDays.suffix"
            )
            // One line: the preview names the count from the last
            // intake, which is what the explainer used to say beside it.
            preview(Text("med.schedule.cadence.rolling.preview \(sub.rollingDays)"))
        case .cyclic:
            // The anchor DatePicker that used to sit here is gone. It
            // wrote to a `cycleAnchor` wire key that appears zero times in the
            // published contract, and it duplicated a control the sheets
            // already show: the cycle is counted from the course start in
            // `CourseWindowRow`, which is the date the server anchors on.
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.cycle.weeksOn.label",
                value: $sub.cyclicOnWeeks,
                range: 1 ... 52,
                unitKey: "med.schedule.cadence.intervalWeeks.suffix"
            )
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.cycle.weeksOff.label",
                value: $sub.cyclicOffWeeks,
                range: 0 ... 52,
                unitKey: "med.schedule.cadence.intervalWeeks.suffix"
            )
            // The steppers show the weeks; the one line left says
            // what the choice does and where the cycle counts from.
            explainer("med.schedule.cadence.cyclic.explainer")
        case .oneShot:
            // The kind's own name says it; no caption repeats it.
            EmptyView()
        case .asNeeded:
            explainer("med.schedule.cadence.asNeeded.explainer")
        }
    }

    private func explainer(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .hlText(.rowSubtitle)
    }

    /// Live cadence preview — rendered with the monochrome tertiary text so it
    /// reads as a calm hint, never a status signal (design doctrine: colour =
    /// signal only).
    private func preview(_ text: Text) -> some View {
        text
            .hlText(.footnote)
    }

    static func kindLabelKey(_ kind: CadenceKind) -> LocalizedStringKey {
        switch kind {
        case .daily: "med.schedule.cadence.kind.daily"
        case .weekdays: "med.schedule.cadence.kind.weekdays"
        case .everyNWeeks: "med.schedule.cadence.kind.everyNWeeks"
        case .monthly: "med.schedule.cadence.kind.monthly"
        case .everyNMonths: "med.schedule.cadence.kind.everyNMonths"
        case .yearly: "med.schedule.cadence.kind.yearly"
        case .rolling: "med.schedule.cadence.kind.rolling"
        case .cyclic: "med.schedule.cadence.kind.cyclic"
        case .oneShot: "med.schedule.cadence.kind.oneShot"
        case .asNeeded: "med.schedule.cadence.kind.asNeeded"
        }
    }
}

// MARK: - Weekday chips

/// Multi-select weekday chip row — Mon→Sun ordering (the wizard's canonical
/// layout). Seven chips share one line evenly; VoiceOver reads the full day
/// for each abbreviation. Mirrors the web `WeekdayChips` (`CadencePicker.tsx`).
struct CadenceWeekdayChips: View {
    @Binding var selection: Set<Weekday>

    static let order: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    var body: some View {
        HLChipRow {
            ForEach(Self.order, id: \.rawValue) { day in
                HLChip(
                    Self.shortKey(day),
                    spokenTitle: Self.longKey(day),
                    isSelected: selection.contains(day)
                ) {
                    selection = Self.toggled(selection, day)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("med.schedule.weekday.group.label"))
    }

    /// The selection after a tap on `day`. The last chosen day stays chosen,
    /// as the server needs at least one (BYDAY ≥ 1).
    static func toggled(_ selection: Set<Weekday>, _ day: Weekday) -> Set<Weekday> {
        var next = selection
        if next.contains(day) {
            if next.count > 1 { next.remove(day) }
        } else {
            next.insert(day)
        }
        return next
    }

    static func shortKey(_ day: Weekday) -> LocalizedStringKey {
        switch day {
        case .mon: "med.schedule.weekday.short.mon"
        case .tue: "med.schedule.weekday.short.tue"
        case .wed: "med.schedule.weekday.short.wed"
        case .thu: "med.schedule.weekday.short.thu"
        case .fri: "med.schedule.weekday.short.fri"
        case .sat: "med.schedule.weekday.short.sat"
        case .sun: "med.schedule.weekday.short.sun"
        }
    }

    static func longKey(_ day: Weekday) -> LocalizedStringKey {
        switch day {
        case .mon: "med.schedule.weekday.long.mon"
        case .tue: "med.schedule.weekday.long.tue"
        case .wed: "med.schedule.weekday.long.wed"
        case .thu: "med.schedule.weekday.long.thu"
        case .fri: "med.schedule.weekday.long.fri"
        case .sat: "med.schedule.weekday.long.sat"
        case .sun: "med.schedule.weekday.long.sun"
        }
    }
}

// MARK: - Integer stepper row

/// A `Form`-friendly integer stepper row: a localized title, the current value
/// (with an optional unit suffix), and a native `Stepper`. Used for the
/// interval / day-of-month / rolling-days / cyclic sub-controls.
struct HLIntStepperRow: View {
    let titleKey: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unitKey: LocalizedStringKey?

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                HLRowTitle(titleKey)
                Spacer()
                valueText
                    .hlText(.factLabel)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if let unitKey {
            Text("\(value) \(Text(unitKey))")
        } else {
            Text("\(value)")
        }
    }
}
