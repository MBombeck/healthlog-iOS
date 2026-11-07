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
    /// #130 — the marker's newest reading as the overview delivered it. The
    /// readings below are filtered from the loaded `labs` page, which can end
    /// before a marker measured only long ago; then this one reading stands in
    /// so the page is never blank for a marker the list shows.
    var overviewLatest: LabResultDTO?

    @State private var range: BiomarkerSeries.LabsRange = .month
    /// One sheet slot for the marker's editor, its spellings and the merge
    /// (#130), so the page keeps a single presentation for all three.
    @State private var markerSheet: MarkerSheet?
    /// #130 — the marker's whole history when the page may end before it.
    @State private var history: [LabResultDTO]?
    @State private var editingResult: LabResultDTO?

    /// #130 — the marker as it is now: the one it was merged into, else the
    /// live catalog entry (an alias edit shows at once).
    private var marker: BiomarkerDTO? {
        biomarker.map(store.resolvedBiomarker)
    }

    /// All readings for this analyte (live re-derived so an edit / delete / undo
    /// in the store repaints the page). Newest-first. #130: the marker's whole
    /// history wins when it holds more than the loaded page.
    private var allRows: [LabResultDTO] {
        let page = pageRows
        if let history, history.count > page.count {
            return history
        }
        if page.isEmpty, let overviewLatest { return [overviewLatest] }
        return page
    }

    private var pageRows: [LabResultDTO] {
        if let marker {
            let linked = BiomarkerSeries.rows(forBiomarkerId: marker.id, in: store.labs)
            if !linked.isEmpty { return linked }
        }
        return BiomarkerSeries.rows(forAnalyte: analyte, in: store.labs)
    }

    /// #130 — the page of rows can end before this marker's readings do.
    private var pageMayBeTruncated: Bool {
        pageRows.isEmpty || store.labs.count >= LabsStore.historyLimit
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
        if let unit = marker?.unit, !unit.isEmpty { return unit }
        return latest?.unit ?? ""
    }

    /// Reference bounds — the linked biomarker's bounds win (the canonical,
    /// user-editable range); else the latest reading's server-resolved bounds.
    private var referenceLow: Double? {
        marker?.lowerBound ?? latest?.referenceLow
    }

    private var referenceHigh: Double? {
        marker?.upperBound ?? latest?.referenceHigh
    }

    private var explainer: String? {
        BiomarkerExplainer.text(context: marker?.context, name: marker?.name ?? analyte)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                header
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
        .sheet(item: $markerSheet) { sheet in
            if let marker {
                switch sheet {
                case .editor: BiomarkerEditorSheet(store: store, existing: marker)
                case .aliases: BiomarkerAliasesSheet(store: store, marker: marker)
                case .merge: BiomarkerMergeSheet(store: store, target: marker)
                }
            }
        }
        .sheet(item: $editingResult) { result in
            EditLabResultSheet(store: store, result: result)
        }
        // #130 — a marker measured only long ago can lie beyond the page.
        .task(id: marker?.id ?? analyte) {
            if pageMayBeTruncated { history = await store.fetchHistory(biomarkerId: marker?.id, analyte: analyte) }
        }
    }

    // MARK: - Sections

    /// 1.4 B2-c — the header carries the page's one (i) (the explainer, the
    /// other spellings, the references and the guide, which used to stand as
    /// two loose blocks under the title) and the gear. Where the server can
    /// edit spellings and merge markers, those two sit in the gear's menu
    /// beside the range editor instead of as caption buttons on the page.
    private var header: some View {
        InsightsPageHeader(
            LocalizedStringKey(displayName),
            accessibilityIdentifierSuffix: "biomarker"
        ) {
            HLInfoButton(content: info, style: .circle, accessibilityIdentifier: "biomarker.detail.info")
            if marker != nil {
                if ServerFeatureMirror.shared.current?.biomarkerMerge == true {
                    Menu {
                        Button("biomarker.detail.editRange") { markerSheet = .editor }
                        Button("labs.aliases.edit") { markerSheet = .aliases }
                        Button("labs.merge.open") { markerSheet = .merge }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .hlHeaderCircle()
                    }
                    .accessibilityLabel(Text("biomarker.detail.editRange"))
                    .accessibilityIdentifier("biomarker.detail.gear")
                } else {
                    InsightsHeaderActionCircle(
                        systemImage: "slider.horizontal.3",
                        accessibilityLabelText: String(localized: "biomarker.detail.editRange"),
                        accessibilityIdentifier: "biomarker.detail.gear"
                    ) {
                        markerSheet = .editor
                    }
                }
            }
        }
    }

    /// What the (i) explains. The citations of the explainer travel with it;
    /// the reading's range verdict keeps its own visible link in the card.
    private var info: HLInfoContent {
        var sections: [HLInfoContent.Section] = []
        if let aliases = marker?.aliases, !aliases.isEmpty {
            sections.append(HLInfoContent.Section(
                title: String(localized: "biomarker.detail.info.aliases"),
                paragraphs: [String(localized: "labs.biomarker.aliases \(aliases.formatted(.list(type: .and)))")]
            ))
        }
        return HLInfoContent(
            title: displayName,
            identifier: "biomarker.detail.info.sheet",
            about: explainer,
            topic: sourcesTopic,
            sections: sections,
            learnMoreConcept: "LAB_BIOMARKER"
        )
    }

    /// The biomarker title. A linked marker shows its catalog name; an unlinked
    /// analyte shows the analyte string verbatim.
    private var displayName: String {
        if let name = marker?.name, !name.isEmpty { return name }
        return analyte
    }

    /// The citation topic for this marker: the resolved catalogue slug when the
    /// analyte name maps to one, else the shared lab reference-range topic.
    private var sourcesTopic: MedicalSourceTopic {
        if let slug = BiomarkerExplainer.slug(forName: marker?.name ?? analyte) {
            return .labBiomarker(slug)
        }
        return .labReferenceRanges
    }

    @ViewBuilder
    private var lastMeasurementSection: some View {
        if let latest {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("biomarker.detail.lastMeasurement")
                BiomarkerLastMeasurementCard(latest: latest, sourcesTopic: sourcesTopic)
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
                // POLISH-A F-LAB-1 — the unity "1" (a ratio, #160) is
                // never printed after a number.
                unit: LabUnit.suffix(unit) ?? ""
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

/// #130 — what the marker page's single sheet shows.
private enum MarkerSheet: String, Identifiable {
    case editor
    case aliases
    case merge

    var id: String {
        rawValue
    }
}
