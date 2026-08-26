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
        .navigationTitle(Text("allergies.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddSheet = true
            } label: {
                Label("allergies.add.title", systemImage: "plus")
            }
            .accessibilityIdentifier("allergies.toolbar.add")
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
            Toggle("allergies.list.showInactive", isOn: $includeInactive)
                .onChange(of: includeInactive) { _, _ in
                    Task { await reload() }
                }
                .accessibilityIdentifier("allergies.list.showInactiveToggle")
        }
        Section {
            ForEach(store.records) { record in
                row(record, store: store)
            }
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    private func row(_ record: AllergyDTO, store: AllergiesStore) -> some View {
        Button {
            editingRecord = record
        } label: {
            AllergyRow(record: record)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.delete(record, undoMessage: String(localized: "allergies.delete.undo"))
            } label: {
                Label("allergies.delete.action", systemImage: "trash")
            }
            Button {
                editingRecord = record
            } label: {
                Label("allergies.edit.action", systemImage: "pencil")
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
            ) {
                HLButton("allergies.add.title", icon: "plus", variant: .primary) {
                    showAddSheet = true
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
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

/// Single allergy list row: substance + category/severity/status badges + an
/// optional note glyph (a reaction / note exists). Neutral badges only.
struct AllergyRow: View {
    let record: AllergyDTO

    private var hasFreeText: Bool {
        record.reaction?.isEmpty == false || record.note?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.xs) {
                Text(record.substance)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if hasFreeText {
                    Image(systemName: "note.text")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: HLSpace.xs) {
                HLBadge(record.category.localizedLabel, tone: .neutral)
                if let severity = record.severity {
                    HLBadge(severity.localizedLabel, tone: .info)
                }
                if record.status != .active {
                    HLBadge(record.status.localizedLabel, tone: .neutral)
                }
            }
        }
        .padding(.vertical, HLSpace.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let template = String(localized: "allergies.row.a11y")
        return String(format: template, record.substance, record.category.localizedLabel, record.type.localizedLabel)
    }
}
