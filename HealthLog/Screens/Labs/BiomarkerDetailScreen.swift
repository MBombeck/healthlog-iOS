import SwiftUI

/// v0154 LR-REDO — the Insights-class biomarker detail page.
///
/// Reached from the ``LabsScreen`` "by type" index (one row per analyte /
/// biomarker). Modeled top-to-bottom on the Insights metric page
/// (`InsightsMetricScreen`): a `InsightsPageHeader` with a gear that opens the
/// `BiomarkerEditorSheet` (to edit the reference range + context), an explainer
/// paragraph, a "Letzte Messung" card, on-device Durchschnitt / Max / Median
/// stats, a value-over-time chart with a neutral reference band, and the full
/// "Alle Messungen" list. A bottom-floating `HLFloatingPeriodControl`
/// (Tag / Woche / Monat / Jahr / Alle) filters the series client-side from the
/// already-loaded `LabsStore.labs` — no new server endpoint.
///
/// **PHI / data.** Every reading is a pure filter of `store.labs`; the page never
/// recomputes a range verdict. The page lives inside the same AccessGuard-gated
/// labs surface as the list, so the PHI gating is inherited.
struct BiomarkerDetailScreen: View {
    let store: LabsStore
    /// The analyte name this page indexes (the "by type" identity). All readings
    /// for this analyte are filtered live from `store.labs`.
    let analyte: String
    /// The linked catalog biomarker, when this analyte resolves to one. Drives
    /// the editor gear (reference range + context) and the explainer fallback.
    let biomarker: BiomarkerDTO?

    @State private var range: BiomarkerSeries.LabsRange = .month
    @State private var showEditor = false
    @State private var editingResult: LabResultDTO?

    /// All readings for this analyte (live re-derived so an edit / delete / undo
    /// in the store repaints the page). Newest-first.
    private var allRows: [LabResultDTO] {
        if let biomarker {
            let linked = BiomarkerSeries.rows(forBiomarkerId: biomarker.id, in: store.labs)
            if !linked.isEmpty { return linked }
        }
        return BiomarkerSeries.rows(forAnalyte: analyte, in: store.labs)
    }

    /// Readings inside the selected range window — drives stats, chart, and list.
    private var windowedRows: [LabResultDTO] {
        BiomarkerSeries.windowed(allRows, range: range)
    }

    private var latest: LabResultDTO? {
        allRows.first
    }

    /// The display unit — prefer the linked biomarker's canonical unit, else the
    /// latest reading's unit.
    private var unit: String {
        if let unit = biomarker?.unit, !unit.isEmpty { return unit }
        return latest?.unit ?? ""
    }

    /// Reference bounds — the linked biomarker's bounds win (the canonical,
    /// user-editable range); else the latest reading's server-resolved bounds.
    private var referenceLow: Double? {
        biomarker?.lowerBound ?? latest?.referenceLow
    }

    private var referenceHigh: Double? {
        biomarker?.upperBound ?? latest?.referenceHigh
    }

    private var explainer: String? {
        BiomarkerExplainer.text(context: biomarker?.context, name: biomarker?.name ?? analyte)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                header
                explainerSlot
                lastMeasurementSection
                statsSection
                chartSection
                allMeasurementsSection
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HLFloatingPeriodControl(selection: $range, accessibilityLabelText: "Time range")
        }
        .sheet(isPresented: $showEditor) {
            if let biomarker {
                BiomarkerEditorSheet(store: store, existing: biomarker)
            }
        }
        .sheet(item: $editingResult) { result in
            EditLabResultSheet(store: store, result: result)
        }
    }

    // MARK: - Sections

    private var header: some View {
        InsightsPageHeader(
            LocalizedStringKey(displayName),
            accessibilityIdentifierSuffix: "biomarker"
        ) {
            if biomarker != nil {
                InsightsHeaderActionCircle(
                    systemImage: "slider.horizontal.3",
                    accessibilityLabelText: String(localized: "biomarker.detail.editRange"),
                    accessibilityIdentifier: "biomarker.detail.gear"
                ) {
                    showEditor = true
                }
            }
        }
    }

    /// The biomarker title. A linked marker shows its catalog name; an unlinked
    /// analyte shows the analyte string verbatim.
    private var displayName: String {
        if let name = biomarker?.name, !name.isEmpty { return name }
        return analyte
    }

    @ViewBuilder
    private var explainerSlot: some View {
        if let explainer {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(verbatim: explainer)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("biomarker.detail.explainer.a11y"))
                // A360-1 M2 — discreet pointer to the generic lab-biomarker
                // /learn guide (mirrors the server's LearnMoreLink on Labs detail).
                HLLearnMoreLink(concept: "LAB_BIOMARKER")
            }
        }
    }

    @ViewBuilder
    private var lastMeasurementSection: some View {
        if let latest {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("biomarker.detail.lastMeasurement")
                BiomarkerLastMeasurementCard(latest: latest)
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        if let stats = BiomarkerSeries.stats(for: windowedRows) {
            // No section header — `StatsRow` already labels each cell
            // (Min / Ø / Max / Median); the real Insights metric page
            // (`InsightsMetricScreen`) renders this strip bare too. A
            // "Durchschnitt" header here would mislabel a 4-stat row as the mean.
            StatsRow(
                stats: stats,
                median: BiomarkerSeries.median(for: windowedRows),
                unit: unit
            )
        }
    }

    private var chartSection: some View {
        BiomarkerChart(
            rows: windowedRows,
            unit: unit,
            referenceLow: referenceLow,
            referenceHigh: referenceHigh
        )
    }

    @ViewBuilder
    private var allMeasurementsSection: some View {
        if !windowedRows.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("biomarker.detail.allMeasurements")
                HLCard {
                    VStack(spacing: 0) {
                        ForEach(Array(windowedRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().overlay(HLColor.separator)
                            }
                            LabResultRow(row: row)
                                .padding(.vertical, HLSpace.xs)
                                .contentShape(Rectangle())
                                .onTapGesture { editingResult = row }
                        }
                    }
                }
            }
        }
    }
}
