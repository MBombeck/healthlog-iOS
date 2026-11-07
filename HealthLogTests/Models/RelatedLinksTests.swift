import Foundation
@testable import HealthLog
import Testing

/// #141 (RELATED, 1.5.0) — `related` on lab results, documents, illness
/// episodes and medications. Server v1.43+, absent on older servers.
@Suite("Related records (#141)")
struct RelatedLinksTests {
    private static let document = #"{"kind":"document","id":"doc_1","label":"Befund März","date":"2026-03-03","href":"/documents/doc_1","via":"direct"}"#
    private static let visit = #"{"kind":"encounter","id":"enc_1","label":"Hausarzt","date":"2026-03-02","href":"/visits/enc_1","via":"direct"}"#
    private static let unknown = #"{"kind":"careTeamNote","id":"x_1","label":"Neu","date":null,"href":"/x/x_1","via":"direct"}"#
    private static let noID = #"{"kind":"medication","label":"Ohne Id","date":null,"href":"/m","via":"direct"}"#

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The acceptance from #141

    @Test("A lab value read from a scanned report lists that report, and the row opens it")
    func labResultWithDocument() throws {
        let json = #"""
        {"id":"lab_1","analyte":"HbA1c","value":5.4,"unit":"%","takenAt":"2026-03-03T08:00:00Z",
         "source":"DOCUMENT","rangeStatus":"in-range","createdAt":"","updatedAt":"","note":null,
         "related":[\#(Self.document)]}
        """#
        let detail = try Self.decode(LabResultDetailDTO.self, json)
        let links = try #require(detail.related?.items)
        #expect(links == [RelatedLink(kind: .document, recordID: "doc_1", label: "Befund März", date: "2026-03-03")])
        #expect(links[0].kind.opensInApp)
        #expect(links[0].id == "document:doc_1")
    }

    // MARK: - Lossy decoding

    @Test("An unknown kind and an element without id are skipped, the rest stay in order")
    func unknownKindIsSkipped() throws {
        let links = try Self.decode(RelatedLinks.self, "[\(Self.visit),\(Self.unknown),\(Self.noID),\(Self.document)]")
        #expect(links.items.map(\.recordID) == ["enc_1", "doc_1"])
    }

    @Test("A related value that is not a list reads as empty and never fails the record")
    func notAListIsEmpty() throws {
        let json = #"{"id":"ep_1","label":"Grippe","type":"INFECTION","lifecycle":"ACUTE","onsetAt":"2026-03-01T00:00:00Z","createdAt":"","updatedAt":"","related":{"oops":1}}"#
        let episode = try Self.decode(IllnessEpisodeDTO.self, json)
        #expect(episode.label == "Grippe")
        #expect(episode.related?.items.isEmpty ?? true)
    }

    @Test("Server without the field: nil on all four records")
    func absentOnOlderServer() throws {
        let lab = try Self.decode(
            LabResultDetailDTO.self,
            #"{"id":"lab_1","analyte":"K","value":4,"unit":"mmol/L","takenAt":"","source":"MANUAL","rangeStatus":"in-range","createdAt":"","updatedAt":""}"#
        )
        #expect(lab.related == nil)
        let episode = try Self.decode(
            IllnessEpisodeDTO.self,
            #"{"id":"ep_1","label":"Grippe","type":"INFECTION","lifecycle":"ACUTE","onsetAt":"","createdAt":"","updatedAt":""}"#
        )
        #expect(episode.related == nil)
        let document = try Self.decode(InboundDocumentDetail.self, Self.documentJSON(related: nil))
        #expect(document.related == nil)
        let medication = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(related: nil)).toDomain()
        #expect(medication.related == nil)
    }

    @Test("Server with the field: the document detail and the medication carry it")
    func presentOnNewerServer() throws {
        let document = try Self.decode(InboundDocumentDetail.self, Self.documentJSON(related: "[\(Self.visit)]"))
        #expect(document.related?.items.map(\.kind) == [.encounter])
        #expect(document.document.id == "doc_9")

        let wire = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(related: "[\(Self.document),\(Self.unknown)]"))
        let medication = wire.toDomain()
        #expect(medication.related?.items.map(\.recordID) == ["doc_1"])
    }

    @Test("Empty related list shows nothing")
    func emptyList() throws {
        let links = try Self.decode(RelatedLinks.self, "[]")
        #expect(links.items.isEmpty)
    }

    // MARK: - Update path (rule 11)

    @Test("A medication cached by 1.4.1 (no related key) still decodes; a cached one keeps its links")
    func medicationCacheRoundTrip() throws {
        let plain = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(related: nil)).toDomain()
        let oldBlob = try JSONEncoder.hlDefault.encode(plain)
        #expect(String(bytes: oldBlob, encoding: .utf8)?.contains("related") == false)
        let restored = try JSONDecoder.hlDefault.decode(Medication.self, from: oldBlob)
        #expect(restored.related == nil)
        #expect(restored.id == plain.id)

        var linked = plain
        linked.related = RelatedLinks([RelatedLink(kind: .labResult, recordID: "lab_1", label: "HbA1c", date: nil)])
        let back = try JSONDecoder.hlDefault.decode(Medication.self, from: JSONEncoder.hlDefault.encode(linked))
        #expect(back.related == linked.related)
    }

    // MARK: - Rows

    @Test("Lab, document, episode and medication open a page; visit and vaccination do not")
    func kindsThatOpen() {
        let opening = [RelatedLink.Kind.labResult, .document, .conditionEpisode, .medication]
        let allOpen = opening.allSatisfy(\.opensInApp)
        #expect(allOpen)
        #expect(!RelatedLink.Kind.encounter.opensInApp)
        #expect(!RelatedLink.Kind.vaccination.opensInApp)
    }

    @Test("A day key stays on its day; no date shows no date")
    func dates() throws {
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 3)))
        #expect(RelatedRecordFormat.date("2026-03-03") == HLDateFormat.date(day, style: .abbreviated))
        #expect(RelatedRecordFormat.date(nil) == nil)
        #expect(RelatedRecordFormat.date("") == nil)
        #expect(RelatedRecordFormat.date("soon") == "soon")
    }

    @Test("VoiceOver reads kind, label and date")
    func spokenLabel() {
        let link = RelatedLink(kind: .vaccination, recordID: "v1", label: "Tetanus", date: nil)
        #expect(RelatedRecordFormat.spokenLabel(link) == "\(String(localized: "related.kind.vaccination")), Tetanus")
    }

    // MARK: - Failure paths

    @Test("Offline, a refusal and a gone record show no section; other failures offer Retry")
    func sectionStateAfterError() {
        #expect(RelatedRecordsModel.stateAfter(HLError.offline) == .loaded([]))
        #expect(RelatedRecordsModel.stateAfter(HLError.moduleDisabled("medications")) == .loaded([]))
        #expect(RelatedRecordsModel.stateAfter(HLError.server(status: 403, code: "module.disabled", message: "")) == .loaded([]))
        #expect(RelatedRecordsModel.stateAfter(HLError.server(status: 404, code: nil, message: "")) == .loaded([]))
        #expect(RelatedRecordsModel.stateAfter(HLError.server(status: 500, code: nil, message: "")) == .failed)
        #expect(RelatedRecordsModel.stateAfter(HLError.decoding("x")) == .failed)
        #expect(RelatedRecordsModel.stateAfter(CancellationError()) == nil)
    }

    @Test("Opening a related record: 404 is gone, 403 is the module, anything else can be retried")
    func destinationAfterError() {
        func phase(_ error: Error) -> String {
            switch RelatedRecordPhase.after(error, kind: .document, offReason: { $0 == .inboundDocuments ? "off" : nil }) {
            case .notFound: "notFound"
            case let .disabled(reason): "disabled:\(reason ?? "-")"
            case .failed: "failed"
            default: "other"
            }
        }
        #expect(phase(HLError.server(status: 404, code: nil, message: "")) == "notFound")
        #expect(phase(HLError.moduleDisabled("inboundDocuments")) == "disabled:off")
        #expect(phase(HLError.server(status: 403, code: "module.disabled", message: "")) == "disabled:off")
        #expect(phase(HLError.offline) == "failed")
    }

    @Test("A lab result opened before the list loaded keeps every field of its single read")
    func labRowFromDetail() {
        let detail = LabResultDetailDTO(
            id: "lab_1", biomarkerId: "bm_1", panel: "Blut", analyte: "INR", value: 1.1, unit: "1",
            referenceLow: 0.8, referenceHigh: 1.2, takenAt: "2026-03-03T08:00:00Z", source: "DOCUMENT",
            rangeStatus: .inRange, createdAt: "c", updatedAt: "u", note: "nüchtern"
        )
        let row = LabResultDTO(detail: detail)
        #expect(row.id == "lab_1")
        #expect(row.analyte == "INR")
        #expect(row.unit == "1")
        #expect(row.hasNote)
        #expect(row.rangeStatus == .inRange)
        #expect(row.biomarkerId == "bm_1")
    }

    // MARK: - Document page (POLISH-A A2)

    @Test("The document page shows a linked episode once: in its card, not again under Related")
    func documentEpisodeShownOnce() throws {
        let episode = #"{"kind":"conditionEpisode","id":"ep_1","label":"Influenza","date":null,"href":"/i/ep_1","via":"direct"}"#
        let other = #"{"kind":"conditionEpisode","id":"ep_2","label":"Migräne","date":null,"href":"/i/ep_2","via":"direct"}"#
        let json = Self.documentJSON(related: "[\(Self.document),\(episode),\(other),\(Self.visit)]")
            .replacingOccurrences(of: #""conditionLinks":[]"#, with: #""conditionLinks":[{"episodeId":"ep_1","name":"Influenza"}]"#)
        let detail = try Self.decode(InboundDocumentDetail.self, json)
        let linked = Set(detail.document.conditionLinks.map(\.episodeId))
        #expect(linked == ["ep_1"])
        let shown = RelatedLinks.excludingEpisodes(detail.related?.items ?? [], linkedOn: linked)
        #expect(shown.map(\.id) == ["document:doc_1", "conditionEpisode:ep_2", "encounter:enc_1"])
        // Nothing linked in the card: the list stays as the server sent it.
        #expect(RelatedLinks.excludingEpisodes(detail.related?.items ?? [], linkedOn: []).count == 4)
    }

    // MARK: - Fixtures

    private static func documentJSON(related: String?) -> String {
        let tail = related.map { #","related":\#($0)"# } ?? ""
        return #"""
        {"id":"doc_9","kind":"LAB_RESULT","title":"Befund","filename":"lab.pdf","mimeType":"application/pdf",
         "byteSize":10,"status":"EXTRACTED","providerType":"anthropic","reportDate":"2026-03-03",
         "documentDate":"2026-03-03","errorReason":null,"factCount":0,"pendingCount":0,
         "conditionLinks":[],"servingClass":"inline","createdAt":"2026-03-03T08:00:00.000Z",
         "updatedAt":"2026-03-03T08:00:00.000Z","facts":[]\#(tail)}
        """#
    }

    private static func medicationJSON(related: String?) -> String {
        let tail = related.map { #","related":\#($0)"# } ?? ""
        return #"{"id":"med_1","name":"Metformin","dose":"500 mg","active":true,"schedules":[]\#(tail)}"#
    }
}
