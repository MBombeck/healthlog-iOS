import SwiftUI

/// v0.10 R1 §3.7 — the medication cadence picker. Mirrors the web oracle
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
        Picker("med.schedule.cadence.label", selection: $kind) {
            ForEach(CadenceKind.allCases) { kind in
                Text(Self.kindLabelKey(kind)).tag(kind)
            }
        }
        subControls
    }

    // MARK: - Conditional sub-controls

    @ViewBuilder
    private var subControls: some View {
        switch kind {
        case .daily:
            EmptyView()
        case .weekdays:
            CadenceWeekdayChips(selection: $sub.weekdays)
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
                "med.schedule.cadence.yearly.date.label",
                selection: $sub.yearlyDate,
                displayedComponents: [.date]
            )
        case .rolling:
            HLIntStepperRow(
                titleKey: "med.schedule.cadence.rollingDays.label",
                value: $sub.rollingDays,
                range: 1 ... 365,
                unitKey: "med.schedule.cadence.rollingDays.suffix"
            )
            explainer("med.schedule.cadence.rolling.explainer")
            preview(Text("med.schedule.cadence.rolling.preview \(sub.rollingDays)"))
        case .cyclic:
            // 09-14 — the anchor DatePicker that used to sit here is gone. It
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
            explainer("med.schedule.cadence.cyclic.explainer")
            preview(Text("med.schedule.cadence.cyclic.preview \(sub.cyclicOnWeeks) \(sub.cyclicOffWeeks)"))
        case .oneShot:
            explainer("med.schedule.course.oneShot.caption")
        case .asNeeded:
            explainer("med.schedule.cadence.asNeeded.explainer")
        }
    }

    private func explainer(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
    }

    /// Live cadence preview — rendered with the monochrome tertiary text so it
    /// reads as a calm hint, never a status signal (design doctrine: colour =
    /// signal only).
    private func preview(_ text: Text) -> some View {
        text
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
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
/// layout). Selected chips use `.tint`; unselected stay on the monochrome
/// surface. Mirrors the web `WeekdayChips` (`CadencePicker.tsx`) + the existing
/// `WeekdayPicker` chip style so the two add/edit surfaces never drift.
struct CadenceWeekdayChips: View {
    @Binding var selection: Set<Weekday>

    private static let order: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Self.order, id: \.rawValue) { day in
                Button {
                    toggle(day)
                } label: {
                    Text(Self.shortKey(day))
                        .font(.hlMetric(.subheadline))
                        // 44 pt min tap target (HIG / WCAG 2.5.5) — matches the
                        // web oracle's `h-11` chip height.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: HLRadius.xs)
                                .fill(selection.contains(day)
                                    ? AnyShapeStyle(.tint.opacity(0.18))
                                    : AnyShapeStyle(HLColor.surface))
                        )
                        .foregroundStyle(selection.contains(day)
                            ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(HLText.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Self.longKey(day)))
                .accessibilityAddTraits(selection.contains(day) ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("med.schedule.weekday.group.label"))
    }

    private func toggle(_ day: Weekday) {
        if selection.contains(day) {
            // Keep at least one weekday selected (mirror server: BYDAY ≥ 1).
            if selection.count > 1 { selection.remove(day) }
        } else {
            selection.insert(day)
        }
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
                Text(titleKey)
                Spacer()
                valueText
                    .font(.hlMetric(.subheadline))
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if let unitKey {
            Text("\(value) ") + Text(unitKey)
        } else {
            Text("\(value)")
        }
    }
}
