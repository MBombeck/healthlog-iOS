import SwiftUI

/// Native family-history records surface (v1.25 `W-RECORDS`; FHIR
/// `FamilyMemberHistory`). Lists entries newest-first (relationship + condition +
/// optional age-at-onset); toolbar "+" adds, tapping a row edits, a trailing
/// swipe deletes with a deferred-undo. Reached from the "Family history"
/// `MoreScreen` clinical-spine row.
struct FamilyHistoryListScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: FamilyHistoryStore?
    @State private var showAddSheet = false
    @State private var editingRecord: FamilyHistoryEntryDTO?

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows() },
            empty: { emptyRows },
            content: { if let store { loadedRows(store: store) } }
        )
        .hlPageMargins()
        .navigationTitle(Text("familyHistory.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .add(label: "familyHistory.add.title", identifier: "familyHistory.toolbar.add") { showAddSheet = true }
        ])
        .task { await onAppear() }
        .sheet(isPresented: $showAddSheet) {
            if let store {
                FamilyHistoryEditorSheet(store: store, record: nil)
            }
        }
        .sheet(item: $editingRecord) { record in
            if let store {
                FamilyHistoryEditorSheet(store: store, record: record)
            }
        }
    }

    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.records.isEmpty {
            if store.isLoading { return .loading }
            if store.lastError != nil { return .error(retry: { await reload() }) }
            return .empty
        }
        return .loaded
    }

    @ViewBuilder
    private func loadedRows(store: FamilyHistoryStore) -> some View {
        Section {
            ForEach(store.records) { record in
                row(record, store: store)
            }
        }
        .hlFormRowSurface()
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        .hlFormRowSurface()
    }

    private func row(_ record: FamilyHistoryEntryDTO, store: FamilyHistoryStore) -> some View {
        HLRowButton {
            editingRecord = record
        } label: {
            FamilyHistoryRow(record: record)
        }
        // The store keeps the way back, so the row goes at once with the
        // undo hint.
        .hlSwipeDelete(.undoable {
            store.delete(record, undoMessage: String(localized: "familyHistory.delete.undo"))
        }) {
            Button("familyHistory.edit.action", systemImage: "pencil") {
                editingRecord = record
            }
            .tint(HLAccent.userBrandTint)
        }
    }

    private var emptyRows: some View {
        Section {
            HLEmptyState(
                icon: "figure.2.and.child.holdinghands",
                title: "familyHistory.empty.title",
                message: "familyHistory.empty.subtitle"
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .hlFormRowSurface()
    }

    private func onAppear() async {
        if store == nil {
            store = container?.familyHistoryStore
        }
        await reload()
    }

    private func reload() async {
        await store?.load()
    }
}

/// Single family-history list row: the condition, and one detail line with
/// the relative and the age at onset.
struct FamilyHistoryRow: View {
    let record: FamilyHistoryEntryDTO

    var body: some View {
        HLRow(
            title: Text(verbatim: record.condition),
            detail: HLRowDetail.text(RecordsRowContent.familyDetailParts(record))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let template = String(localized: "familyHistory.row.a11y")
        return String(format: template, record.relationship.localizedLabel, record.condition)
    }
}
