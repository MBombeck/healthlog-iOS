import SwiftUI

/// Native allergy / intolerance records surface (v1.25 `W-RECORDS`; FHIR
/// `AllergyIntolerance`). Lists records newest-first with neutral category /
/// severity / status badges; a toolbar "+" presents the add sheet, tapping a row
/// opens the edit sheet, and a trailing swipe deletes with a deferred-undo
/// (no restore endpoint — the network delete fires only after the undo window).
///
/// Reached from the (default-on) "Allergies" `MoreScreen` clinical-spine row.
/// Mirrors `IllnessJournalScreen`: a stable `HLAsyncListScreen` scroll root.
struct AllergiesListScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: AllergiesStore?
    @State private var showAddSheet = false
    @State private var editingRecord: AllergyDTO?
    @State private var includeInactive = true

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows() },
            empty: { emptyRows },
            content: { if let store { loadedRows(store: store) } }
        )
        .hlPageMargins()
        .navigationTitle(Text("allergies.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .add(label: "allergies.add.title", identifier: "allergies.toolbar.add") { showAddSheet = true }
        ])
        .task { await onAppear() }
        .sheet(isPresented: $showAddSheet) {
            if let store {
                AllergyEditorSheet(store: store, record: nil)
            }
        }
        .sheet(item: $editingRecord) { record in
            if let store {
                AllergyEditorSheet(store: store, record: record)
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
    private func loadedRows(store: AllergiesStore) -> some View {
        Section {
            Toggle(isOn: $includeInactive) {
                HLRowTitle("allergies.list.showInactive")
            }
            .onChange(of: includeInactive) { _, _ in
                Task { await reload() }
            }
            .accessibilityIdentifier("allergies.list.showInactiveToggle")
        }
        .hlFormRowSurface()
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

    private func row(_ record: AllergyDTO, store: AllergiesStore) -> some View {
        HLRowButton {
            editingRecord = record
        } label: {
            AllergyRow(record: record)
        }
        // The store keeps the way back, so the row goes at once with the
        // undo hint.
        .hlSwipeDelete(.undoable {
            store.delete(record, undoMessage: String(localized: "allergies.delete.undo"))
        }) {
            Button("allergies.edit.action", systemImage: "pencil") {
                editingRecord = record
            }
            .tint(HLAccent.userBrandTint)
        }
    }

    private var emptyRows: some View {
        Section {
            HLEmptyState(
                icon: "allergens",
                title: "allergies.empty.title",
                message: "allergies.empty.subtitle"
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .hlFormRowSurface()
    }

    private func onAppear() async {
        if store == nil {
            store = container?.allergiesStore
        }
        await reload()
    }

    private func reload() async {
        await store?.load(includeInactive: includeInactive)
    }
}

/// Single allergy list row: the substance, one detail line (type, category,
/// severity) and, for a record that is no longer active, its status as text.
struct AllergyRow: View {
    let record: AllergyDTO

    var body: some View {
        HLRow(
            title: Text(verbatim: record.substance),
            detail: HLRowDetail.text(RecordsRowContent.allergyDetailParts(record)),
            status: RecordsRowContent.allergyStatus(record).map { HLRowStatus($0) }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let template = String(localized: "allergies.row.a11y")
        return String(format: template, record.substance, record.category.localizedLabel, record.type.localizedLabel)
    }
}
