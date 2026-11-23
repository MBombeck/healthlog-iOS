import SwiftUI

/// "Eigene Metriken" — the list of the user's custom metric definitions, each
/// with its latest logged value.
///
/// Mounted below the Measurements surface, mirroring where the web hangs it
/// (`app/measurements/page.tsx:172` renders `<CustomMetricList />` under the
/// measurement list). Tapping a row pushes ``CustomMetricDetailScreen``.
///
/// **No module gate** — the server routes carry none (verified in the route
/// files), so this surface is unconditionally available.
struct CustomMetricsListScreen: View {
    let store: CustomMetricsStore

    @State private var showEditor = false
    @State private var editingMetric: CustomMetricDTO?

    var body: some View {
        List {
            if store.metrics.isEmpty, !store.isLoading {
                if Self.showsLoadFailure(isEmpty: true, isLoading: false, lastError: store.lastError) {
                    // A list that failed to load is not an empty one: no
                    // invitation to create a first metric, but a retry.
                    HLAsyncListErrorRow(retry: { await store.load() })
                } else {
                    // The lockup stands on the list, not on a row card.
                    Section { emptyState.listRowBackground(Color.clear) }
                }
            } else {
                Section {
                    ForEach(store.metrics) { metric in
                        // A data row: the whole row pushes the detail, no chevron.
                        CustomMetricRow(metric: metric)
                            .hlRowLink(inList: true) {
                                CustomMetricDetailScreen(store: store, metricID: metric.id)
                            }
                            // A metric is a container of values: it asks first.
                            .hlSwipeDelete(.confirmed(
                                title: "customMetric.delete.confirm.title",
                                message: "customMetric.delete.confirm.message"
                            ) {
                                await store.deleteMetric(
                                    id: metric.id,
                                    undoMessage: String(localized: "customMetric.delete.undo")
                                )
                            }) {
                                Button("customMetric.action.edit", systemImage: "slider.horizontal.3") {
                                    editingMetric = metric
                                }
                                .tint(HLAccent.userBrandTint)
                            }
                    }
                } footer: {
                    Text("customMetric.list.footer")
                }
                .hlFormRowSurface()
            }
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .hlPageMargins()
        .hlScrollEdgeSoft()
        .navigationTitle(Text("customMetric.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .add(label: "customMetric.action.add", identifier: "customMetric.list.add") {
                showEditor = true
            }
        ])
        .refreshable { await store.load() }
        .task { await store.load() }
        .sheet(isPresented: $showEditor) {
            CustomMetricEditorSheet(store: store, existing: nil)
        }
        .sheet(item: $editingMetric) { metric in
            CustomMetricEditorSheet(store: store, existing: metric)
        }
    }

    /// Nothing to show because the request failed, rather than because there
    /// is nothing.
    nonisolated static func showsLoadFailure(isEmpty: Bool, isLoading: Bool, lastError: String?) -> Bool {
        isEmpty && !isLoading && lastError != nil
    }

    /// No button: the plus in the bar creates the first metric (Z31).
    private var emptyState: some View {
        HLEmptyState(
            icon: "chart.line.uptrend.xyaxis",
            title: "customMetric.empty.title",
            message: "customMetric.empty.message"
        )
    }
}

// MARK: - Row

/// One custom-metric row: name and last date (or target band) on the left,
/// the latest value with its band as a quiet status text on the right.
struct CustomMetricRow: View {
    let metric: CustomMetricDTO

    var body: some View {
        HLRow(
            title: Text(verbatim: metric.name),
            detail: subtitle.map { Text(verbatim: $0) },
            value: Text(verbatim: metric.latestDisplayValue),
            status: CustomMetricBandBadge.rowStatus(metric.latestBandStatus)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Sub-line: the last measurement date, else the target band, else nothing.
    /// The date is the more useful of the two once values exist — it answers
    /// "is this current?", which is what a list glance is for.
    private var subtitle: String? {
        if let measuredAt = metric.latest?.measuredAt, !measuredAt.isEmpty {
            return LabsDateFormat.mediumDate(measuredAt)
        }
        return metric.targetBandDescription
    }

    private var accessibilityText: Text {
        guard metric.latest != nil else {
            return Text("customMetric.row.a11y.noValues \(metric.name)")
        }
        return Text("customMetric.row.a11y \(metric.name) \(metric.latestDisplayValue)")
    }
}

// MARK: - Band badge

/// Calm, NON-critical badge for a value's position in its target window: a
/// capsule in the detail head, a status text (`rowStatus`) in rows.
///
/// Deliberately mirrors `LabRangeBadge`'s tone doctrine: `below` / `above` are
/// `.info`, never `.critical`. This is the user's own goal band, not a clinical
/// threshold — an out-of-band value is information, not an alarm.
struct CustomMetricBandBadge: View {
    let status: CustomMetricBandStatus

    var body: some View {
        if status != .unknown {
            HLBadge(Self.label(status), tone: Self.tone(status))
        }
    }

    /// The same band as a row's status text; nothing when the band is unknown.
    static func rowStatus(_ status: CustomMetricBandStatus) -> HLRowStatus? {
        status == .unknown ? nil : HLRowStatus(label(status), tone: tone(status))
    }

    static func label(_ status: CustomMetricBandStatus) -> String {
        switch status {
        case .inBand: String(localized: "customMetric.band.inBand")
        case .below: String(localized: "customMetric.band.below")
        case .above: String(localized: "customMetric.band.above")
        case .unknown: ""
        }
    }

    static func tone(_ status: CustomMetricBandStatus) -> HLBadge.Tone {
        switch status {
        case .inBand: .success
        case .below, .above: .info
        case .unknown: .neutral
        }
    }
}
