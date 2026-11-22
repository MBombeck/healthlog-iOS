import SwiftUI

/// The Insights-class biomarker detail page.
///
/// Reached from the ``LabsScreen`` "by type" index (one row per analyte /
/// biomarker). It keeps the section order of the reference metric pages
/// (Ruhepuls, Blutdruck): last measurement on its reference range,
/// assessment, statistics, chart, then the row to all readings. Pushed, the
/// title is the system's, large at the top and moving into the bar on
/// scroll; beside the labs table the page is a column of that screen, headed
/// by ``HLColumnHeader``, its section headers one rank down. The (i) and the
/// gear stand in the bar in both forms. The period bar at the bottom (the app's
/// one period set) filters the series client-side from `LabsStore.labs`.
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
    /// The marker's newest reading as the overview delivered it. The
    /// readings below are filtered from the loaded `labs` page, which can end
    /// before a marker measured only long ago; then this one reading stands in
    /// so the page is never blank for a marker the list shows.
    var overviewLatest: LabResultDTO?
    /// Every reading of the marker as the overview counts them, so the
    /// column's head says what the table row says before the history loads.
    var overviewCount: Int?
    /// The page stands as the detail beside the labs table instead of being
    /// pushed: it heads itself with the column header, and its actions stand
    /// in the labs screen's bar. Everything below the head is the pushed page.
    var isEmbedded = false
    /// Where the editor, the spellings and the merge are presented. Beside the
    /// table the screen owns them (a sheet on the pane would close with the
    /// pane when the window narrows); pushed, the page keeps its own.
    var externalSheet: Binding<BiomarkerSheet?>?

    @Environment(\.dismiss) private var dismiss

    /// The period the reader chose; `nil` until then, so the page opens on
    /// a period that holds the marker's values (`openingRange`).
    @State private var chosenRange: BiomarkerSeries.LabsRange?
    /// One sheet slot for the marker's editor, its spellings and the merge
    /// (#130), so the page keeps a single presentation for all three.
    @State private var markerSheet: BiomarkerSheet?
    /// The marker's whole history when the page may end before it.
    @State private var history: [LabResultDTO]?

    /// The marker as it is now: the one it was merged into, else the
    /// live catalog entry (an alias edit shows at once).
    private var marker: BiomarkerDTO? {
        biomarker.map(store.resolvedBiomarker)
    }

    /// All readings for this analyte (live re-derived so an edit / delete / undo
    /// in the store repaints the page). Newest-first. The marker's whole
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

    /// The page of rows can end before this marker's readings do.
    private var pageMayBeTruncated: Bool {
        pageRows.isEmpty || store.labs.count >= LabsStore.historyLimit
    }

    private var range: BiomarkerSeries.LabsRange {
        chosenRange ?? BiomarkerSeries.openingRange(for: allRows)
    }

    private var rangeSelection: Binding<BiomarkerSeries.LabsRange> {
        Binding(get: { range }, set: { chosenRange = $0 })
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
        LabRangeScale.bounds(marker: marker, latest: latest).low
    }

    private var referenceHigh: Double? {
        LabRangeScale.bounds(marker: marker, latest: latest).high
    }

    var body: some View {
        page
            .modifier(BiomarkerPageChrome(isEmbedded: isEmbedded, title: displayName, actions: pageActions))
            // Asks before the marker's delete in the more menu.
            .hlDeleteConfirmation()
            // The period bar of every chart page, floating at the bottom
            // edge, only for a marker with a course: one value has no period
            // to choose, it stands on its range in the card above.
            .hlPeriodBar(selection: rangeSelection, label: "Time range", isShown: showsPeriodBar)
            .sheet(item: ownSheet) { sheet in
                if let marker {
                    switch sheet {
                    case .editor: BiomarkerEditorSheet(store: store, existing: marker)
                    case .aliases: BiomarkerAliasesSheet(store: store, marker: marker)
                    case .merge: BiomarkerMergeSheet(store: store, target: marker)
                    }
                }
            }
            // A marker measured only long ago can lie beyond the page.
            .task(id: marker?.id ?? analyte) {
                if pageMayBeTruncated { history = await store.fetchHistory(biomarkerId: marker?.id, analyte: analyte) }
            }
    }

    /// The marker page: the same blocks pushed and beside the table.
    private var page: some View {
        HLPage {
            if isEmbedded {
                HLColumnHeader(verbatim: displayName, subtitle: columnSubtitle, titleIdentifier: "biomarker.detail.columnHeader")
            }
            lastMeasurementSection
            assessmentSection
            statsSection
            chartSection
            // #191 QoL — the newest readings under the chart, with the row
            // to all of them as the card's last row.
            BiomarkerLatestValuesSection(store: store, rows: allRows, windowedRows: windowedRows, title: displayName)
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    // MARK: - Sections

    private var sheetBinding: Binding<BiomarkerSheet?> {
        externalSheet ?? $markerSheet
    }

    /// The page's own sheet slot: unused while the screen presents for it.
    private var ownSheet: Binding<BiomarkerSheet?> {
        Binding(get: { externalSheet == nil ? markerSheet : nil }, set: { markerSheet = $0 })
    }

    /// Whether the period bar stands: only when the marker has two values
    /// to draw, pushed and beside the table alike.
    private var showsPeriodBar: Bool {
        Self.hasCourse(allRows)
    }

    /// Whether the readings make a course: two numbers at least.
    nonisolated static func hasCourse(_ rows: [LabResultDTO]) -> Bool {
        BiomarkerSeries.valueBearing(rows).count >= 2
    }

    /// Whether the course card stands: with a course, and also for a single
    /// value that has no place on a range (no range, or a qualitative
    /// result), where its note says why no line is drawn. Only a value the
    /// range bar can place leaves the card out.
    nonisolated static func showsCourseCard(_ rows: [LabResultDTO], low: Double?, high: Double?) -> Bool {
        hasCourse(rows) || LabRangeScale.placement(value: rows.first?.value, previous: [], low: low, high: high) == nil
    }

    /// The line under the column header: how many readings, and when the
    /// newest was taken, as the row in the table says it.
    private var columnSubtitle: String? {
        HLRowDetail.joined([
            BiomarkerIndexRow.countCaption(max(overviewCount ?? 0, allRows.count, 1)),
            latest.map { LabsDateFormat.labDate($0.takenAt) }
        ])
    }

    /// This page is pushed, so its (i) and its edit stand in the system bar
    /// as one group. Beside the labs table the screen's bar carries the same
    /// actions for the selected marker (``markerActions(marker:analyte:sheet:)``).
    private var pageActions: HLTabHeaderActions {
        HLTabHeaderActions(Self.markerActions(marker: marker, analyte: analyte, sheet: sheetBinding) { id in
            if await store.deleteBiomarker(id: id) { dismiss() }
        })
    }

    /// The biomarker title. A linked marker shows its catalog name; an unlinked
    /// analyte shows the analyte string verbatim.
    private var displayName: String {
        Self.displayName(marker: marker, analyte: analyte)
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
            HLSectionHeader("biomarker.detail.lastMeasurement", rank: .area)
            BiomarkerLastMeasurementCard(
                latest: latest,
                previous: Self.earlierValues(allRows),
                referenceLow: referenceLow,
                referenceHigh: referenceHigh
            )
        }
    }

    /// The assessment: the reference range the verdicts are made against,
    /// how many readings of the period fall inside it, and where the range
    /// comes from with its sources. It counts the server's verdicts; nothing
    /// is judged here.
    @ViewBuilder
    private var assessmentSection: some View {
        let range = BiomarkerSeries.referenceText(low: referenceLow, high: referenceHigh, unit: unit)
        let share = BiomarkerSeries.inRangeShare(windowedRows)
        if range != nil || latest?.rangeStatus.rowStatus != nil {
            HLSectionHeader("biomarker.detail.assessment", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLFactGroup {
                        if let range {
                            HLFactRow("labs.detail.reference", value: range)
                        }
                        if let share {
                            HLFactRow(
                                "labs.range.inRange",
                                value: String(localized: "biomarker.detail.inRange.count \(share.inRange) \(share.judged)")
                            )
                        }
                    }
                    // A range verdict is a medical-shaped statement: it says
                    // where the range comes from and offers the sources.
                    LabReferenceSourceLine(topic: sourcesTopic)
                }
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        if let stats = BiomarkerSeries.pageStats(for: windowedRows) {
            // The cells name themselves (Min, Ø, Max, Median), as on the
            // reference metric page; the unity "1" (#160) is never printed.
            HLStatGrid(cells: BiomarkerSeries.statCells(
                stats: stats,
                median: BiomarkerSeries.median(for: windowedRows),
                unit: LabUnit.suffix(unit) ?? ""
            ))
        }
    }

    /// The course. A single value has none: with a range it already stands
    /// on it in the card above, without one the note says why no line is
    /// drawn.
    @ViewBuilder
    private var chartSection: some View {
        if Self.showsCourseCard(allRows, low: referenceLow, high: referenceHigh) {
            BiomarkerChart(
                rows: windowedRows,
                unit: unit,
                referenceLow: referenceLow,
                referenceHigh: referenceHigh
            )
        }
    }
}

/// The navigation chrome of the marker page: the system title and the bar
/// actions when it is pushed, nothing when it stands beside the labs table.
private struct BiomarkerPageChrome: ViewModifier {
    let isEmbedded: Bool
    let title: String
    let actions: HLTabHeaderActions

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content
                .navigationTitle(Text(verbatim: title))
                .toolbarTitleDisplayMode(.inlineLarge)
                .hlPageActions(actions)
        }
    }
}

