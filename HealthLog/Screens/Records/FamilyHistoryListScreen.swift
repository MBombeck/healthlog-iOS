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
        .navigationTitle(Text("familyHistory.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddSheet = true
            } label: {
                Label("familyHistory.add.title", systemImage: "plus")
            }
            .accessibilityIdentifier("familyHistory.toolbar.add")
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
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    private func row(_ record: FamilyHistoryEntryDTO, store: FamilyHistoryStore) -> some View {
        Button {
            editingRecord = record
        } label: {
            FamilyHistoryRow(record: record)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.delete(record, undoMessage: String(localized: "familyHistory.delete.undo"))
            } label: {
                Label("familyHistory.delete.action", systemImage: "trash")
            }
            Button {
                editingRecord = record
            } label: {
                Label("familyHistory.edit.action", systemImage: "pencil")
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
            ) {
                HLButton("familyHistory.add.title", icon: "plus", variant: .primary) {
                    showAddSheet = true
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
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

/// Single family-history list row: relationship + condition + optional
/// age-at-onset caption + a note glyph when a note exists.
struct FamilyHistoryRow: View {
    let record: FamilyHistoryEntryDTO

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.xs) {
                Text(record.condition)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if record.note?.isEmpty == false {
                    Image(systemName: "note.text")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: HLSpace.xs) {
                HLBadge(record.relationship.localizedLabel, tone: .neutral)
                if let age = record.ageAtOnset {
                    Text(ageCaption(age))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .padding(.vertical, HLSpace.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func ageCaption(_ age: Int) -> String {
        String(format: String(localized: "familyHistory.row.ageAtOnset"), age)
    }

    private var accessibilityText: String {
        let template = String(localized: "familyHistory.row.a11y")
        return String(format: template, record.relationship.localizedLabel, record.condition)
    }
}
