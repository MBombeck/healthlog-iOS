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
                        // The whole row edits the value, with press feedback.
                        HLRowButton {
                            editingEntry = entry
                        } label: {
                            CustomMetricEntryRow(entry: entry, metric: metric)
                        }
                        // The entry delete is permanent, so it asks first.
                        .hlSwipeDelete(.confirmed(
                            title: "customMetric.values.delete.confirm.title",
                            message: "customMetric.values.delete.confirm.message"
                        ) {
                            _ = await store.deleteEntry(metricID: metricID, entryID: entry.id)
                        }) {
                            Button("customMetric.action.edit", systemImage: "pencil") {
                                editingEntry = entry
                            }
                            .tint(HLAccent.userBrandTint)
                        }
                    }
                } header: {
                    HLSectionHeader("customMetric.values.count \(store.entryTotalByMetric[metricID] ?? entries.count)")
                }
                .hlFormRowSurface()

                if store.hasMoreEntries(for: metricID) {
                    Section {
                        HLLoadMoreRow(hasMore: true, isLoading: store.isLoadingEntries) {
                            Task { await store.loadMoreEntries(metricID: metricID) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("customMetric.values.loadMore")
                    }
                }
            }

            if CustomMetricsListScreen.showsLoadFailure(
                isEmpty: entries.isEmpty, isLoading: store.isLoadingEntries, lastError: store.lastError
            ) {
                HLAsyncListErrorRow(retry: { await store.loadEntries(metricID: metricID) })
            } else if entries.isEmpty, !store.isLoadingEntries {
                Section {
                    // The title only; a call to log without a
                    // button on this screen was a dead end.
                    HLEmptyState(
                        icon: "list.bullet",
                        title: "customMetric.values.empty.title"
                    )
                }
            }

            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoadingEntries)
            }
        }
        .listStyle(.insetGrouped)
        .hlPageMargins()
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
    }
}
