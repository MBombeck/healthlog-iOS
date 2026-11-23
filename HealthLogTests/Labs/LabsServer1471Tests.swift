import Foundation
@testable import HealthLog
import Testing

/// #164 (server v1.47.1): `customPanels` for the marker form,
/// `adoptedPanel` on a merge, and the person's `groupBy` / `groupsOpen` for
/// the labs list. Each one absent on an older server, which keeps the old
/// behaviour.
@Suite("Labs: panel suggestions, adopted panel, list grouping")
@MainActor
struct LabsServer1471Tests {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.hlDefault.decode(type, from: Data(json.utf8))
    }

    private static func row(_ id: String, analyte: String) -> LabResultDTO {
        LabResultDTO(
            id: id, biomarkerId: nil, panel: nil, analyte: analyte, value: 1, unit: "mg/l",
            referenceLow: nil, referenceHigh: nil, takenAt: "2026-03-04T12:00:00.000Z", source: "MANUAL",
            hasNote: false, rangeStatus: .inRange, createdAt: "2026-03-04T12:00:00.000Z",
            updatedAt: "2026-03-04T12:00:00.000Z"
        )
    }

    private static func entry(_ key: String) -> LabsStore.MarkerIndexEntry {
        LabsStore.MarkerIndexEntry(id: key, analyte: key, name: key, biomarkerId: nil, latest: row(key, analyte: key), count: 1)
    }

    private static let categories = [
        LabOverviewCategory(key: "inflammation", label: "Entzündung", markerKeys: ["crp"], status: .above),
        LabOverviewCategory(key: "other", label: "Sonstige", markerKeys: ["ggt"], status: .inRange)
    ]

    // MARK: - customPanels

    @Test("customPanels decode, blanks dropped; an older server sends none")
    func customPanelsDecode() throws {
        let new = try Self.decode(ListBiomarkersResponse.self, #"{"biomarkers":[],"customPanels":["Meine Praxis"," ","Sport"]}"#)
        #expect(new.customPanels == ["Meine Praxis", "Sport"])
        let old = try Self.decode(ListBiomarkersResponse.self, #"{"biomarkers":[]}"#)
        #expect(old.customPanels.isEmpty)
        let again = try JSONDecoder.hlDefault.decode(ListBiomarkersResponse.self, from: JSONEncoder.hlDefault.encode(new))
        #expect(again.customPanels == new.customPanels, "the SWR cache keeps them")
    }

    @Test("Suggestions narrow as the person types, leading matches first")
    func suggestionsNarrow() {
        let panels = ["Sportmedizin", "Meine Praxis", "Schilddrüse", "Praxis Sport"]
        #expect(LabPanelSuggestions.matches(typed: "", panels: panels) == panels)
        #expect(LabPanelSuggestions.matches(typed: "sport", panels: panels) == ["Sportmedizin", "Praxis Sport"])
        #expect(LabPanelSuggestions.matches(typed: "xyz", panels: panels).isEmpty)
        #expect(LabPanelSuggestions.matches(typed: "", panels: ["A", "a", "B"]) == ["A", "B"], "one spelling each")
        #expect(LabPanelSuggestions.matches(typed: "", panels: (1 ... 20).map { "P\($0)" }).count == LabPanelSuggestions.limit)
        #expect(LabPanelSuggestions.same(" meine praxis", "Meine Praxis"))
    }

    // MARK: - adoptedPanel

    @Test("adoptedPanel decodes on a dry run and a merge; blank or absent reads nil")
    func adoptedPanelDecodes() throws {
        let dry = try Self.decode(
            BiomarkerMergeResult.self,
            #"{"dryRun":true,"sources":[],"movedReadings":3,"convertedReadings":0,"adoptedPanel":"Meine Praxis"}"#
        )
        #expect(dry.adoptedPanel == "Meine Praxis")
        #expect(BiomarkerMergeCopy.summaryLines(dry).count == 2)
        let blank = try Self.decode(
            BiomarkerMergeResult.self,
            #"{"dryRun":false,"sources":[],"movedReadings":3,"convertedReadings":0,"adoptedPanel":" "}"#
        )
        #expect(blank.adoptedPanel == nil)
        let old = try Self.decode(BiomarkerMergeResult.self, #"{"dryRun":false,"sources":[],"movedReadings":3,"convertedReadings":0}"#)
        #expect(old.adoptedPanel == nil)
        #expect(BiomarkerMergeCopy.adoptedPanelLine(old) == nil)
        #expect(BiomarkerMergeCopy.doneLines(old).count == 1)
    }

    @Test("After the merge the sheet names the adopted panel, worded apart from the preview")
    func adoptedPanelAfterMerge() throws {
        let done = try Self.decode(
            BiomarkerMergeResult.self,
            #"{"dryRun":false,"sources":[],"movedReadings":3,"convertedReadings":1,"adoptedPanel":"coagulation","mergeId":"m1"}"#
        )
        let lines = BiomarkerMergeCopy.doneLines(done)
        #expect(lines.count == 2)
        let preview = try Self.decode(
            BiomarkerMergeResult.self,
            #"{"dryRun":true,"sources":[],"movedReadings":3,"convertedReadings":1,"adoptedPanel":"coagulation"}"#
        )
        #expect(BiomarkerMergeCopy.adoptedPanelLine(preview) != BiomarkerMergeCopy.adoptedPanelLine(done))
    }

    // MARK: - module-list-layout

    @Test("The labs layout decodes groupBy and groupsOpen; unknown words fall back")
    func layoutDecodes() throws {
        let json = #"{"version":1,"lists":{"labs":{"view":"list","groupBy":"category","groupsOpen":"flagged","saved":true},"illness":{}}}"#
        let layout = try #require(try Self.decode(ModuleListLayoutResponse.self, json).labs)
        #expect(layout.groupBy == .category)
        #expect(layout.groupsOpen == .flagged)
        let older = try #require(try Self.decode(ModuleListLayoutResponse.self, #"{"lists":{"labs":{"view":"list"}}}"#).labs)
        #expect(older.groupBy == nil)
        #expect(older.groupsOpen == .expanded)
        let odd = try #require(try Self
            .decode(ModuleListLayoutResponse.self, #"{"lists":{"labs":{"groupBy":"panel","groupsOpen":"half"}}}"#).labs)
        #expect(odd.groupBy == .unknown)
        #expect(odd.groupsOpen == .unknown)
        #expect(try Self.decode(ModuleListLayoutResponse.self, #"{"lists":{}}"#).labs == nil)
    }

    @Test("groupBy none keeps the list flat even when the server could group it")
    func groupByNoneIsFlat() {
        let none = LabsListLayout(groupBy: .flat)
        #expect(!none.groups(overviewGrouped: true))
        #expect(LabsListLayout(groupBy: .category).groups(overviewGrouped: true))
        #expect(!LabsListLayout(groupBy: .category).groups(overviewGrouped: false), "the overview's grouped has the last word")
        #expect(LabsListLayout(groupBy: nil).groups(overviewGrouped: true), "an older server groups as before")
        let entries = [Self.entry("crp"), Self.entry("ggt")]
        let flat = LabMarkerSections.build(entries: entries, categories: Self.categories, grouped: none.groups(overviewGrouped: true))
        #expect(flat.map(\.id) == [LabMarkerSections.flatID])
        let grouped = LabMarkerSections.build(entries: entries, categories: Self.categories, grouped: true)
        #expect(grouped.map(\.status) == [.above, .inRange])
    }

    @Test("groupsOpen decides which categories start open; a hand toggle wins")
    func groupsOpenStart() {
        let entries = [Self.entry("crp"), Self.entry("ggt")]
        let sections = LabMarkerSections.build(entries: entries, categories: Self.categories, grouped: true)
        let open = { (layout: LabsListLayout?, toggled: [String: Bool]) in
            sections.map { LabGroupsOpen.isOpen($0, layout: layout, toggled: toggled) }
        }
        #expect(open(nil, [:]) == [true, true], "older server: everything open")
        #expect(open(LabsListLayout(groupBy: .category, groupsOpen: .expanded), [:]) == [true, true])
        #expect(open(LabsListLayout(groupBy: .category, groupsOpen: .collapsed), [:]) == [false, false])
        #expect(open(LabsListLayout(groupBy: .category, groupsOpen: .flagged), [:]) == [true, false])
        #expect(open(LabsListLayout(groupBy: .category, groupsOpen: .flagged), ["other": true]) == [true, true])
        #expect(open(LabsListLayout(groupBy: .category, groupsOpen: .expanded), ["inflammation": false]) == [false, true])
    }
}
