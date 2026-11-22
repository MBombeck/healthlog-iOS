import Foundation

/// What the labs screen pushes. Values, not destinations: the screen's root
/// resolves them (`navigationDestination(for:)`), so a pushed page does not
/// hang on the row or the pane that opened it and survives a change of width.
/// Each carries the snapshot it was opened with, so the page is never blank
/// while the list reloads.
struct LabMarkerRoute: Hashable {
    let entryID: String
    let analyte: String
    let biomarkerId: String?
    let latest: LabResultDTO

    init(_ entry: LabsStore.MarkerIndexEntry) {
        entryID = entry.id
        analyte = entry.analyte
        biomarkerId = entry.biomarkerId
        latest = entry.latest
    }
}

/// The readings of one marker (in the chosen period, or all of them).
struct LabHistoryRoute: Hashable {
    let title: String
    let rows: [LabResultDTO]

    /// The rows as the store has them now: an edit shows at once, a deleted
    /// reading is gone; readings beyond the loaded page keep their snapshot.
    @MainActor
    func liveRows(in store: LabsStore) -> [LabResultDTO] {
        let pending = Set(store.pendingRestoreIDs)
        let current = Dictionary(store.labs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { pending.contains($0.id) ? nil : (current[$0.id] ?? $0) }
    }
}
