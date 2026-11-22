// The labs list as the screen reads it: one entry per marker, in the
// server's categories when it sends them, flat and alphabetical otherwise.
//
// The grouping itself is the server's (`categories` and `grouped` of
// `GET /api/labs/overview`); nothing here rebuilds a category, its order or
// its status. A server without the overview route leaves only the loaded
// page, from which the list is the newest reading per analyte.
import Foundation

public extension LabsStore {
    /// One row of the marker list.
    struct MarkerIndexEntry: Identifiable, Sendable, Equatable {
        /// Overview `key` (`bm:<id>` / `analyte:<name>`), or the lower-cased
        /// analyte on the fallback path.
        public let id: String
        /// The analyte the detail page filters by.
        public let analyte: String
        /// Catalog name when the marker is linked, else the analyte.
        public let name: String
        public let biomarkerId: String?
        public let latest: LabResultDTO
        /// Every live reading of the marker, as the server counts them.
        public let count: Int
        /// Values of the newest readings, oldest first, `nil` for a
        /// qualitative one. Empty on the fallback path.
        public let trend: [Double?]

        public init(
            id: String,
            analyte: String,
            name: String,
            biomarkerId: String?,
            latest: LabResultDTO,
            count: Int,
            trend: [Double?] = []
        ) {
            self.id = id
            self.analyte = analyte
            self.name = name
            self.biomarkerId = biomarkerId
            self.latest = latest
            self.count = count
            self.trend = trend
        }
    }

    /// The marker list. From the server's overview when there is one
    /// (every marker over the whole history, count and newest reading as
    /// delivered); otherwise, against a server before v1.42.4, the newest
    /// reading per analyte of the loaded ``labs`` page. Named markers only,
    /// alphabetical; the blank-analyte rows stay in ``blankAnalyteRows``.
    var markerIndex: [MarkerIndexEntry] {
        markerList.index
    }

    /// The marker index and its sections, built once per set of inputs
    /// (D5 #11). Both used to be computed properties the labs screen read up
    /// to four times per body: a localized sort, a catalog lookup per marker
    /// and the section build, paid again on every expand, collapse and iPad
    /// split selection.
    ///
    /// Reading the four inputs here is what keeps observation intact: a view
    /// that reads the list is invalidated by a change of any of them, exactly
    /// as before. The comparison is cheap: an unchanged array is the same
    /// buffer, and `==` on the same buffer returns without a walk.
    private var markerList: LabsMarkerMemo.List {
        let inputs = LabsMarkerMemo.Inputs(
            labs: labs,
            biomarkers: biomarkers,
            overview: markerOverview,
            layout: listLayout
        )
        if let list = markerMemo.list, list.inputs == inputs { return list }
        let index = buildMarkerIndex()
        let list = LabsMarkerMemo.List(
            inputs: inputs,
            index: index,
            sections: LabMarkerSections.build(
                entries: index,
                categories: markerOverview?.categories ?? [],
                grouped: listLayout.map { $0.groups(overviewGrouped: markerOverview?.grouped ?? false) }
                    ?? (markerOverview?.grouped ?? false)
            )
        )
        markerMemo.list = list
        markerMemo.builds += 1
        return list
    }

    /// How often the marker list was built; the D5 #11 test reads it.
    var markerListBuildCount: Int {
        markerMemo.builds
    }

