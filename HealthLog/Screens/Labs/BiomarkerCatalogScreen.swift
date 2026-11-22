import SwiftUI

/// The user's biomarker catalog, reached from the ``LabsScreen`` toolbar.
/// Name-ordered list with create / edit / delete. Deleting a marker keeps the
/// lab history (the server `onDelete: SetNull` unlinks readings, which keep
/// their legacy analyte/unit) — the confirmation copy says so explicitly.
struct BiomarkerCatalogScreen: View {
    let store: LabsStore

    @State private var showAddSheet = false
    @State private var editingMarker: BiomarkerDTO?

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
                    .hlFormRowSurface()
                    if !hiddenMarkers.isEmpty {
                        Section {
                            ForEach(hiddenMarkers) { marker in
                                markerRow(marker)
                            }
                        } header: {
                            // Header only: what "hidden" means is
                            // the editor's toggle line, one tap away.
                            HLSectionHeader("biomarker.catalog.hidden.section", rank: .group)
                        }
                        .hlFormRowSurface()
                    }
                    Section {} footer: {
                        HLSyncStatusFooter(screenLoading: store.isLoading)
                    }
                }
                .listStyle(.insetGrouped)
                .hlPageMargins()
                .refreshable { await store.reloadBiomarkers() }
            }
        }
        .navigationTitle(Text("biomarker.catalog.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .add(label: "biomarker.add.title", identifier: "biomarker.toolbar.add") { showAddSheet = true }
        ])
        .task { await store.reloadBiomarkers() }
        .sheet(isPresented: $showAddSheet) {
            BiomarkerEditorSheet(store: store, existing: nil)
        }
        .sheet(item: $editingMarker) { marker in
            BiomarkerEditorSheet(store: store, existing: marker)
        }
    }

    /// One catalog row — extracted so the visible and hidden sections stay
    /// literally identical in behaviour (tap to edit, swipe to delete). A
    /// hidden marker is still fully editable; that is how you un-hide it.
    private func markerRow(_ marker: BiomarkerDTO) -> some View {
        HLRowButton {
            editingMarker = marker
        } label: {
            BiomarkerRow(marker: marker)
        }
        // A marker is a container: asked first, its readings stay.
        .hlSwipeDelete(.confirmed(
            title: "biomarker.delete.confirm.title",
            message: "biomarker.delete.keepsHistory"
        ) {
            await store.deleteBiomarker(id: marker.id)
        })
    }

    private var emptyState: some View {
        // The one empty-state form: on the page, no ghost card; its one
        // action adds the first marker, the plus in the bar stays.
        HLPage {
            HLEmptyState(
                icon: "list.bullet.rectangle",
                title: "biomarker.empty.title",
                message: "biomarker.empty.subtitle"
            ) {
                HLButton("biomarker.add.title", systemImage: "plus", variant: .secondary) { showAddSheet = true }
                    .accessibilityIdentifier("biomarker.empty.add")
            }
        }
        .refreshable { await store.reloadBiomarkers() }
    }
}

/// One catalog entry: the name, and one detail line with panel, unit and
/// reference range. It opens the editor as a whole, without a chevron.
struct BiomarkerRow: View {
    let marker: BiomarkerDTO

    var body: some View {
        HLRow(title: Text(verbatim: marker.name), detail: HLRowDetail.text(Self.detailParts(marker)))
    }

    /// Panel, unit and range in reading order; a marker without a unit says
    /// so instead of "1".
    static func detailParts(_ marker: BiomarkerDTO) -> [String?] {
        [LabPanelName.display(marker.panel), LabUnit.standalone(marker.unit), rangeLabel(marker)]
    }

    static func rangeLabel(_ marker: BiomarkerDTO) -> String? {
        switch (marker.lowerBound, marker.upperBound) {
        case let (low?, high?): HLNumberFormat.range(low.formatted(), high.formatted())
        case let (low?, nil): "≥ \(low.formatted())"
        case let (nil, high?): "≤ \(high.formatted())"
        case (nil, nil): nil
        }
    }
}
