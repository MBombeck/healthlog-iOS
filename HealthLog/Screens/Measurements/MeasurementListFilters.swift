import Foundation
import SwiftUI

/// v0.5.5.1 — pure filter pipeline behind `MeasurementListScreen`. Lives
/// outside the View so unit tests can lock the contract via
/// `MeasurementListFilter.apply(...)` without spinning up a SwiftUI
/// render context.
enum MeasurementListFilter {
    /// Applies the source-chip filter first (cheap O(n) equality scan), then
    /// the search-bar query. The needle matches against:
    ///   - measurement note (existing v0.4.1 behaviour, kept verbatim);
    ///   - source display label so the user can type a provenance keyword
    ///     in the search bar even without picking a chip;
    ///   - recordedAt month/weekday/day in the user's locale so
    ///     date-shaped searches like "Mai" or "Montag" land.
    static func apply(
        _ measurements: [Measurement],
        source: MeasurementSource?,
        query: String,
        valueMin: Double? = nil,
        valueMax: Double? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil
    ) -> [Measurement] {
        // Build 3 / item 3.3 — the date-range slice runs FIRST: it is the
        // cheapest predicate and the one most likely to cut the array down, so
        // every later pass walks fewer rows.
        let measurements = applyDateRange(measurements, from: dateFrom, to: dateTo)
        let sourceFiltered: [Measurement] = if let source {
            measurements.filter { $0.source == source }
        } else {
            measurements
        }
        // v1.18.5 parity — numeric value-range filter. Applied after the
        // source slice and before the search needle so min/max compose with
        // both. A `nil` bound is open-ended; an inverted range (min > max)
        // is normalised so the user never traps themselves in zero results.
        let rangeFiltered = applyValueRange(sourceFiltered, valueMin: valueMin, valueMax: valueMax)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rangeFiltered }
        let needle = trimmed.lowercased()
        return rangeFiltered.filter { measurement in
            if measurement.note?.lowercased().contains(needle) == true { return true }
            if sourceSearchLabel(measurement.source).contains(needle) { return true }
            let dateLabel = measurement.recordedAt
                .formatted(.dateTime.month(.wide).weekday(.wide).day())
                .lowercased()
            return dateLabel.contains(needle)
        }
    }

    /// Filters `measurements` to those whose `value` falls in `[lo, hi]`
    /// (inclusive). `nil` bounds are open-ended; an inverted `valueMin >
    /// valueMax` is swapped so the predicate stays well-formed.
    static func applyValueRange(
        _ measurements: [Measurement],
        valueMin: Double?,
        valueMax: Double?
    ) -> [Measurement] {
        guard valueMin != nil || valueMax != nil else { return measurements }
        var lo = valueMin
        var hi = valueMax
        if let l = lo, let h = hi, l > h { swap(&lo, &hi) }
        return measurements.filter { measurement in
            // BP rows compare on the systolic component (`primaryComponent`),
            // mirroring the server which filters BP on the systolic column.
            let v = measurement.value.primaryComponent
            // A non-finite value (NaN/±inf) compares false against every bound,
            // so it would otherwise SLIP THROUGH an active range as if it
            // matched. Exclude it when any bound is active (QA Correctness-L-2).
            guard v.isFinite else { return false }
            if let lo, v < lo { return false }
            if let hi, v > hi { return false }
            return true
        }
    }

    /// Build 3 / item 3.3 — filters `measurements` to those recorded within
    /// `[from, to]`. Web parity: `measurement-list.tsx:328-329, 456-458` sends
    /// `from` / `to` query params; iOS had NO date filter at all, on any
    /// surface.
    ///
    /// Both bounds are optional and open-ended when `nil`. **The bounds are
    /// snapped to DAY boundaries** — `from` to the start of its day, `to` to the
    /// END of its day — because the picker asks for a date, not an instant. A
    /// user who sets "to = today" means "including everything today", and a raw
    /// `<= now` comparison would silently hide this afternoon's readings.
    ///
    /// An inverted range (`from > to`) is swapped rather than returning zero
    /// rows, mirroring ``applyValueRange`` so the user never traps themselves.
    static func applyDateRange(
        _ measurements: [Measurement],
        from: Date?,
        to: Date?,
        calendar: Calendar = .current
    ) -> [Measurement] {
        guard from != nil || to != nil else { return measurements }
        var lo = from
        var hi = to
        if let l = lo, let h = hi, l > h { swap(&lo, &hi) }
        let lowerBound = lo.map { calendar.startOfDay(for: $0) }
        let upperBound = hi.flatMap { day -> Date? in
            let start = calendar.startOfDay(for: day)
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        return measurements.filter { measurement in
            let at = measurement.recordedAt
            if let lowerBound, at < lowerBound { return false }
            // Exclusive upper bound == start of the day AFTER `to`, i.e. the
            // whole of `to` is included.
            if let upperBound, at >= upperBound { return false }
            return true
        }
    }

    /// Distinct sources actually present in `measurements`, ordered as
    /// `appleHealth → withings → whoop → fitbit → manual → import_`. The
    /// deduplication keeps the chip row narrow on the 393pt iPhone canvas;
    /// only sources with ≥1 loaded row surface as chips, so WHOOP/Fitbit
    /// appear once their first measurement lands (A4 MEDIUM #2 parity seed).
    static func availableSources(in measurements: [Measurement]) -> [MeasurementSource] {
        // Build 3 / item 3.3 — `.computed` was MISSING from this order list even
        // though `SourceFilterChips.label(for:)` and `sourceSearchLabel` both
        // already knew it. The effect: server-derived rows (the screener sum
        // scores since v1.27.6) could be searched for by name but never
        // filtered by chip, because a chip is only offered for a source in this
        // array. Placed after the device providers and before `.manual` so the
        // row reads device-ingest → derived → hand-entered.
        let canonical: [MeasurementSource] = [
            .appleHealth, .withings, .whoop, .fitbit, .googleHealth,
            .strava, .oura, .polar, .nightscout, .computed, .manual, .import_
        ]
        var seen = Set<MeasurementSource>()
        var ordered: [MeasurementSource] = []
        for source in canonical
            where measurements.contains(where: { $0.source == source }) && seen.insert(source).inserted
        {
            ordered.append(source)
        }
        return ordered
    }

    /// Lowercased search-aliases per source — the search-bar needle is
    /// compared against these so the user can type "apple", "withings",
    /// "manuell" or "import" without picking a chip.
    private static func sourceSearchLabel(_ source: MeasurementSource) -> String {
        switch source {
        case .appleHealth: "apple health"
        case .withings: "withings"
        case .whoop: "whoop"
        case .fitbit: "fitbit"
        case .googleHealth: "google health"
        case .strava: "strava"
        case .oura: "oura"
        case .polar: "polar"
        case .nightscout: "nightscout"
        case .manual: "manuell"
        case .computed: "computed berechnet"
        case .import_: "import"
        }
    }
}

