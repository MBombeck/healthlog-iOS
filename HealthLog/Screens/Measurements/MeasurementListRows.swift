import SwiftUI

// Row-level subviews extracted from `MeasurementListScreen.swift`
// so the screen file stays under the 600-line SwiftLint `file_length`
// baseline once the multi-select bulk-delete affordances landed. Types are
// unchanged (same module, module-internal access); only the file boundary
// moves — the same mechanical split `MeasurementBucketing.swift` and
// `MeasurementListFilters.swift` went through in v0.5.5.1.

// MARK: - Raw row (per-measurement)

/// One reading as a history row: date and time as the title, source, sleep
/// split and note in the one detail line, the value at the right. A locked
/// (server-derived) reading carries a lock where an editable one has nothing;
/// the reason is one tap away (`MeasurementSwipeRow`).
struct MeasurementRow: View {
    let measurement: Measurement
    /// The date line when the card names the week: the day and the time
    /// ("Heute, 07:30"). `nil` → the full date and time.
    var title: String?
    /// Render the value in the user's chosen unit (matches the
    /// dashboard tile / chrono feed), not the raw canonical value.
    @Environment(\.unitPreferences) private var units

    var body: some View {
        if measurement.isServerDerivedReadOnly {
            HLRow(
                title: dateLine,
                detail: detail,
                value: Text(verbatim: formattedValue),
                accessory: .symbol("lock")
            )
        } else {
            HLHistoryRow(date: dateLine, detail: detail, value: Text(verbatim: formattedValue))
        }
    }

    private var dateLine: Text {
        Text(verbatim: title ?? HLDateFormat.dateTime(measurement.recordedAt))
    }

    // Value formatting lives in the shared
    // `MeasurementChronoModel.formattedValue(_:)` so the chronological feed row
    // and this drill-down row never diverge on a value.
    private var formattedValue: String {
        MeasurementChronoModel.formattedValue(measurement, units: units)
    }

    private var detail: Text? {
        Self.detailLine(for: measurement).map { Text(verbatim: $0) }
    }

    /// Source, the night-and-naps split of a sleep day, the reading's own
    /// clock when it was taken in another zone, and the note, joined into the
    /// row's single detail line.
    static func detailLine(for measurement: Measurement, device: TimeZone = .current) -> String? {
        HLRowDetail.joined([
            measurement.source.measurementRowLabel,
            measurement.sleepSplit?.breakdownLine,
            zoneHint(for: measurement, device: device),
            measurement.note
        ])
    }

    /// #181 — "Ortszeit New York 08:12": the time the reading showed where it
    /// was taken, when the server names a zone whose clock differs from the
    /// device's at that instant. `nil` otherwise and on an older server.
    static func zoneHint(
        for measurement: Measurement,
        device: TimeZone = .current,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let zone = ReadingTimeZone.awayZone(measurement.timeZone, at: measurement.recordedAt, device: device) else {
            return nil
        }
        let locale = HLTimeFormat.current(defaults: defaults).formattingLocale
        let clock = HLTimeFormat.shortTime(measurement.recordedAt, locale: locale, timeZone: zone)
        return String(localized: "measurement.row.readingZone \(ReadingTimeZone.placeName(zone)) \(clock)")
    }
}

extension MeasurementSource {
    /// The source as the history row's detail line names it.
    var measurementRowLabel: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .appleHealth: "Apple Health"
        case .withings: "Withings"
        case .whoop: "WHOOP"
        case .fitbit: "Fitbit"
        case .googleHealth: "Google Health"
        case .strava: "Strava"
        case .oura: "Oura"
        case .polar: "Polar"
        case .nightscout: "Nightscout"
        case .healthConnect: "Health Connect"
        case .garmin: "Garmin"
        case .telegram: "Telegram"
        case .mcp: "MCP"
        case .external: String(localized: "measurement.source.external")
        case .computed: String(localized: "measurement.source.computed")
        case .import_: "Import"
        case .unknown: String(localized: "measurement.source.unknown")
        }
    }
}

// MARK: - Editable raw row (read-only-aware swipe actions)

/// #42 (v1.27.6) — a raw per-day `MeasurementRow` with its Edit/Delete swipe
/// affordances gated on the row's provenance. A `COMPUTED` (server-derived)
/// measurement — e.g. a PHQ-9 / GAD-7 screening sum score — is read-only:
/// editing or deleting a derived value is meaningless, so the row still renders
/// but exposes NO swipe actions. The host additionally excludes it from
/// multi-select via `.selectionDisabled(_:)`. Extracted from
/// `MeasurementListScreen` so the screen stays under the `file_length` ceiling.
struct MeasurementSwipeActions<Content: View>: View {
    let measurement: Measurement
    let onEdit: (Measurement) -> Void
    /// Deletes through the store, which offers the undo; no question first.
    let onDelete: (Measurement) async -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if measurement.isServerDerivedReadOnly {
            content
        } else {
            content
                .hlSwipeDelete(.undoable { await onDelete(measurement) }) {
                    Button(HLControlWord.edit.key, systemImage: "pencil") {
                        onEdit(measurement)
                    }
                }
        }
    }
}

struct MeasurementSwipeRow: View {
    let measurement: Measurement
    /// The row's date line (``MeasurementRow/title``).
    var title: String?
    let onEdit: (Measurement) -> Void
    let onDelete: (Measurement) async -> Void
    /// The reason a row is locked, shown on tap instead of under
    /// every locked row of the list.
    @State private var explainsLock = false

