import SwiftUI

/// The custom-metric detail page in the section order of the Insights metric
/// pages: title, latest value, Min/Ø/Max/Median, the chart with the target
/// band, the latest values with the way to all of them, and the description
/// last as background. Log and edit live in the system bar of the pushed page.
///
/// **The chart is the shared ``BiomarkerChart``**, driven through its generic
/// `points:` initialiser — same tokens, same neutral band styling, same
/// VoiceOver descriptor. No second chart implementation exists.
struct CustomMetricDetailScreen: View {
    let store: CustomMetricsStore
    let metricID: String

    @State private var range: CustomMetricSeries.Range = .standard
    @State private var showEditor = false
    @State private var showEntrySheet = false
    @State private var editingEntry: CustomMetricEntryDTO?

    /// How many values the detail page lists inline before the drill row to
    /// the dedicated "Alle Werte" screen.
    static let inlinePreviewCount = 5

    /// The live definition, re-read from the store so an edit repaints here.
    private var metric: CustomMetricDTO? {
        store.metric(id: metricID)
    }

    /// All loaded values, newest-first.
    private var allEntries: [CustomMetricEntryDTO] {
        store.entries(for: metricID)
    }

    /// Values inside the selected window — drives stats, chart and the preview.
    private var windowedEntries: [CustomMetricEntryDTO] {
        CustomMetricSeries.windowed(allEntries, range: range)
    }

    private var latest: CustomMetricEntryDTO? {
        allEntries.first
    }

    /// Failed when the values did not load and none are left to show;
    /// otherwise the slots draw what there is, an empty chart included.
    private var valuesPhase: HLLoadPhase {
        let failed = CustomMetricsListScreen.showsLoadFailure(
            isEmpty: allEntries.isEmpty, isLoading: store.isLoadingEntries, lastError: store.lastError
        )
        guard failed else { return .loaded }
        return .error(retry: { await store.loadEntries(metricID: metricID) })
    }

    var body: some View {
        HLPage {
            if let metric {
                header(metric)
                // The values did not load: say so instead of an empty chart.
                HLStateContainer(valuesPhase) {
                    EmptyView()
                } empty: {
                    EmptyView()
                } content: {
                    // The order of every metric page: the latest value, the
                    // key figures as tiles, then the chart.
                    latestSlot(metric)
                    statsSlot
                    chartSlot(metric)
                    recentValuesSlot(metric)
                }
                descriptionSlot(metric)
                HLSyncStatusFooter(screenLoading: store.isLoading || store.isLoadingEntries)
            }
        }
        // The header in the content carries the title; the bar stays compact
        // and holds the back button and the page's actions.
        .navigationBarTitleDisplayMode(.inline)
        // Editing the definition is an entry of "More"; logging a value is
        // the plus at the trailing edge.
        .hlPageActions(pageActions)
        // The period bar of every detail page, floating at the bottom edge.
        .hlPeriodBar(selection: $range, label: "customMetric.detail.range.a11y")
        .task { await store.loadEntries(metricID: metricID) }
        .refreshable {
            await store.load()
            await store.loadEntries(metricID: metricID)
        }
        .sheet(isPresented: $showEditor) {
            if let metric {
                CustomMetricEditorSheet(store: store, existing: metric)
            }
        }
        .sheet(isPresented: $showEntrySheet) {
            if let metric {
                CustomMetricEntrySheet(store: store, metric: metric)
            }
        }
        .sheet(item: $editingEntry) { entry in
            if let metric {
                CustomMetricEntrySheet(store: store, metric: metric, existing: entry)
            }
        }
    }

    private var pageActions: HLTabHeaderActions {
        Self.pageActions(
            hasMetric: metric != nil,
            editDefinition: { showEditor = true },
            logValue: { showEntrySheet = true }
        )
    }

    /// Logging a value is the plus at the trailing edge; editing the
    /// definition is an entry of "More", never the page-setting slider.
    static func pageActions(
        hasMetric: Bool,
        editDefinition: @escaping () -> Void,
        logValue: @escaping () -> Void
    ) -> HLTabHeaderActions {
        guard hasMetric else { return .none }
        return [
            .more(identifier: "customMetric.detail.more") {
                Button("customMetric.detail.editDefinition", systemImage: "pencil", action: editDefinition)
                    .accessibilityIdentifier("customMetric.detail.gear")
            },
            .add(label: "customMetric.detail.logValue", identifier: "customMetric.detail.add", action: logValue)
        ]
    }

