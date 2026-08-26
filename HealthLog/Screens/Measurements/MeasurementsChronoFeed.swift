import SwiftUI

/// v0.14.8 — the **chronological** cross-category measurement feed, mounted as
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
/// Data source: `measurementsRepo.recentAll(limit:)` (SWR-cached, on-device in
/// standalone) raised to a cross-category window so multiple kinds interleave.
struct MeasurementsChronoFeed: View {
    /// The recent measurements across all kinds, already loaded by the host
    /// screen (so the feed stays a pure, preview-able view).
    @Binding var measurements: [Measurement]
    let onDelete: (Measurement) async -> Bool

    /// QoL-4 (A360-4) — routes the empty-state CTA to the capture picker so the
    /// empty feed has a next step instead of a dead-end caption.
    @Environment(AppRouter.self) private var router
    /// A11Y (audit-v0162 §5) — gates the imperative scroll-into-view animation
    /// on the category strip so the active chip jumps instead of sliding when
    /// Reduce Motion is on (the `.hlAnimation` on the strip already honours it).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: MeasurementChronoModel.ChronoFilter = .all
    @State private var editing: Measurement?
    @State private var deleteConfirmTarget: Measurement?

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
            } onDismiss: {
                editing = nil
            }
            .hlSheetPresentation(.form)
        }
        .hlConfirmDestructive(
            Text("Messung löschen?"),
            isPresented: Binding(
                get: { deleteConfirmTarget != nil },
                set: { if !$0 { deleteConfirmTarget = nil } }
            ),
            message: Text("measurement.delete.confirm.message"),
            confirm: Text("Delete"),
            cancel: Text("Cancel"),
            onCancel: { deleteConfirmTarget = nil },
            action: {
                if let target = deleteConfirmTarget {
                    Task { await performDelete(target) }
                }
                deleteConfirmTarget = nil
            }
        )
    }

    // MARK: - Category strip

    /// Horizontally scrollable chip strip — "Alle" + every chip that has data.
    /// Mirrors `InsightsMetricTabStrip`: monochrome capsules, selected chip
    /// filled + scrolled to the leading edge so the active category reads
    /// left-to-right. Reduce-motion is honored via `hlAnimation`.
    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HLSpace.sm) {
                    ForEach(chips) { chip in
                        chipPill(chip)
                            .id(chip)
                    }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.sm)
            }
            .scrollClipDisabled()
            .onChange(of: selection) { _, newValue in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    proxy.scrollTo(newValue, anchor: .leading)
                }
            }
        }
        .hlAnimation(.easeInOut(duration: 0.22), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("measurements.chrono.strip")
    }

    private func chipPill(_ chip: MeasurementChronoModel.ChronoFilter) -> some View {
        let isSelected = selection == chip
        return Button {
            selection = chip
        } label: {
            Text(chip.label)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(isSelected ? HLSurface.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(HLSurface.tertiary))
                }
                .overlay {
                    if !isSelected {
                        Capsule(style: .continuous)
                            .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityIdentifier(chip.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            EmptyCategoryState(onLog: { router.requestCapture() })
        } else {
            List {
                ForEach(entries) { entry in
                    switch entry {
                    case .collapsed:
                        chronologicalNavigationRow(entry)
                    case let .single(measurement):
                        if entry.editableMeasurement != nil {
                            MeasurementSwipeActions(
                                measurement: measurement,
                                onEdit: { editing = $0 },
                                onDelete: { deleteConfirmTarget = $0 },
                                content: { chronologicalNavigationRow(entry) }
                            )
                        } else {
                            chronologicalNavigationRow(entry)
                        }
                    }
                }
                // v0.14.8 W2-SYNCUX — canonical sync-status footer so the
                // chrono mode carries the same pull-to-refresh feedback as the
                // by-type list (self-suppressing via empty-section footer).
                Section {} footer: {
                    HLSyncStatusFooter()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Canonical screen canvas (matches Mehr/Insights/Medis/Start) —
            // `HLColor.background` drifted bluish in dark mode.
            .background(HLSurface.primary)
            .hlScrollEdgeSoft()
        }
    }

    private func chronologicalNavigationRow(
        _ entry: MeasurementChronoModel.ChronoEntry
    ) -> some View {
        NavigationLink {
            MeasurementListScreen(kind: entry.representative.kind)
        } label: {
            ChronoRow(entry: entry)
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

/// One chronological feed row — glyph + localized type name + value/unit +
/// absolute timestamp, monochrome. Reuses `MetricKindDescriptor` for the glyph
/// and `MeasurementChronoModel.formattedValue(_:)` for the value (shared with
/// the per-kind drill-down).
///
/// D1 (#34) — a `.collapsed` entry (a same-minute run of high-frequency-vital
/// samples, e.g. Apple-Watch heart rate) renders as ONE honest summary row
/// ("46 bpm · 10×") with a quiet "N Messwerte" sub-caption, instead of N
/// near-identical rows. Display-only: every underlying sample is preserved.
private struct ChronoRow: View {
    let entry: MeasurementChronoModel.ChronoEntry
    /// A360-5 C-1 — render values in the user's chosen unit, matching the
    /// dashboard tile / detail screen instead of the raw canonical value.
    @Environment(\.unitPreferences) private var units

    private var measurement: Measurement {
        entry.representative
    }

    private var descriptor: MetricKindDescriptor {
        measurement.kind.descriptor
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
        HStack(alignment: .center, spacing: HLSpace.md) {
            Image(systemName: descriptor.sfSymbol)
                .font(.hlIcon(HLIconSize.md))
                .foregroundStyle(HLText.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(measurement.kind.displayName)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                // b215 — historical rows add the year when the measurement
                // isn't from the current year (else the day+month is ambiguous).
                Text(HLDateFormat.appendingYearIfNeeded(
                    measurement.recordedAt,
                    base: .dateTime.weekday(.abbreviated).day().month().hour().minute()
                ))
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                if let samples = collapsedSamples {
                    Text("\(samples.count) measurements this minute")
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }
            }
            Spacer(minLength: HLSpace.sm)
            Text(valueLabel)
                .font(.hlMetric(.body))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

/// Calm per-category empty state — shown when the selected chip has no rows
/// (or the whole feed is empty). Mirrors the type-picker / drill-down empty
/// copy family so the surfaces feel like one.
private struct EmptyCategoryState: View {
    /// QoL-4 (A360-4) — next-step CTA: open the capture picker.
    var onLog: (() -> Void)?

    var body: some View {
        HLEmptyState(
            icon: "tray",
            title: "No measurements yet",
            message: "No measurements in this category yet."
        ) {
            if let onLog {
                HLButton(
                    String(localized: "Log a measurement"),
                    icon: "plus",
                    variant: .restrained,
                    action: onLog
                )
                .accessibilityIdentifier("measurements.chrono.empty.log")
            }
        }
        .accessibilityIdentifier("measurements.chrono.empty")
    }
}