    var body: some View {
        MeasurementSwipeActions(
            measurement: measurement,
            onEdit: onEdit,
            onDelete: onDelete
        ) {
            if measurement.isServerDerivedReadOnly {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    MeasurementRow(measurement: measurement, title: title)
                    if explainsLock {
                        Text(lockReason)
                            .hlText(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("measurement.readOnly.explain")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { explainsLock.toggle() }
                .accessibilityHint(Text(lockReason))
            } else {
                MeasurementRow(measurement: measurement, title: title)
            }
        }
    }

    /// An hourly/daily mean or a sleep night is a summary, not a
    /// row from a connected source.
    private var lockReason: LocalizedStringKey {
        measurement.isSyntheticServerRow ? "measurement.readOnly.aggregate" : "measurement.readOnly.explain"
    }
}

// MARK: - Summary row (Apple-Health-style aggregate)

/// Apple-Health-style aggregate row: the period as the title ("KW 45"), the
/// count and the span of the values in the one detail line ("6 Einträge,
/// 72,0 bis 73,0 kg"), the mean at the right. A tap opens the underlying rows
/// below it, so the trailing sign is the expand chevron.
struct MeasurementSummaryRow: View {
    let period: String
    let kind: MetricKind
    let items: [Measurement]
    let isExpanded: Bool
    let toggle: () -> Void
    /// Render aggregate stats in the user's chosen unit so the
    /// summary row agrees with the dashboard / per-reading rows.
    @Environment(\.unitPreferences) private var units

    private var stats: SummaryStats {
        SummaryStats.compute(items: items)
    }

    /// Unit-aware suffix for this kind (kg→lb, mmHg→kPa, mg/dL→mmol/L).
    private var unitSuffix: String {
        MetricValueFormatter.unitSuffix(for: kind, units: units)
    }

    var body: some View {
        HLRowButton(action: toggle) {
            HLRow(
                title: Text(verbatim: period),
                detail: HLRowDetail.text([String(localized: "\(items.count) entries"), rangeLine]),
                // A bucket of unknown rows has no mean to show and no unit
                // to show it in; the count in the detail line carries it.
                value: meanText,
                accessory: .expand(isExpanded)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text(isExpanded
                ? String(localized: "Double-tap to hide the entries")
                : String(localized: "Double-tap to show the entries")))
    }

    private var meanText: Text? {
        stats.mean.map { mean in
            let unit = MetricDurationFormat.unit(unitSuffix, kind: kind)
            let value = formatMean(mean, secondaryMean: stats.secondaryMean)
            return Text(verbatim: unit.isEmpty ? value : "\(value) \(unit)")
        }
    }

    /// "72,0 bis 73,0 kg": the two ends in the locale's range form, one unit.
    static func span(_ low: String, _ high: String, unit: String) -> String {
        let range = low == high ? low : HLNumberFormat.range(low, high)
        return unit.isEmpty ? range : "\(range) \(unit)"
    }

    /// `nil` when the bucket has no band to state (unknown rows).
    private var rangeLine: String? {
        // A360-5 C-1/C-2 — BP min/max legs convert + round per the active unit
        // (kPa → 1 decimal); scalar stats convert per family. mmHg / default
        // units are unchanged.
        guard let min = stats.min, let max = stats.max else { return nil }
        if let secMin = stats.secondaryMin, let secMax = stats.secondaryMax {
            let minPair = MetricValueFormatter.formatBloodPressure(systolic: min, diastolic: secMin, units: units)
            let maxPair = MetricValueFormatter.formatBloodPressure(systolic: max, diastolic: secMax, units: units)
            return Self.span(minPair, maxPair, unit: unitSuffix)
        }
        return Self.span(format(min), format(max), unit: MetricDurationFormat.unit(unitSuffix, kind: kind))
    }

    /// VoiceOver reads exactly what is on screen: for an unknown
    /// bucket that is the period and the count, with no Ø / Min / Max spoken.
    /// The aggregate branch is the pre-existing label, unchanged.
    private var accessibilityLabel: Text {
        guard let mean = stats.mean, let min = stats.min, let max = stats.max else {
            return Text("\(period), \(items.count) entries")
        }
        let average = formatMean(mean, secondaryMean: stats.secondaryMean)
        return Text(
            "measurements.bucket.a11y \(period) \(average) \(unitSuffix) \(items.count) \(format(min)) \(format(max))"
        )
    }

    private func formatMean(_ mean: Double, secondaryMean: Double?) -> String {
        if let secondaryMean {
            return MetricValueFormatter.formatBloodPressure(systolic: mean, diastolic: secondaryMean, units: units)
        }
        return format(mean)
    }

    private func format(_ v: Double) -> String {
        MetricDurationFormat.text(v, kind: kind) ?? MetricValueFormatter.formatScalar(v, kind: kind, units: units)
    }
}

// MARK: - First-paint skeleton

/// Shape-aware placeholder painted while the initial `measurements`
/// fetch is in flight. Mirrors the live history rows (date, detail line,
/// value at the right) inside one card, so the jump-cut to content stays small.
///
/// Mounted via `.overlay` because the host `List` would otherwise force an
/// empty-state row layout; it disappears the moment `measurements` fills.
struct MeasurementListSkeletonContent: View {
    var body: some View {
        HLPage {
            HLCard(layout: .rows) {
                ForEach(0 ..< 8, id: \.self) { _ in
                    HStack(spacing: HLSpace.sm) {
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            HLSkeleton(.capsule, width: 140, height: 14)
                            HLSkeleton(.capsule, width: 90, height: 10)
                        }
                        Spacer(minLength: 0)
                        HLSkeleton(.capsule, width: 64, height: 14)
                    }
                    .frame(minHeight: HLRowMetrics.minHeight)
                }
            }
        }
    }
}