    // MARK: - Sections

    private func header(_ metric: CustomMetricDTO) -> some View {
        HLTabHeader(
            LocalizedStringResource(String.LocalizationValue(metric.name)),
            titleIdentifier: "insights.page.header.title.customMetric",
            actions: .none
        )
    }

    @ViewBuilder
    private func descriptionSlot(_ metric: CustomMetricDTO) -> some View {
        if let description = metric.description, !description.isEmpty {
            HLSectionHeader("About", rank: .area)
            HLCard {
                Text(verbatim: description)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func latestSlot(_ metric: CustomMetricDTO) -> some View {
        if let latest {
            HLSectionHeader("customMetric.detail.lastValue", rank: .area)
            HLCard {
                HStack(alignment: .top, spacing: HLSpace.sm) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        // The entry's own unit snapshot, as everywhere else.
                        HLValueText(
                            latest.value,
                            unit: HLUnit(symbol: latest.unit),
                            size: .hero,
                            fractionDigits: CustomMetricSeries.fractionDigits(decimals: metric.decimals)
                        )
                        Text(verbatim: LabsDateFormat.mediumDateTime(latest.measuredAt))
                            .hlText(.factLabel)
                    }
                    Spacer(minLength: HLSpace.sm)
                    CustomMetricBandBadge(status: latest.bandStatus(in: metric))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var statsSlot: some View {
        if let stats = CustomMetricSeries.stats(for: windowedEntries) {
            // No section header: `StatsRow` labels each tile itself, exactly
            // as the biomarker and Insights metric pages render it.
            StatsRow(
                stats: stats,
                median: CustomMetricSeries.median(for: windowedEntries),
                unit: metric?.unit ?? ""
            )
        }
    }

    /// "N von M im Zielbereich" — a plain count, never a score or a grade.
    /// The chart card's one line, under the band it counts against,
    /// instead of a loose line between the stats and the chart.
    private func inBandCaption(_ metric: CustomMetricDTO) -> String? {
        CustomMetricSeries.inBandCount(windowedEntries, metric: metric).map { counts in
            String(localized: "customMetric.detail.inBandCount \(counts.inBand) \(counts.total)")
        }
    }

    /// The shared chart, fed through its generic points initialiser. The target
    /// band rides in on the `reference*` parameters — the render contract there
    /// is already "calm graphite rail, never a verdict", which is exactly what a
    /// self-set goal band should look like.
    private func chartSlot(_ metric: CustomMetricDTO) -> some View {
        BiomarkerChart(
            points: CustomMetricSeries.chartPoints(windowedEntries),
            unit: metric.unit,
            referenceLow: metric.targetLow,
            referenceHigh: metric.targetHigh,
            caption: inBandCaption(metric)
        )
    }

    @ViewBuilder
    private func recentValuesSlot(_ metric: CustomMetricDTO) -> some View {
        if !windowedEntries.isEmpty {
            HLSectionHeader("customMetric.detail.recentValues", rank: .area)
            HLCard(layout: .rows) {
                ForEach(windowedEntries.prefix(Self.inlinePreviewCount)) { entry in
                    // A tap edits the value, as before; no chevron on a data row.
                    HLRowButton {
                        editingEntry = entry
                    } label: {
                        CustomMetricEntryRow(entry: entry, metric: metric)
                    }
                }
                // The count of the chosen period, like every drill row; the
                // list behind it holds all values.
                HLDrillRow(
                    "Show all measurements",
                    count: windowedEntries.count,
                    hasEntriesOutsidePeriod: !allEntries.isEmpty
                )
                .hlRowLink {
                    CustomMetricValuesScreen(store: store, metricID: metricID)
                }
                .accessibilityIdentifier("customMetric.detail.allValues")
            }
        }
    }
}

// MARK: - Entry row

/// One logged value as a history row: date and time, the note in the detail
/// line, the value with its band as a status text. Renders the entry's OWN
/// snapshotted unit — a later unit rename must not relabel history.
struct CustomMetricEntryRow: View {
    let entry: CustomMetricEntryDTO
    let metric: CustomMetricDTO

    var body: some View {
        HLHistoryRow(
            date: Text(verbatim: LabsDateFormat.mediumDateTime(entry.measuredAt)),
            detail: HLRowDetail.text([entry.note]),
            value: Text(verbatim: entry.displayValue(decimals: metric.decimals)),
            status: CustomMetricBandBadge.rowStatus(entry.bandStatus(in: metric))
        )
    }
}