    private func buildMarkerIndex() -> [MarkerIndexEntry] {
        let names = Dictionary(biomarkers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let catalogName: (String?) -> String? = { id in
            guard let id else { return nil }
            return names[id]
        }
        let entries: [MarkerIndexEntry] = if let overview = markerOverview {
            overview.markers.compactMap { marker in
                let analyte = marker.latest.analyte
                guard !analyte.isEmpty else { return nil }
                let biomarkerId = marker.biomarkerId ?? marker.latest.biomarkerId
                let name = catalogName(biomarkerId).flatMap { $0.isEmpty ? nil : $0 } ?? analyte
                return MarkerIndexEntry(
                    id: marker.key,
                    analyte: analyte,
                    name: name,
                    biomarkerId: biomarkerId,
                    latest: marker.latest,
                    count: marker.count,
                    trend: marker.trend
                )
            }
        } else {
            pageEntries(catalogName: catalogName)
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The marker list under the server's category heads, or one headless
    /// section while the server does not group (see ``LabMarkerSections``).
    var markerSections: [LabMarkerSection] {
        markerList.sections
    }

    /// Legacy rows with a blank analyte: they have no marker page and list
    /// their readings inline. Server order (newest first).
    var blankAnalyteRows: [LabResultDTO] {
        labs.filter(\.analyte.isEmpty)
    }

    /// All labs in a single flat list sorted by collection date, newest-first —
    /// the "chronological" sort axis. `takenAt` is an ISO-8601 wire string that
    /// sorts lexicographically (zero-padded fields, fixed `Z` offset), so the
    /// string compare matches chronological order without parsing.
    var sortedByDate: [LabResultDTO] {
        let source = labs
        if let memo = markerMemo.byDate, memo.source == source { return memo.rows }
        let rows = source.sorted { $0.takenAt > $1.takenAt }
        markerMemo.byDate = (source, rows)
        return rows
    }

    /// The newest reading per analyte of the loaded page. Bucketing is
    /// case-insensitive so "GGT" and "ggt" are one marker, the identity the
    /// marker page aggregates with; the first-seen spelling is kept.
    private func pageEntries(catalogName: (String?) -> String?) -> [MarkerIndexEntry] {
        var order: [String] = []
        var buckets: [String: [LabResultDTO]] = [:]
        for row in labs where !row.analyte.isEmpty {
            let key = row.analyte.lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }
        return order.compactMap { key in
            guard let rows = buckets[key], let latest = rows.first else { return nil }
            let biomarkerId = rows.first(where: { $0.biomarkerId != nil })?.biomarkerId
            let name = catalogName(biomarkerId).flatMap { $0.isEmpty ? nil : $0 } ?? latest.analyte
            return MarkerIndexEntry(
                id: key,
                analyte: latest.analyte,
                name: name,
                biomarkerId: biomarkerId,
                latest: latest,
                count: rows.count
            )
        }
    }
}

/// One stretch of the marker list: a category head and its markers, or the
/// whole list without a head.
public struct LabMarkerSection: Identifiable, Sendable, Equatable {
    public let id: String
    /// The server's label, shown as sent. `nil` for a headless stretch.
    public let title: String?
    public let entries: [LabsStore.MarkerIndexEntry]
    /// The server's combined status of the category; `nil` for a headless
    /// stretch. Decides `groupsOpen: flagged`.
    public let status: LabRangeStatus?

    public init(id: String, title: String?, entries: [LabsStore.MarkerIndexEntry], status: LabRangeStatus? = nil) {
        self.id = id
        self.title = title
        self.entries = entries
        self.status = status
    }
}

/// Lays the marker entries under the server's categories. Pure.
public enum LabMarkerSections {
    /// The marker the pane beside the list shows and the list marks: the
    /// selection while it is still listed, else the first marker as the list
    /// shows them (the first of the first category), so the marked row and the
    /// pane always agree.
    public static func resolvedEntry(
        selection: HLPaneSelection<String>,
        in sections: [LabMarkerSection]
    ) -> LabsStore.MarkerIndexEntry? {
        let entries = sections.flatMap(\.entries)
        guard let id = selection.resolvedOrFirst(in: entries.map(\.id)) else { return nil }
        return entries.first { $0.id == id }
    }

    /// Headless id of the one flat section.
    public static let flatID = "labs.flat"
    /// Headless id of markers no category names (not expected from the
    /// server; they are listed rather than dropped).
    public static let unlistedID = "labs.unlisted"

    /// `entries` are the alphabetical marker list. While the server does not
    /// group (`grouped == false`, no categories, or no overview at all) the
    /// result is one headless, alphabetical section. Otherwise one section per
    /// category in the server's order, members alphabetical, empty categories
    /// left out.
    public static func build(
        entries: [LabsStore.MarkerIndexEntry],
        categories: [LabOverviewCategory],
        grouped: Bool
    ) -> [LabMarkerSection] {
        guard !entries.isEmpty else { return [] }
        guard grouped, !categories.isEmpty else {
            return [LabMarkerSection(id: flatID, title: nil, entries: entries)]
        }
        let byKey = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var sections: [LabMarkerSection] = []
        for category in categories {
            let members = category.markerKeys
                .compactMap { byKey[$0] }
                .filter { placed.insert($0.id).inserted }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !members.isEmpty {
                sections.append(LabMarkerSection(
                    id: category.key, title: category.label, entries: members, status: category.status
                ))
            }
        }
        let unlisted = entries.filter { !placed.contains($0.id) }
        if !unlisted.isEmpty {
            sections.append(LabMarkerSection(id: unlistedID, title: nil, entries: unlisted))
        }
        return sections
    }
}

/// Which categories of the labs list are open. Pure.
public enum LabGroupsOpen {
    /// A category opened or closed by hand stays so; otherwise the person's
    /// `groupsOpen` choice decides, from the server's status for the whole
    /// category. Without a layout (older server) every category is open.
    public static func isOpen(
        _ section: LabMarkerSection,
        layout: LabsListLayout?,
        toggled: [String: Bool]
    ) -> Bool {
        if let own = toggled[section.id] { return own }
        guard let layout, section.title != nil else { return true }
        return layout.startsOpen(status: section.status ?? .unknown)
    }
}

/// The labs list derived from one set of inputs (D5 #11).
struct LabsMarkerMemo {
    struct Inputs: Equatable {
        let labs: [LabResultDTO]
        let biomarkers: [BiomarkerDTO]
        let overview: LabOverviewResponse?
        let layout: LabsListLayout?
    }

    struct List {
        let inputs: Inputs
        let index: [LabsStore.MarkerIndexEntry]
        let sections: [LabMarkerSection]
    }

    var list: List?
    var byDate: (source: [LabResultDTO], rows: [LabResultDTO])?
    var builds = 0
}