/// One reading in a marker's history: the date, the printed value of a
/// converted reading, the value and its range as quiet text. Tapping opens
/// the reading's editor.
struct LabHistoryRow: View {
    let row: LabResultDTO
    let onTap: () -> Void

    var body: some View {
        HLRowButton(action: onTap) {
            HLHistoryRow(
                date: Text(verbatim: LabsDateFormat.labDate(row.takenAt)),
                detail: LabConversion(row).convertedLine.map { Text(verbatim: $0) },
                value: Text(verbatim: row.displayValue),
                status: row.rangeStatus.rowStatus
            )
        }
    }
}

/// Every reading of the marker in the chosen period, one card of history
/// rows. The rows are read live, so an edit shows at once.
struct BiomarkerHistoryScreen: View {
    let title: String
    let store: LabsStore
    let rows: () -> [LabResultDTO]

    @State private var editingResult: LabResultDTO?

    var body: some View {
        HLPage {
            HLCard(layout: .rows) {
                ForEach(rows()) { row in
                    LabHistoryRow(row: row) { editingResult = row }
                }
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingResult) { result in
            EditLabResultSheet(store: store, result: result)
        }
    }
}

/// What the marker page's single sheet shows.
enum BiomarkerSheet: String, Identifiable {
    case editor
    case aliases
    case merge

