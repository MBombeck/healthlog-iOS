import Foundation
@testable import HealthLog
import Testing

/// #186.2 and #187 — symptoms from Today, the server's symptom limit, the chip
/// filter, and the document's way back to Paperless-ngx or Papra.
@Suite("Symptom quick entry and document source link (#186, #187)")
struct SymptomQuickEntryTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func definition(_ id: String, _ label: String?, active: Bool = true) -> SymptomDefinition {
        SymptomDefinition(id: id, label: label, isActive: active)
    }

    // MARK: - Limit

    @Test("The limit is the server's; an old server's missing, null or odd limit is 8", arguments: [
        (#"{"definitions":[],"limit":30}"#, 30),
        (#"{"definitions":[]}"#, 8),
        (#"{"definitions":[],"limit":null}"#, 8),
        (#"{"definitions":[],"limit":"30"}"#, 8),
        (#"{"definitions":[],"limit":0}"#, 8)
    ])
    func limit(json: String, expected: Int) throws {
        #expect(try decode(SymptomDefinitionList.self, json).limit == expected)
    }

    // MARK: - Chips

    @Test("The filter stands from 13 chips on, as on the web")
    func filterThreshold() {
        #expect(!SymptomChipPicker.showsFilter(count: 12))
        #expect(SymptomChipPicker.showsFilter(count: 13))
        #expect(SymptomChipPicker.showsFilter(count: 30))
    }

    @Test("The filter matches the name in any case and keeps the picked chip")
    func filterKeepsPicked() {
        let list = [definition("1", "Kopfschmerz"), definition("2", "Übelkeit"), definition("3", "Schwindel"), definition("4", nil)]
        #expect(SymptomChipPicker.filtered(list, filter: "  ", picked: nil).count == 4)
        #expect(SymptomChipPicker.filtered(list, filter: "kopf", picked: nil).map(\.id) == ["1"])
        #expect(SymptomChipPicker.filtered(list, filter: "übel", picked: "3").map(\.id) == ["2", "3"])
        #expect(SymptomChipPicker.filtered(list, filter: "zzz", picked: nil).isEmpty)
    }

    // MARK: - Quick entry

    @Test("Only active symptoms are offered; none at all says so")
    func loadedState() {
        let state = SymptomQuickEntryState.loaded(
            definitions: [definition("1", "A"), definition("2", "B", active: false)],
            episodes: []
        )
        #expect(state == .ready(definitions: [definition("1", "A")], episodes: []))
        #expect(SymptomQuickEntryState.loaded(definitions: [definition("2", "B", active: false)], episodes: []) == .noSymptoms)
    }

    @Test("Today offers the entry with the illness module on and a server from 1.43.4", arguments: [
        (true, "1.48.4", true),
        (true, "1.43.4", true),
        (true, "1.43.3", false),
        (true, nil, false),
        (false, "1.48.4", false)
    ])
    func offered(illnessEnabled: Bool, version: String?, expected: Bool) {
        #expect(SymptomQuickEntryState.isOffered(illnessEnabled: illnessEnabled, serverVersion: version) == expected)
    }

    @Test("A refusal is the disabled card, a failure can be retried, a cancel changes nothing")
    func failures() {
        #expect(SymptomQuickEntryState
            .after(HLError.server(status: 403, code: "illness.disabled", message: ""), offReason: "off") == .disabled("off"))
        #expect(SymptomQuickEntryState.after(HLError.server(status: 500, code: nil, message: ""), offReason: nil) == .failed)
        #expect(SymptomQuickEntryState.after(CancellationError(), offReason: nil) == nil)
    }

    @Test("Without an opening episode the page offers the store's episodes as they are")
    func episodeSourceWithoutEpisode() {
        #expect(SymptomEventSheet.episodeSource(opening: nil, episodes: []).isEmpty)
    }

    // MARK: - Document source link

    private func document(_ extra: String) throws -> InboundDocument {
        try decode(
            InboundDocument.self,
            #"{"id":"d1","kind":"other","mimeType":"application/pdf","byteSize":1,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z""# +
                extra + "}"
        )
    }

    @Test("Paperless-ngx and Papra with an http(s) address open there")
    func sourceLinkOpens() throws {
        let paperless =
            try #require(try document(#","sourceSystem":"PAPERLESS","sourceUrl":"https://paperless.example.org/documents/12/details""#)
                    .sourceLink)
        #expect(paperless.archive == .paperless)
        #expect(paperless.archive.displayName == "Paperless-ngx")
        #expect(paperless.url.absoluteString == "https://paperless.example.org/documents/12/details")
        let papra = try #require(try document(#","sourceSystem":"PAPRA","sourceUrl":"http://papra.lan/d/1""#).sourceLink)
        #expect(papra.archive.displayName == "Papra")
    }

    @Test("Update path and old server: no field, null, another system or scheme opens nothing", arguments: [
        "",
        #","sourceSystem":"PAPERLESS","sourceUrl":null"#,
        #","sourceSystem":null,"sourceUrl":"https://a.example/x""#,
        #","sourceSystem":"OTHER","sourceUrl":"https://a.example/x""#,
        #","sourceSystem":"PAPERLESS","sourceUrl":"javascript:alert(1)""#,
        #","sourceSystem":"PAPERLESS","sourceUrl":"/documents/1""#,
        #","sourceSystem":"PAPERLESS","sourceUrl":42"#
    ])
    func sourceLinkAbsent(extra: String) throws {
        let doc = try document(extra)
        #expect(doc.sourceLink == nil)
        #expect(doc.id == "d1")
    }
}
