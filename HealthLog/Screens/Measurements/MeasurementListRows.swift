import SwiftUI

// v0.14.8 W3 — row-level subviews extracted from `MeasurementListScreen.swift`
// so the screen file stays under the 600-line SwiftLint `file_length`
// baseline once the multi-select bulk-delete affordances landed. Types are
// unchanged (same module, module-internal access); only the file boundary
// moves — the same mechanical split `MeasurementBucketing.swift` and
// `MeasurementListFilters.swift` went through in v0.5.5.1.

// MARK: - Section header

struct MeasurementListSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hlCaption.weight(.semibold))
            .foregroundStyle(HLText.secondary)
    }
}

// MARK: - Raw row (per-measurement)

struct MeasurementRow: View {
    let measurement: Measurement
    /// A360-5 C-1 — render the value in the user's chosen unit (matches the
    /// dashboard tile / chrono feed), not the raw canonical value.
    @Environment(\.unitPreferences) private var units

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(formattedValue)
                    .font(.hlMetric(.title3))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                // b215 — historical rows add the year when the measurement
                // isn't from the current year (else the day+month is ambiguous).
                Text(HLDateFormat.appendingYearIfNeeded(
                    measurement.recordedAt,
                    base: .dateTime.weekday(.abbreviated).day().month().hour().minute()
                ))
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                if let note = measurement.note, !note.isEmpty {
                    Text(note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            HLBadge(sourceLabel, tone: sourceTone)
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    // v0.14.8 — value formatting now lives in the shared
    // `MeasurementChronoModel.formattedValue(_:)` so the chronological feed row
    // and this drill-down row never diverge on a value.
    private var formattedValue: String {
        MeasurementChronoModel.formattedValue(measurement, units: units)
    }

    private var sourceLabel: String {
        switch measurement.source {
        case .manual: "Manuell"
        case .appleHealth: "Apple Health"
        case .withings: "Withings"
        case .whoop: "WHOOP"
        case .fitbit: "Fitbit"
        case .googleHealth: "Google Health"
        case .strava: "Strava"
        case .oura: "Oura"
        case .polar: "Polar"
        case .nightscout: "Nightscout"
        case .computed: String(localized: "measurement.source.computed")
        case .import_: "Import"
        }
    }

    /// REG-3 (2026-05-21): per-source coloured backgrounds (green for Apple
    /// Health, cyan for Withings, purple for Import) read as "wrong/loud"
    /// against the otherwise tonal-mono drill-down — most visibly on the
    /// BP rows where the operator flagged the issue. Aligns with the
    /// Insights monochrome template (see
    /// `.planning/v056-marathon/A3-monochrome-template.md`) which always
    /// paints source-provenance pills with `.neutral` (graphite). The
    /// source label itself still carries the provenance information — the
    /// colour was decorative, not semantic.
    private var sourceTone: HLBadge.Tone {
        .neutral
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
    let onDelete: (Measurement) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !measurement.isServerDerivedReadOnly {
                    Button(role: .destructive) {
                        onDelete(measurement)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        onEdit(measurement)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
    }
}

struct MeasurementSwipeRow: View {
    let measurement: Measurement
    let onEdit: (Measurement) -> Void
    let onDelete: (Measurement) -> Void

    var body: some View {
        MeasurementSwipeActions(
            measurement: measurement,
            onEdit: onEdit,
            onDelete: onDelete
        ) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                MeasurementRow(measurement: measurement)
                // Build 3 / item 3.3 — explain computed read-only rows instead
                // of silently withholding actions.
                if measurement.isServerDerivedReadOnly {
                    Label {
                        Text("measurement.readOnly.explain")
                    } icon: {
                        Image(systemName: "lock")
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityIdentifier("measurement.readOnly.explain")
                }
            }
        }
    }
}

// MARK: - Summary row (Apple-Health-style aggregate)

/// Apple-Health-style aggregate row — replaces a long list of raw rows with a
/// single "Ø 84 kg · 12 Eintraege · Min 82.1 / Max 86.4" line plus a chevron
/// to expand to the underlying rows. The card-row tap toggles expansion.
struct MeasurementSummaryRow: View {
    let period: String
    let kind: MetricKind
    let items: [Measurement]
    let isExpanded: Bool
    let toggle: () -> Void
    /// A360-5 C-1 — render aggregate stats in the user's chosen unit so the
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
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(period)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    // Existing expandable summary affordance; it toggles in
                    // place and intentionally does not push a destination.
                    // swiftlint:disable:next hl_no_handmade_chevron
                    HLDisclosureChevron(expanded: isExpanded)
                }
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    Text(formatMean(stats.mean, secondaryMean: stats.secondaryMean))
                        .font(.hlMetric(.title3))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                    Text(unitSuffix)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text("\(items.count) entries")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                }
                Text(rangeLine)
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, HLSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                "\(period), Ø \(formatMean(stats.mean, secondaryMean: stats.secondaryMean)) \(unitSuffix), \(items.count) Einträge, Min \(format(stats.min)), Max \(format(stats.max))"
            )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isExpanded
                ? String(localized: "Double-tap to hide the entries")
                : String(localized: "Double-tap to show the entries")))
    }

    private var rangeLine: String {
        // A360-5 C-1/C-2 — BP min/max legs convert + round per the active unit
        // (kPa → 1 decimal); scalar stats convert per family. mmHg / default
        // units are unchanged.
        if let secMin = stats.secondaryMin, let secMax = stats.secondaryMax {
            let minPair = MetricValueFormatter.formatBloodPressure(systolic: stats.min, diastolic: secMin, units: units)
            let maxPair = MetricValueFormatter.formatBloodPressure(systolic: stats.max, diastolic: secMax, units: units)
            return "Min \(minPair) · Max \(maxPair) \(unitSuffix)"
        }
        return "Min \(format(stats.min)) / Max \(format(stats.max)) \(unitSuffix)"
    }

    private func formatMean(_ mean: Double, secondaryMean: Double?) -> String {
        if let secondaryMean {
            return MetricValueFormatter.formatBloodPressure(systolic: mean, diastolic: secondaryMean, units: units)
        }
        return format(mean)
    }

    private func format(_ v: Double) -> String {
        MetricValueFormatter.formatScalar(v, kind: kind, units: units)
    }
}