    var id: String {
        rawValue
    }
}

// MARK: - A marker's actions

extension BiomarkerDetailScreen {
    /// The (i) and the edit of a marker, for the pushed page's bar and for
    /// the labs screen's bar beside the table. Where the server can also edit
    /// spellings and merge markers, the three edits share the more menu;
    /// otherwise the range editor is the pencil.
    /// #191 QoL — Delete stands in the more menu, away from the thumb, and
    /// asks first (the page needs ``View/hlDeleteConfirmation()``). The
    /// server deletes the marker with every reading under it.
    static func markerActions(
        marker: BiomarkerDTO?,
        analyte: String,
        sheet: Binding<BiomarkerSheet?>,
        onDelete: (@MainActor (String) async -> Void)? = nil
    ) -> [HLTabHeaderAction] {
        var items: [HLTabHeaderAction] = [.info(info(marker: marker, analyte: analyte), identifier: "biomarker.detail.info")]
        guard let marker else { return items }
        let merges = ServerFeatureMirror.shared.current?.biomarkerMerge == true
        if merges || onDelete != nil {
            items.append(.more(identifier: "biomarker.detail.gear") {
                Button("biomarker.detail.editRange") { sheet.wrappedValue = .editor }
                if merges {
                    Button("labs.aliases.edit") { sheet.wrappedValue = .aliases }
                    Button("labs.merge.open") { sheet.wrappedValue = .merge }
                }
                if let onDelete {
                    Divider()
                    HLDeleteMenuItem(.confirmed(
                        title: "biomarker.delete.confirm.title",
                        message: "biomarker.delete.removesReadings"
                    ) {
                        await onDelete(marker.id)
                    })
                    .accessibilityIdentifier("biomarker.detail.delete")
                }
            })
        } else {
            items.append(.edit(identifier: "biomarker.detail.gear") { sheet.wrappedValue = .editor })
        }
        return items
    }

    /// The values before the newest reading, oldest first, as faint points
    /// beside it on the range.
    nonisolated static func earlierValues(_ rows: [LabResultDTO]) -> [Double] {
        // `rows` is newest first; the newest is the reading itself.
        Array(rows.dropFirst().compactMap(\.value).reversed())
    }

    /// The biomarker title. A linked marker shows its catalog name; an
    /// unlinked analyte shows the analyte string verbatim.
    static func displayName(marker: BiomarkerDTO?, analyte: String) -> String {
        if let name = marker?.name, !name.isEmpty { return name }
        return analyte
    }

    /// What the (i) explains. The citations of the explainer travel with it;
    /// the reading's range verdict keeps its own visible link in the card.
    static func info(marker: BiomarkerDTO?, analyte: String) -> HLInfoContent {
        var sections: [HLInfoContent.Section] = []
        if let aliases = marker?.aliases, !aliases.isEmpty {
            sections.append(HLInfoContent.Section(
                title: String(localized: "biomarker.detail.info.aliases"),
                paragraphs: [String(localized: "labs.biomarker.aliases \(aliases.formatted(.list(type: .and)))")]
            ))
        }
        let name = marker?.name ?? analyte
        // The citation topic: the catalogue slug when the name maps to one,
        // else the shared lab reference-range topic.
        let topic: MedicalSourceTopic = BiomarkerExplainer.slug(forName: name).map { .labBiomarker($0) } ?? .labReferenceRanges
        return HLInfoContent(
            title: displayName(marker: marker, analyte: analyte),
            identifier: "biomarker.detail.info.sheet",
            about: BiomarkerExplainer.text(context: marker?.context, name: name),
            topic: topic,
            sections: sections,
            learnMoreConcept: "LAB_BIOMARKER"
        )
    }
}
