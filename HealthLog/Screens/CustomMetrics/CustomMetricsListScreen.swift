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
    @State private var pendingDelete: CustomMetricDTO?

    var body: some View {
        List {
            if store.metrics.isEmpty, !store.isLoading {
                Section { emptyState }
            } else {
                Section {
                    ForEach(store.metrics) { metric in
                        NavigationLink {
                            CustomMetricDetailScreen(store: store, metricID: metric.id)
                        } label: {
                            CustomMetricRow(metric: metric)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = metric
                            } label: {
                                Label("customMetric.action.delete", systemImage: "trash")
                            }
                            Button {
                                editingMetric = metric
                            } label: {
                                Label("customMetric.action.edit", systemImage: "slider.horizontal.3")
                            }
                            .tint(HLAccent.userBrandTint)
                        }
                    }
                } footer: {
                    Text("customMetric.list.footer")
                }
            }
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        .hlScrollEdgeSoft()
        .navigationTitle(Text("customMetric.list.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditor = true
                } label: {
                    Label("customMetric.action.add", systemImage: "plus")
                }
                .accessibilityIdentifier("customMetric.list.add")
            }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .sheet(isPresented: $showEditor) {
            CustomMetricEditorSheet(store: store, existing: nil)
        }
        .sheet(item: $editingMetric) { metric in
            CustomMetricEditorSheet(store: store, existing: metric)
        }
        .hlConfirmDestructive(
            Text("customMetric.delete.confirm.title"),
            presenting: $pendingDelete,
            // The values survive the delete server-side and a same-name
            // re-create revives them — say so, rather than implying data loss.
            message: { _ in Text("customMetric.delete.confirm.message") },
            confirm: Text("customMetric.action.delete"),
            cancel: Text("customMetric.action.cancel"),
            action: { metric in
                Task {
                    await store.deleteMetric(
                        id: metric.id,
                        undoMessage: String(localized: "customMetric.delete.undo")
                    )
                }
            }
        )
    }

    private var emptyState: some View {
        HLEmptyState(
            icon: "chart.line.uptrend.xyaxis",
            title: "customMetric.empty.title",
            message: "customMetric.empty.message"
        ) {
            HLButton("customMetric.action.add", icon: "plus", variant: .primary) {
                showEditor = true
            }
        }
    }
}

// MARK: - Row

/// One custom-metric row: name + target band on the left, the latest value and
/// its band status on the right.
struct CustomMetricRow: View {
    let metric: CustomMetricDTO

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(verbatim: metric.name)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer(minLength: HLSpace.sm)
            VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                Text(verbatim: metric.latestDisplayValue)
                    .font(.hlMetric(.title3))
                    .monospacedDigit()
                    .foregroundStyle(HLText.primary)
                CustomMetricBandBadge(status: metric.latestBandStatus)
            }
        }
        .padding(.vertical, HLSpace.xs)
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

/// Calm, NON-critical badge for a value's position in its target window.
///
/// Deliberately mirrors `LabRangeBadge`'s tone doctrine: `below` / `above` are
/// `.info`, never `.critical`. This is the user's own goal band, not a clinical
/// threshold — an out-of-band value is information, not an alarm.
struct CustomMetricBandBadge: View {
    let status: CustomMetricBandStatus

    var body: some View {
        if status != .unknown {
            HLBadge(label, tone: tone)
        }
    }

    private var label: String {
        switch status {
        case .inBand: String(localized: "customMetric.band.inBand")
        case .below: String(localized: "customMetric.band.below")
        case .above: String(localized: "customMetric.band.above")
        case .unknown: ""
        }
    }

    private var tone: HLBadge.Tone {
        switch status {
        case .inBand: .success
        case .below, .above: .info
        case .unknown: .neutral
        }
    }
}
