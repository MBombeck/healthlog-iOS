import SwiftUI

/// "Alle Werte" — the full, pageable value history for one custom metric, with
/// edit + delete per row. The iOS counterpart of the web's
/// `app/custom-metrics/[id]/values/page.tsx`.
///
/// Unlike the measurement + labs lists (which cap hard at 400 / 500 rows with no
/// way to reach older history — audit B9), this screen honours the server's
/// offset pagination: it loads a page at a time and offers an explicit
/// "Mehr laden" once the server-reported total exceeds what is on screen.
///
/// **Delete is HARD here.** The entry route deletes the row outright and there
/// is no restore endpoint, so this path confirms destructively and never
/// promises an undo — deliberately different from the metric-definition delete
/// on the list screen, which is a soft-delete with a real undo.
struct CustomMetricValuesScreen: View {
    let store: CustomMetricsStore
    let metricID: String

    @State private var editingEntry: CustomMetricEntryDTO?
    @State private var pendingDelete: CustomMetricEntryDTO?

    private var metric: CustomMetricDTO? {
        store.metric(id: metricID)
    }

    private var entries: [CustomMetricEntryDTO] {
        store.entries(for: metricID)
    }

    var body: some View {
        List {
            if let metric {
                Section {
                    ForEach(entries) { entry in
                        CustomMetricEntryRow(entry: entry, metric: metric)
                            .contentShape(Rectangle())
                            .onTapGesture { editingEntry = entry }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = entry
                                } label: {
                                    Label("customMetric.action.delete", systemImage: "trash")
                                }
                                Button {
                                    editingEntry = entry
                                } label: {
                                    Label("customMetric.action.edit", systemImage: "pencil")
                                }
                                .tint(HLAccent.userBrandTint)
                            }
                    }
                } header: {
                    Text("customMetric.values.count \(store.entryTotalByMetric[metricID] ?? entries.count)")
                }

                if store.hasMoreEntries(for: metricID) {
                    Section {
                        Button {
                            Task { await store.loadMoreEntries(metricID: metricID) }
                        } label: {
                            HStack {
                                Spacer()
                                Text("customMetric.values.loadMore")
                                Spacer()
                            }
                        }
                        .disabled(store.isLoadingEntries)
                        .accessibilityIdentifier("customMetric.values.loadMore")
                    }
                }
            }

            if entries.isEmpty, !store.isLoadingEntries {
                Section {
                    HLEmptyState(
                        icon: "list.bullet",
                        title: "customMetric.values.empty.title",
                        message: "customMetric.values.empty.message"
                    ) {
                        EmptyView()
                    }
                }
            }

            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoadingEntries)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        .hlScrollEdgeSoft()
        .navigationTitle(Text("customMetric.values.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadEntries(metricID: metricID) }
        .task { await store.loadEntries(metricID: metricID) }
        .sheet(item: $editingEntry) { entry in
            if let metric {
                CustomMetricEntrySheet(store: store, metric: metric, existing: entry)
            }
        }
        .hlConfirmDestructive(
            Text("customMetric.values.delete.confirm.title"),
            presenting: $pendingDelete,
            // Honest copy: this one really is permanent.
            message: { _ in Text("customMetric.values.delete.confirm.message") },
            confirm: Text("customMetric.action.delete"),
            cancel: Text("customMetric.action.cancel"),
            action: { entry in
                Task { await store.deleteEntry(metricID: metricID, entryID: entry.id) }
            }
        )
    }
}