// MARK: - Empty state

/// v0.7.0 — migrated to `ContentUnavailableView` (iOS 17+). The previous
/// hand-rolled stack of glyph + caption is replaced by the system
/// primitive, which carries the standard Dynamic-Type rhythm + VoiceOver
/// grouping. The empty card lives inside the host `List`, so the
/// `.listRow*` modifiers stay on the wrapper to keep the background
/// transparent + suppress the row separator.
struct MeasurementListEmptyState: View {
    /// QoL-4 (A360-4) — optional next-step CTA. When the host wires it, the empty
    /// state offers a "Log a measurement" button (prefilled to this kind) instead
    /// of a dead-end caption. `nil` keeps the bare empty state (e.g. previews).
    var onLog: (() -> Void)?

    var body: some View {
        HLEmptyState(
            icon: "tray",
            title: "No measurements yet",
            message: "Log your first measurement to see the history."
        ) {
            if let onLog {
                HLButton(
                    String(localized: "Log a measurement"),
                    icon: "plus",
                    variant: .restrained,
                    action: onLog
                )
                .accessibilityIdentifier("measurements.list.empty.log")
            }
        }
        .accessibilityIdentifier("measurements.list.empty")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - First-paint skeleton (W-IMPL-SKELETON)

/// Shape-aware placeholder painted while the initial `measurements`
/// fetch is in flight. Mirrors the live `MeasurementRow` rhythm — a
/// title capsule (value), a subtitle capsule (timestamp), an optional
/// note capsule and a trailing source-chip pill — so the jump-cut
/// from skeleton to content stays minimal.
///
/// Mounted via `.overlay` because the host `List` is rendered as a
/// `.listStyle(.insetGrouped)` and embedding the skeleton as a list
/// section would force an empty-state row layout. The overlay sits
/// above the empty `List` and disappears the moment `measurements`
/// fills — the `isLoading && measurements.isEmpty` gate matches the
/// pre-W-IMPL-SKELETON `ProgressView()` overlay it replaces.
struct MeasurementListSkeletonContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                ForEach(0 ..< 8, id: \.self) { _ in
                    HLCard {
                        HStack(alignment: .top, spacing: HLSpace.sm) {
                            VStack(alignment: .leading, spacing: HLSpace.xs) {
                                HLSkeleton(.capsule, width: 110, height: 20)
                                HLSkeleton(.capsule, width: 160, height: 12)
                                HLSkeleton(.capsule, width: 200, height: 10)
                            }
                            Spacer(minLength: 0)
                            HLSkeleton(.capsule, width: 64, height: 18)
                        }
                    }
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.md)
        }
        .scrollContentBackground(.hidden)
    }
}
