import SwiftUI

/// The marker rows of the labs list: the category sections and the row that either selects the marker beside the table or
/// pushes its page.
extension LabsScreen {
    /// One stretch of the list: the server's category head over its markers,
    /// or the markers alone while the list is flat. No column titles: each
    /// row says what its cells are (name and date, value with its verdict,
    /// the range as quiet text, the course as a line).
    @ViewBuilder
    func markerSection(
        _ section: LabMarkerSection,
        store: LabsStore,
        layout: HLListDetailLayout.Resolution,
        columns: [LabsTableLayout.Column],
        selectedID: String?
    ) -> some View {
        let rows = ForEach(section.entries) { entry in
            markerRow(entry, store: store, layout: layout, columns: columns, selectedID: selectedID)
        }
        if let title = section.title {
            let open = LabGroupsOpen.isOpen(section, layout: store.listLayout, toggled: openGroups)
            Section {
                if open { rows }
            } header: {
                groupHeader(title, section: section, isOpen: open, layout: store.listLayout)
            }
            .hlFormRowSurface()
        } else {
            Section {
                rows
            }
            .hlFormRowSurface()
        }
    }

    /// A category head. Under the person's `groupsOpen` choice (server
    /// v1.47.1) the head opens and closes its markers; without that choice
    /// every category stays open and the head is plain text, as before.
    @ViewBuilder
    func groupHeader(
        _ title: String,
        section: LabMarkerSection,
        isOpen: Bool,
        layout: LabsListLayout?
    ) -> some View {
        if layout == nil {
            HLSectionHeader(verbatim: title, rank: .group)
        } else {
            HLLinkButton(Text(verbatim: title), alignment: .leading, isExpanded: isOpen) {
                openGroups[section.id] = !isOpen
            }
            .accessibilityValue(Text(isOpen ? "labs.group.open" : "labs.group.closed"))
            .accessibilityHint(Text(isOpen ? "labs.group.hint.close" : "labs.group.hint.open"))
            .accessibilityIdentifier("labs.group.\(section.id)")
        }
    }

    /// One marker of the list. Alone on the screen a tap opens the marker's
    /// page; beside its history a tap selects it there and the row stands on
    /// the recessed surface.
    @ViewBuilder
    func markerRow(
        _ entry: LabsStore.MarkerIndexEntry,
        store: LabsStore,
        layout: HLListDetailLayout.Resolution,
        columns: [LabsTableLayout.Column],
        selectedID: String?
    ) -> some View {
        let isSelected = layout.isSideBySide && entry.id == selectedID
        let content = markerRowContent(entry, store: store, columns: columns, isSelected: isSelected)
        if layout.isSideBySide {
            HLRowButton { selection.select(entry.id) } label: { content }
                .listRowBackground(isSelected ? HLSurface.tertiary : HLSurface.secondary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("labs.byType.item")
        } else {
            content
                .hlRowLink(inList: true, value: LabMarkerRoute(entry))
                .accessibilityIdentifier("labs.byType.item")
        }
    }

    @ViewBuilder
    func markerRowContent(
        _ entry: LabsStore.MarkerIndexEntry,
        store: LabsStore,
        columns: [LabsTableLayout.Column],
        isSelected: Bool
    ) -> some View {
        if columns.isEmpty {
            BiomarkerIndexRow(name: entry.name, latest: entry.latest, count: entry.count)
        } else {
            LabMarkerTableRow(
                entry: entry,
                columns: columns,
                marker: entry.biomarkerId.flatMap { id in store.biomarkers.first { $0.id == id } }.map(store.resolvedBiomarker),
                surface: isSelected ? HLSurface.tertiary : HLSurface.secondary
            )
        }
    }
}
