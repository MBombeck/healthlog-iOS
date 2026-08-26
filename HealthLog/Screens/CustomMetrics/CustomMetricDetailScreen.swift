import SwiftUI

/// The custom-metric detail page — modelled on ``BiomarkerDetailScreen`` so the
/// two "one metric over time" surfaces read identically: header with a gear that
/// opens the definition editor, an optional description, a latest-value card,
/// the Min/Ø/Max/Median stat strip, a value-over-time chart with the target band,
/// and a recent-values list with a link to the full "Alle Werte" page.
///
/// **The chart is the shared ``BiomarkerChart``**, driven through its generic
/// `points:` initialiser — same tokens, same neutral band styling, same
/// VoiceOver descriptor. No second chart implementation exists.
struct CustomMetricDetailScreen: View {
    let store: CustomMetricsStore
    let metricID: String

    @State private var range: CustomMetricSeries.Range = .month
    @State private var showEditor = false
    @State private var showEntrySheet = false
    @State private var editingEntry: CustomMetricEntryDTO?

    /// How many values the detail page lists inline before deferring to the
    /// dedicated "Alle Werte" screen.
    private static let inlinePreviewCount = 10

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

    var body: some View {
        ScrollView {
            if let metric {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    header(metric)
                    descriptionSlot(metric)
                    latestSlot(metric)
                    statsSlot
                    inBandSlot(metric)
                    chartSlot(metric)
                    recentValuesSlot(metric)
                    HLSyncStatusFooter(screenLoading: store.isLoading || store.isLoadingEntries)
                }
                .padding(HLSpace.lg)
            }
        }
        .hlScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HLFloatingPeriodControl(
                selection: $range,
                accessibilityLabelText: "customMetric.detail.range.a11y"
            )
        }
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

    // MARK: - Sections

    private func header(_ metric: CustomMetricDTO) -> some View {
        InsightsPageHeader(
            LocalizedStringKey(metric.name),
            accessibilityIdentifierSuffix: "customMetric"
        ) {
            InsightsHeaderActionCircle(
                systemImage: "plus",
                accessibilityLabelText: String(localized: "customMetric.detail.logValue"),
                accessibilityIdentifier: "customMetric.detail.add"
            ) {
                showEntrySheet = true
            }
            InsightsHeaderActionCircle(
                systemImage: "slider.horizontal.3",
                accessibilityLabelText: String(localized: "customMetric.detail.editDefinition"),
                accessibilityIdentifier: "customMetric.detail.gear"
            ) {
                showEditor = true
            }
        }
    }

    @ViewBuilder
    private func descriptionSlot(_ metric: CustomMetricDTO) -> some View {
        if let description = metric.description, !description.isEmpty {
            Text(verbatim: description)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func latestSlot(_ metric: CustomMetricDTO) -> some View {
        if let latest {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("customMetric.detail.lastValue")
                HLCard {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                        Text(verbatim: latest.displayValue(decimals: metric.decimals))
                            .font(.hlMetric(.title))
                            .monospacedDigit()
                            .foregroundStyle(HLText.primary)
                        CustomMetricBandBadge(status: latest.bandStatus(in: metric))
                        Spacer(minLength: HLSpace.sm)
                        Text(verbatim: LabsDateFormat.mediumDateTime(latest.measuredAt))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var statsSlot: some View {
        if let stats = CustomMetricSeries.stats(for: windowedEntries) {
            // No section header — `StatsRow` labels each cell itself, exactly as
            // the biomarker + Insights metric pages render it.
            StatsRow(
                stats: stats,
                median: CustomMetricSeries.median(for: windowedEntries),
                unit: metric?.unit ?? ""
            )
        }
    }

    /// "N von M im Zielbereich" — a plain count, never a score or a grade.
    @ViewBuilder
    private func inBandSlot(_ metric: CustomMetricDTO) -> some View {
        if let counts = CustomMetricSeries.inBandCount(windowedEntries, metric: metric) {
            Text("customMetric.detail.inBandCount \(counts.inBand) \(counts.total)")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            referenceHigh: metric.targetHigh
        )
    }

    @ViewBuilder
    private func recentValuesSlot(_ metric: CustomMetricDTO) -> some View {
        if !windowedEntries.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("customMetric.detail.recentValues")
                HLCard {
                    VStack(spacing: 0) {
                        ForEach(Array(windowedEntries.prefix(Self.inlinePreviewCount).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().overlay(HLColor.separator)
                            }
                            CustomMetricEntryRow(entry: entry, metric: metric)
                                .padding(.vertical, HLSpace.xs)
                                .contentShape(Rectangle())
                                .onTapGesture { editingEntry = entry }
                        }
                    }
                }
                NavigationLink {
                    CustomMetricValuesScreen(store: store, metricID: metricID)
                } label: {
                    Text("customMetric.detail.allValues \(store.entryTotalByMetric[metricID] ?? allEntries.count)")
                        .font(.hlSubhead)
                }
                .accessibilityIdentifier("customMetric.detail.allValues")
            }
        }
    }
}

// MARK: - Entry row

/// One logged value: date + note on the left, value + band badge on the right.
/// Renders the entry's OWN snapshotted unit — a later unit rename must not
/// relabel history.
struct CustomMetricEntryRow: View {
    let entry: CustomMetricEntryDTO
    let metric: CustomMetricDTO

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(verbatim: LabsDateFormat.mediumDateTime(entry.measuredAt))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                if let note = entry.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: HLSpace.sm)
            VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                Text(verbatim: entry.displayValue(decimals: metric.decimals))
                    .font(.hlMetric(.body))
                    .monospacedDigit()
                    .foregroundStyle(HLText.primary)
                CustomMetricBandBadge(status: entry.bandStatus(in: metric))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
