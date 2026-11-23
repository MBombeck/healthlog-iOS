import SwiftUI

/// The **chronological** cross-category measurement feed, mounted as
/// the "Chronologisch" mode of `MeasurementsPickerScreen`.
///
/// The operator asked: "manchmal möchte man einfach nur sehen, was die letzten
/// Messwerte sind — chronologisch, über alle Kategorien hinweg. Und man soll
/// zwischen den Kategorien hin- und her-sliden können." This is that view — a
/// single time-sorted (newest-first) feed across ALL kinds, with a horizontally
/// scrollable category chip strip pinned at the top (mirroring the Insights
/// tab-strip idiom for cross-screen consistency: monochrome filled-capsule
/// selection, selected chip scrolled to the leading edge).
///
/// Reuses: `MeasurementChronoModel` for the pure chip/sort/filter decisions,
/// `MeasurementChronoModel.formattedValue(_:)` for the value string (shared with
/// the per-kind drill-down so the two never disagree), `MetricKindDescriptor`
/// for the glyph + title. Tapping a row pushes the established per-kind table
/// (`MeasurementListScreen(kind:)`) — no parallel detail surface.
///
/// Data source: `measurementsRepo.recentAll(limit:)` (SWR-cached) raised to a cross-category window so multiple kinds interleave.
struct MeasurementsChronoFeed: View {
    /// The recent measurements across all kinds, already loaded by the host
    /// screen (so the feed stays a pure, preview-able view).
    @Binding var measurements: [Measurement]
    let onDelete: (Measurement) async -> Bool

    /// Routes the empty-state CTA to the capture picker so the
    /// empty feed has a next step instead of a dead-end caption.
    @Environment(AppRouter.self) private var router

    @State private var selection: MeasurementChronoModel.ChronoFilter = .all
    @State private var editing: Measurement?

    private var chips: [MeasurementChronoModel.ChronoFilter] {
        MeasurementChronoModel.chips(for: measurements)
    }

    private var entries: [MeasurementChronoModel.ChronoEntry] {
        MeasurementChronoModel.entries(measurements, filter: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryStrip
            content
        }
        // Keep the selection valid if the loaded set changes (e.g. a category
        // chip disappears after a reload) — fall back to "Alle".
        .onChange(of: chips) { _, newChips in
            if !newChips.contains(selection) {
                selection = .all
            }
        }
        .sheet(item: $editing) { measurement in
            EditMeasurementSheet(measurement: measurement) { updated in
                measurements = MeasurementChronoModel.replacing(
                    updated,
                    matching: measurement.id,
                    in: measurements
                )
                editing = nil
            }
        }
    }

    // MARK: - Category strip

    /// "Alle" and every category with data, as one row of chips that
    /// scrolls sideways like the Insights strip. Wrapping left a single chip
    /// alone on a second line.
    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(chips) { chip in
                    HLChip(verbatim: chip.label, isSelected: selection == chip) {
                        selection = chip
                    }
                    .sensoryFeedback(.selection, trigger: selection == chip)
                    .accessibilityIdentifier(chip.accessibilityIdentifier)
                }
            }
            .padding(.horizontal, HLLayout.pageMargin)
            .padding(.vertical, HLSpace.sm)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("measurements.chrono.strip")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            // The title says it; the button is the next step.
            HLEmptyState(icon: "tray", title: "No measurements yet") {
                HLButton("Log a measurement", systemImage: "plus", variant: .secondary) {
                    router.requestCapture()
                }
                .accessibilityIdentifier("measurements.chrono.empty.log")
            }
            .accessibilityIdentifier("measurements.chrono.empty")
        } else {
            List {
                Section {
                    ForEach(entries) { entry in
                        switch entry {
                        case .collapsed:
                            chronologicalNavigationRow(entry)
                        case let .single(measurement):
                            if entry.editableMeasurement != nil {
                                MeasurementSwipeActions(
                                    measurement: measurement,
                                    onEdit: { editing = $0 },
                                    onDelete: { await performDelete($0) },
                                    content: { chronologicalNavigationRow(entry) }
                                )
                            } else {
                                chronologicalNavigationRow(entry)
                            }
                        }
                    }
                }
                .hlFormRowSurface()
                // Canonical sync-status footer so the
                // chrono mode carries the same pull-to-refresh feedback as the
                // by-type list (self-suppressing via empty-section footer).
                Section {} footer: {
                    HLSyncStatusFooter()
                }
            }
            .listStyle(.insetGrouped)
            .hlPageMargins()
            .hlScrollEdgeSoft()
        }
    }

    private func chronologicalNavigationRow(
        _ entry: MeasurementChronoModel.ChronoEntry
    ) -> some View {
        // A data row: the whole row pushes the per-kind table, no chevron.
        ChronoRow(entry: entry)
            .hlRowLink(inList: true) {
                MeasurementListScreen(kind: entry.representative.kind)
            }
            .accessibilityIdentifier("measurements.chrono.row.\(entry.id)")
    }

    private func performDelete(_ measurement: Measurement) async {
        let snapshot = measurements
        measurements.removeAll { $0.id == measurement.id }
        if await !onDelete(measurement) {
            measurements = snapshot
        }
    }
}

// MARK: - Row

/// One chronological feed row: the kind's glyph and name, the timestamp in
/// the detail line, the value at the right. A `.collapsed` entry (a
/// same-minute run of high-frequency vitals, e.g. Apple-Watch heart rate)
/// shows as ONE honest summary row ("46 bpm · 10×") with the sample count in
/// the detail line. Display-only: every underlying sample is preserved.
private struct ChronoRow: View {
    let entry: MeasurementChronoModel.ChronoEntry
    /// Render values in the user's chosen unit, matching the
    /// dashboard tile / detail screen instead of the raw canonical value.
    @Environment(\.unitPreferences) private var units

    private var measurement: Measurement {
        entry.representative
    }

    private var collapsedSamples: [Measurement]? {
        if case let .collapsed(_, samples) = entry { return samples }
        return nil
    }

    private var valueLabel: String {
        if let samples = collapsedSamples {
            // High-frequency vitals (pulse / SpO₂ / respiratory) have no
            // re-unitable family, so the unit suffix resolves to the canonical
            // label; kept unit-aware for a single resolution path.
            let unit = MetricValueFormatter.unitSuffix(for: measurement.kind, units: units)
            return MeasurementChronoModel.collapsedValueLabel(for: samples, unit: unit)
        }
        return MeasurementChronoModel.formattedValue(measurement, units: units)
    }

    var body: some View {
        HLRow(
            title: Text(measurement.kind.displayName),
            detail: HLRowDetail.text([
                // Historical rows add the year when the measurement isn't
                // from the current year (else the day+month is ambiguous).
                HLDateFormat.appendingYearIfNeeded(
                    measurement.recordedAt,
                    base: .dateTime.weekday(.abbreviated).day().month().hour().minute()
                ),
                collapsedSamples.map { String(localized: "\($0.count) measurements this minute") },
                MeasurementRow.zoneHint(for: measurement)
            ]),
            value: Text(verbatim: valueLabel)
        ) {
            // The same chip as the "By type" list, so a kind looks alike in both.
            HLSettingsIconChip(symbol: measurement.kind.descriptor.sfSymbol, tint: HLAccent.userBrandTint)
        }
    }
}