// v0.5.5.1 — measurement-list filter affordances. Extracted from
// `MeasurementListScreen.swift` so the screen stays under the 600-line
// SwiftLint `file_length` baseline.
//
// Two surfaces:
// 1. `SourceFilterChips` — horizontal chip row for the per-source
//    filter ("Alle" + one chip per source present in the loaded
//    measurements). Apple-Health pattern for drill-down filter rows.
// 2. `NoMatchesState` — humane copy when the active filter + search
//    query produce zero rows. Distinct from the "no data at all"
//    `EmptyState` so the operator knows data is present, they just
//    need to widen the filter / clear the search.

struct SourceFilterChips: View {
    let available: [MeasurementSource]
    @Binding var selection: MeasurementSource?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.xs) {
                Chip(
                    label: String(localized: "All"),
                    isSelected: selection == nil
                ) { selection = nil }
                ForEach(available, id: \.self) { source in
                    Chip(
                        label: Self.label(for: source),
                        isSelected: selection == source
                    ) {
                        selection = selection == source ? nil : source
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Compact source label (distinct from the long-form "Manuelle
    /// Eingabe" used in the per-row badge) so the chip-row stays narrow
    /// enough to fit four entries on a 393pt iPhone width.
    static func label(for source: MeasurementSource) -> String {
        switch source {
        case .appleHealth: String(localized: "Apple Health")
        case .withings: String(localized: "Withings")
        case .whoop: String(localized: "WHOOP")
        case .fitbit: String(localized: "Fitbit")
        case .googleHealth: String(localized: "Google Health")
        case .strava: String(localized: "Strava")
        case .oura: String(localized: "Oura")
        case .polar: String(localized: "Polar")
        case .nightscout: String(localized: "Nightscout")
        case .manual: String(localized: "Manual")
        case .computed: String(localized: "measurement.source.computed")
        case .import_: String(localized: "Import")
        }
    }

    private struct Chip: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.hlCaption.weight(.semibold))
                    // FW1-C (M6): the selected-pill label now uses the canonical
                    // inverted-label token `HLSurface.primary` (the tab-strip's
                    // solution, InsightsMetricTabStrip) instead of raw `Color
                    // .white`, so the app has a single selected-pill vocabulary.
                    .foregroundStyle(isSelected ? HLSurface.primary : HLText.secondary)
                    .padding(.horizontal, HLSpace.md)
                    .padding(.vertical, HLSpace.xs)
                    .background(
                        Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLColor.surface))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// v1.18.5 parity — collapsible numeric value-range filter. Collapsed it is
/// a single disclosure row ("Value range"); expanded it reveals min + max
/// decimal fields with the metric unit suffix and a Clear button. Mirrors
/// web's measurement-list value-range control. Bounds are bound as text so
/// partial input never traps the field; the screen parses them at filter
/// time and the predicate normalises an inverted range.
struct ValueRangeFilterControl: View {
    @Binding var isExpanded: Bool
    @Binding var minText: String
    @Binding var maxText: String
    let unit: String

    @State private var clearTick = false
    @FocusState private var focusedField: Field?

    /// A11Y (audit-v0162 §5) — gates the disclosure expand/collapse animation so
    /// it snaps instead of sliding when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The two numeric fields, so the keyboard "Done" toolbar can dismiss
    /// whichever decimal-pad field is up (decimalPad has no return key).
    private enum Field { case min, max }

    private var isActive: Bool {
        !minText.trimmingCharacters(in: .whitespaces).isEmpty
            || !maxText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A360-5 H-4 — a bound the user typed that can't be parsed (e.g. "abc",
    /// "1.2.3"). Surfacing it stops the range filter from silently doing nothing
    /// on bad input. A blank field is not "invalid" — it's just open-ended.
    private func isUnparseable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && LocaleDecimalParser.parse(trimmed) == nil
    }

    private var hasInvalidBound: Bool {
        isUnparseable(minText) || isUnparseable(maxText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Button {
                withAnimation(reduceMotion ? nil : .default) { isExpanded.toggle() }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Value range")
                    if isActive {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.secondary))
            }
            .hlPressable()
            .accessibilityIdentifier("measurements.list.valueRange.toggle")

            if isExpanded {
                HStack(spacing: HLSpace.sm) {
                    field(prompt: String(localized: "Min"), text: $minText)
                        .focused($focusedField, equals: .min)
                        .accessibilityIdentifier("measurements.list.valueRange.min")
                    Text("–").foregroundStyle(HLText.secondary)
                    field(prompt: String(localized: "Max"), text: $maxText)
                        .focused($focusedField, equals: .max)
                        .accessibilityIdentifier("measurements.list.valueRange.max")
                    if !unit.isEmpty {
                        Text(unit).font(.hlCaption).foregroundStyle(HLText.secondary)
                    }
                    if isActive {
                        Button {
                            minText = ""
                            maxText = ""
                            clearTick.toggle()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(HLText.tertiary)
                        }
                        .hlPressable()
                        .accessibilityLabel(Text("Clear value range"))
                    }
                }
                if hasInvalidBound {
                    Text("measurements.list.valueRange.invalid")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("measurements.list.valueRange.invalid")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: clearTick)
        .toolbar {
            // decimalPad has no return key — give the user an explicit dismiss
            // so they're never trapped behind the keyboard (QA-b198 Design-M3).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { focusedField = nil }
            }
        }
    }

    private func field(prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.decimalPad)
            .font(.hlBody)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 96)
            .padding(.vertical, HLSpace.xs)
            .padding(.horizontal, HLSpace.sm)
            .background(Capsule().fill(HLColor.surface))
    }
}

