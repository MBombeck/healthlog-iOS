import Foundation
@testable import HealthLog
import Testing

/// The labs overview with the server's categories, decoded from the payload
/// the server's contract describes (`GET /api/labs/overview` at v1.47.3,
/// `LabOverviewResponse` in `docs/api/openapi.yaml`). The list renders the
/// categories as sent; nothing here rebuilds one.
@Suite("Labs overview decoding and categories")
@MainActor
struct LabsOverviewDecodingTests {
    private static func fixtureData(file: String = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ServerContracts/v1.47.3/labs-overview.json")
        return try Data(contentsOf: url)
    }

    /// The envelope's `data`, as `APIClient` hands it to the decoder.
    private static func overview() throws -> LabOverviewResponse {
        let root = try #require(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: #require(root["data"]))
        return try JSONDecoder.hlDefault.decode(LabOverviewResponse.self, from: data)
    }

    private func store(_ overview: LabOverviewResponse?) throws -> LabsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .ephemeral)
        let store = try LabsStore(repository: LabsRepository(api: api, outbox: OutboxQueue(inMemory: true)))
        store.seedForTesting(labs: overview?.markers.map(\.latest) ?? [], overview: overview)
        return store
    }

    // MARK: - Decoding

    @Test("the markers, the categories in the server's order and the grouped flag decode")
    func decodesServerPayload() throws {
        let overview = try Self.overview()
        #expect(overview.markers.count == 4)
        #expect(overview.grouped)
        // Order as sent, not catalog order: the server applied `categoryOrder`.
        #expect(overview.categories.map(\.key) == ["inflammation", "coagulation", "custom:3f9a1c0b7d42", "other"])
        #expect(overview.categories.map(\.label) == ["Entzündung", "Gerinnung", "Meine Praxis", "Sonstige"])
        let coagulation = try #require(overview.categories.first { $0.key == "coagulation" })
        #expect(coagulation.markerKeys == ["bm:bm_inr"])
        #expect(coagulation.counts == LabOverviewCategoryCounts(inRange: 0, below: 0, above: 1, unknown: 0))
        #expect(coagulation.status == .above)
        #expect(overview.categories.first { $0.key == "other" }?.status == .inRange)
    }

    @Test("every marker of the fixture is named by exactly one category")
    func categoriesCoverMarkers() throws {
        let overview = try Self.overview()
        let named = overview.categories.flatMap(\.markerKeys)
        #expect(Set(named) == Set(overview.markers.map(\.key)))
        #expect(named.count == Set(named).count)
    }

    @Test("a trend keeps its gaps and a qualitative marker decodes without a number")
    func trendAndQualitative() throws {
        let overview = try Self.overview()
        let inr = try #require(overview.markers.first { $0.key == "bm:bm_inr" })
        #expect(inr.count == 12)
        #expect(inr.trend == [1.0, 1.1, nil, 1.3])
        let own = try #require(overview.markers.first { $0.key == "analyte:praxis-wert" })
        #expect(own.latest.isQualitative)
        #expect(own.latest.value == nil)
    }

    @Test("a server before the categories sends none: flat list, grouped false")
    func olderServerWithoutCategories() throws {
        let json = Data(#"{"markers":[]}"#.utf8)
        let overview = try JSONDecoder.hlDefault.decode(LabOverviewResponse.self, from: json)
        #expect(overview.categories.isEmpty)
        #expect(overview.grouped == false)
    }

    @Test("a category this build cannot read is skipped, the rest stay")
    func unreadableCategoryIsSkipped() throws {
        let json = Data(#"""
        {"markers":[],"grouped":true,"categories":[
          {"key":"coagulation","label":"Gerinnung","markerKeys":["a"],"counts":{"inRange":1,"below":0,"above":0,"unknown":0},"status":"in-range"},
          {"label":"no key"},
          {"key":"other","label":"Sonstige","markerKeys":[],"status":"from-the-future"}
        ]}
        """#.utf8)
        let overview = try JSONDecoder.hlDefault.decode(LabOverviewResponse.self, from: json)
        #expect(overview.categories.map(\.key) == ["coagulation", "other"])
        #expect(overview.categories.last?.status == .unknown, "an unknown status reads as unknown, never a failure")
    }

    // MARK: - Sections

    @Test("grouped: one section per category in the server's order, members alphabetical, heads as sent")
    func sectionsFollowServer() throws {
        let store = try store(Self.overview())
        let sections = store.markerSections
        #expect(sections.map(\.title) == ["Entzündung", "Gerinnung", "Meine Praxis", "Sonstige"])
        #expect(sections.map(\.id) == ["inflammation", "coagulation", "custom:3f9a1c0b7d42", "other"])
        #expect(sections.map { $0.entries.map(\.name) } == [["hs-CRP"], ["INR"], ["Praxis-Wert"], ["Zink"]])
        #expect(sections[1].entries.first?.trend == [1.0, 1.1, nil, 1.3])
    }

    @Test("not grouped: one headless alphabetical section, whatever categories came along")
    func flatWhileNotGrouped() throws {
        let sent = try Self.overview()
        let flat = LabOverviewResponse(markers: sent.markers, categories: sent.categories, grouped: false)
        let sections = try store(flat).markerSections
        #expect(sections.count == 1)
        #expect(sections[0].title == nil)
        #expect(sections[0].entries.map(\.name) == ["hs-CRP", "INR", "Praxis-Wert", "Zink"])
    }

    @Test("a server without categories gives the same flat list")
    func flatWithoutCategories() throws {
        let sent = try Self.overview()
        let sections = try store(LabOverviewResponse(markers: sent.markers)).markerSections
        #expect(sections.map(\.title) == [nil])
        #expect(sections[0].entries.count == 4)
    }

    @Test("without an overview the list is flat, from the loaded page")
    func flatWithoutOverview() throws {
        let sent = try Self.overview()
        let page = sent.markers.map(\.latest)
        let store = try store(nil)
        store.seedForTesting(labs: page, overview: nil)
        #expect(store.markerSections.map(\.title) == [nil])
        #expect(store.markerSections[0].entries.map(\.name) == ["hs-CRP", "INR", "Praxis-Wert", "Zink"])
    }

    @Test("D5 #11: the marker list is built once per change of its inputs, not per read")
    func markerListIsBuiltOncePerRevision() throws {
        let sent = try Self.overview()
        let store = try store(nil)
        store.seedForTesting(labs: sent.markers.map(\.latest), overview: sent)
        let before = store.markerListBuildCount
        for _ in 0 ..< 4 {
            _ = store.markerSections
            _ = store.markerIndex
        }
        #expect(store.markerListBuildCount == before + 1, "every read rebuilt the sorted, sectioned list")

        store.seedForTesting(labs: [], overview: LabOverviewResponse(markers: []))
        #expect(store.markerSections.flatMap(\.entries).isEmpty, "a new input revision builds anew")
        #expect(store.markerListBuildCount == before + 2)
    }

    @Test("a marker no category names is listed after them, an empty category is left out")
    func unlistedMarkersAndEmptyCategories() throws {
        let sent = try Self.overview()
        let categories = [
            LabOverviewCategory(key: "coagulation", label: "Gerinnung", markerKeys: ["bm:bm_inr"]),
            LabOverviewCategory(key: "empty", label: "Leer", markerKeys: ["bm:gone"])
        ]
        let sections = try store(LabOverviewResponse(markers: sent.markers, categories: categories, grouped: true))
            .markerSections
        #expect(sections.map(\.id) == ["coagulation", LabMarkerSections.unlistedID])
        #expect(sections.last?.title == nil)
        #expect(sections.last?.entries.map(\.name) == ["hs-CRP", "Praxis-Wert", "Zink"])
    }

    @Test("a marker named by two categories shows once, in the first")
    func markerShowsOnce() throws {
        let sent = try Self.overview()
        let categories = [
            LabOverviewCategory(key: "a", label: "A", markerKeys: ["bm:bm_inr"]),
            LabOverviewCategory(key: "b", label: "B", markerKeys: ["bm:bm_inr", "bm:bm_crp"])
        ]
        let sections = try store(LabOverviewResponse(markers: sent.markers, categories: categories, grouped: true))
            .markerSections
        #expect(sections.map(\.id) == ["a", "b", LabMarkerSections.unlistedID])
        #expect(sections[1].entries.map(\.name) == ["hs-CRP"])
    }

    @Test("the marked row and the pane resolve to the same marker: the first of the first category")
    func markedRowIsThePaneMarker() throws {
        let sent = try Self.overview()
        // The first category holds INR; alphabetically hs-CRP comes first.
        let categories = [
            LabOverviewCategory(key: "coagulation", label: "Gerinnung", markerKeys: ["bm:bm_inr"]),
            LabOverviewCategory(key: "inflammation", label: "Entzündung", markerKeys: ["bm:bm_crp"]),
            LabOverviewCategory(key: "other", label: "Sonstige", markerKeys: ["analyte:praxis-wert", "analyte:zink"])
        ]
        let store = try store(LabOverviewResponse(markers: sent.markers, categories: categories, grouped: true))
        #expect(store.markerIndex.first?.name == "hs-CRP", "the alphabetical first is not in the first category")
        let sections = store.markerSections
        let none = HLPaneSelection<String>()
        #expect(LabMarkerSections.resolvedEntry(selection: none, in: sections)?.name == "INR")
        var chosen = HLPaneSelection<String>()
        chosen.select("bm:bm_crp")
        #expect(LabMarkerSections.resolvedEntry(selection: chosen, in: sections)?.name == "hs-CRP")
        chosen.select("bm:gone")
        #expect(LabMarkerSections.resolvedEntry(selection: chosen, in: sections)?.name == "INR")
        #expect(LabMarkerSections.resolvedEntry(selection: none, in: []) == nil)
    }

    @Test("the history route shows the store's current rows: edits show, deleted readings are gone")
    func historyRouteIsLive() throws {
        let sent = try Self.overview()
        let inr = try #require(sent.markers.first { $0.key == "bm:bm_inr" }).latest
        let store = try store(sent)
        let route = LabHistoryRoute(title: "INR", rows: [inr])
        #expect(route.liveRows(in: store).map(\.id) == [inr.id])
        store.seedForTesting(labs: [], overview: sent)
        #expect(route.liveRows(in: store).map(\.id) == [inr.id], "beyond the loaded page the snapshot stays")
    }
}
