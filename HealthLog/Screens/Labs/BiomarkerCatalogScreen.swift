import SwiftUI

/// The user's biomarker catalog, reached from the ``LabsScreen`` toolbar.
/// Name-ordered list with create / edit / delete. Deleting a marker keeps the
/// lab history (the server `onDelete: SetNull` unlinks readings, which keep
/// their legacy analyte/unit) — the confirmation copy says so explicitly.
struct BiomarkerCatalogScreen: View {
    let store: LabsStore

    @State private var showAddSheet = false
    @State private var editingMarker: BiomarkerDTO?
    @State private var deletingMarker: BiomarkerDTO?

    private var sortedMarkers: [BiomarkerDTO] {
        store.biomarkers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Build 3 / item 3.2 — the ACTIVE catalog. A hidden marker still exists
    /// and still owns its readings; it just stops being offered.
    private var visibleMarkers: [BiomarkerDTO] {
        sortedMarkers.filter { !$0.hidden }
    }

    /// Hidden markers, rendered in their own section so the operator can find
    /// and un-hide one. Mirrors the web manager, which sorts
    /// `[{ hidden: "asc" }, { name: "asc" }]` and renders two sections.
    private var hiddenMarkers: [BiomarkerDTO] {
        sortedMarkers.filter(\.hidden)
    }

    var body: some View {
        Group {
            if sortedMarkers.isEmpty, !store.isLoading {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(visibleMarkers) { marker in
                            markerRow(marker)
                        }
                    }
                    if !hiddenMarkers.isEmpty {
                        Section {
                            ForEach(hiddenMarkers) { marker in
                                markerRow(marker)
                            }
                        } header: {
                            Text("biomarker.catalog.hidden.section")
                        } footer: {
                            Text("biomarker.catalog.hidden.footer")
                        }
                    }
                    Section {} footer: {
                        HLSyncStatusFooter(screenLoading: store.isLoading)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.reloadBiomarkers() }
            }
        }
        .navigationTitle(Text("biomarker.catalog.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("biomarker.add.title", systemImage: "plus")
                }
                .accessibilityIdentifier("biomarker.toolbar.add")
            }
        }
        .task { await store.reloadBiomarkers() }
        .sheet(isPresented: $showAddSheet) {
            BiomarkerEditorSheet(store: store, existing: nil)
        }
        .sheet(item: $editingMarker) { marker in
            BiomarkerEditorSheet(store: store, existing: marker)
        }
        .hlConfirmDestructive(
            Text("biomarker.delete.confirm.title"),
            isPresented: deleteBinding,
            message: Text("biomarker.delete.keepsHistory"),
            confirm: Text("labs.delete.action"),
            cancel: Text("labs.action.cancel"),
            onCancel: { deletingMarker = nil },
            action: {
                if let marker = deletingMarker {
                    Task { await store.deleteBiomarker(id: marker.id) }
                }
                deletingMarker = nil
            }
        )
    }

    /// One catalog row — extracted so the visible and hidden sections stay
    /// literally identical in behaviour (tap to edit, swipe to delete). A
    /// hidden marker is still fully editable; that is how you un-hide it.
    private func markerRow(_ marker: BiomarkerDTO) -> some View {
        Button {
            editingMarker = marker
        } label: {
            BiomarkerRow(marker: marker)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingMarker = marker
            } label: {
                Label("labs.delete.action", systemImage: "trash")
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deletingMarker != nil },
            set: { if !$0 { deletingMarker = nil } }
        )
    }

    private var emptyState: some View {
        ScrollView {
            HLCard(style: .ghost) {
                HLEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "biomarker.empty.title",
                    message: "biomarker.empty.subtitle"
                ) {
                    HLButton("biomarker.add.title", icon: "plus", variant: .primary) {
                        showAddSheet = true
                    }
                }
            }
            .padding(HLSpace.lg)
        }
        .refreshable { await store.reloadBiomarkers() }
    }
}

struct BiomarkerRow: View {
    let marker: BiomarkerDTO

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(marker.name)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if let panel = marker.panel, !panel.isEmpty {
                    Text(panel)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer(minLength: HLSpace.sm)
            VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                Text(marker.unit)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                if let range = rangeLabel {
                    Text(range)
                        .font(.hlCaption)
                        .monospacedDigit()
                        .foregroundStyle(HLText.tertiary)
                }
            }
            HLDisclosureChevron()
        }
        .padding(.vertical, HLSpace.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rangeLabel: String? {
        switch (marker.lowerBound, marker.upperBound) {
        case let (low?, high?): "\(low.formatted())–\(high.formatted())"
        case let (low?, nil): "≥ \(low.formatted())"
        case let (nil, high?): "≤ \(high.formatted())"
        case (nil, nil): nil
        }
    }
}