/// Build 3 / item 3.3 — collapsible date-range filter (from / to). Mirrors
/// ``ValueRangeFilterControl`` exactly so the two filter rows share one
/// vocabulary: a disclosure row with an active dot, an expanded body, and a
/// clear button that only appears once a bound is set.
///
/// Web parity: `measurement-list.tsx:328-329` (`from` / `to` inputs). Both
/// bounds are OPTIONAL and independently clearable — the common real use is
/// "everything since my last check-up", which sets only `from`.
struct DateRangeFilterControl: View {
    @Binding var isExpanded: Bool
    @Binding var from: Date?
    @Binding var to: Date?

    @State private var clearTick = false

    /// A11Y — gates the disclosure animation so it snaps under Reduce Motion,
    /// matching `ValueRangeFilterControl`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool {
        from != nil || to != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Button {
                withAnimation(reduceMotion ? nil : .default) { isExpanded.toggle() }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "calendar")
                    Text("measurements.list.dateRange.label")
                    if isActive {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.secondary))
            }
            .hlPressable()
            .accessibilityIdentifier("measurements.list.dateRange.toggle")

            if isExpanded {
                bound(
                    label: "measurements.list.dateRange.from",
                    date: $from,
                    identifier: "measurements.list.dateRange.from"
                )
                bound(
                    label: "measurements.list.dateRange.to",
                    date: $to,
                    identifier: "measurements.list.dateRange.to"
                )
                if isActive {
                    Button {
                        from = nil
                        to = nil
                        clearTick.toggle()
                    } label: {
                        Label {
                            Text("measurements.list.dateRange.clear")
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    }
                    .hlPressable()
                    .accessibilityIdentifier("measurements.list.dateRange.clear")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: clearTick)
    }

    /// One optional bound. A `nil` bound renders as a "set a date" button rather
    /// than a DatePicker prefilled with today — prefilling would make an
    /// INACTIVE bound look active and quietly narrow the list.
    @ViewBuilder
    private func bound(label: LocalizedStringKey, date: Binding<Date?>, identifier: String) -> some View {
        if let value = date.wrappedValue {
            HStack(spacing: HLSpace.sm) {
                DatePicker(
                    label,
                    selection: Binding(get: { value }, set: { date.wrappedValue = $0 }),
                    displayedComponents: [.date]
                )
                .font(.hlCaption)
                Button {
                    date.wrappedValue = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HLText.tertiary)
                }
                .hlPressable()
                .accessibilityLabel(Text("measurements.list.dateRange.clearBound"))
            }
            .accessibilityIdentifier(identifier)
        } else {
            Button {
                date.wrappedValue = .now
            } label: {
                HStack {
                    Text(label)
                    Spacer()
                    Text("measurements.list.dateRange.unset")
                        .foregroundStyle(HLText.tertiary)
                }
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            }
            .hlPressable()
            .accessibilityIdentifier(identifier)
        }
    }
}

struct NoMatchesState: View {
    /// Audit-01 C1 — the canonical `HLEmptyState` lockup, matching every other
    /// empty surface app-wide.
    var body: some View {
        HLEmptyState(
            icon: "magnifyingglass",
            title: "No matches",
            message: "Adjust the filters or search to see measurements."
        )
        .accessibilityIdentifier("measurements.list.noMatches")
    }
}
