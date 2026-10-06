import Foundation
@testable import HealthLog
import Testing

/// **#115 · 1.7 / C1 — an unknown server value never becomes a stated fact.**
///
/// Four server-owned enums used to decode an unknown value to a case that
/// claims something about the person's record: an allergy severity to `MILD`,
/// an allergy status to `ACTIVE`, an illness course to `ACUTE`, and a staged
/// document fact to `OBSERVATION` (counted as a lab value). Each now lands on a
/// neutral `.unknown`, is labelled as unknown, is never offered in a picker and
/// is never sent back on an unchanged edit. The wire literals are the server's
/// own vocabularies at v1.39.0 (`src/lib/validations/allergy.ts`,
/// `src/lib/validations/illness.ts`, `ExtractedFact.factType` in
/// `docs/api/openapi.yaml`) with one value the server does not have (yet).
@Suite("C1 — unknown enum values stay neutral, never a stated fact")
struct FactClaimingFallbackTests {
    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    private func allergyJSON(severity: String?, status: String?) -> String {
        var fields = [
            #""id":"al-1""#, #""substance":"Penicillin""#, #""category":"MEDICATION""#, #""type":"ALLERGY""#,
            #""onsetAt":null"#, #""reaction":null"#, #""note":null"#,
            #""createdAt":"2026-09-01T08:00:00.000Z""#, #""updatedAt":"2026-09-01T08:00:00.000Z""#
        ]
        fields.append(severity.map { #""severity":"\#($0)""# } ?? #""severity":null"#)
        if let status { fields.append(#""status":"\#(status)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func episodeJSON(lifecycle: String?, parent: String?) -> String {
        var fields = [
            #""id":"ep-1""#, #""label":"Colitis""#, #""type":"CHRONIC""#,
            #""onsetAt":"2026-01-10T08:00:00.000Z""#, #""resolvedAt":null"#, #""note":null"#,
            #""createdAt":"2026-01-10T08:00:00.000Z""#, #""updatedAt":"2026-01-10T08:00:00.000Z""#
        ]
        fields.append(parent.map { #""parentConditionId":"\#($0)""# } ?? #""parentConditionId":null"#)
        if let lifecycle { fields.append(#""lifecycle":"\#(lifecycle)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func factJSON(id: String, type: String?, status: String = "PENDING") -> String {
        let typeField = type.map { #","factType":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","status":"\#(status)","confidence":0.9,"needsReview":false,"data":{"label":"x"}\#(typeField)}"#
    }

    // MARK: - Allergy severity

    @Test("an unknown allergy severity is unknown, not mild")
    func unknownSeverity() throws {
        let dto = try decode(AllergyDTO.self, allergyJSON(severity: "ANAPHYLACTIC", status: "ACTIVE"))
        #expect(dto.severity == .unknown)
        #expect(dto.severity?.localizedLabel != AllergySeverity.mild.localizedLabel)
        // "No severity recorded" stays distinct from "a severity we cannot name".
        let none = try decode(AllergyDTO.self, allergyJSON(severity: nil, status: "ACTIVE"))
        #expect(none.severity == nil)
        let known = try decode(AllergyDTO.self, allergyJSON(severity: "SEVERE", status: "ACTIVE"))
        #expect(known.severity == .severe)
    }

    // MARK: - Allergy status

    @Test("an unknown or missing allergy status is unknown, not active")
    func unknownStatus() throws {
        let unknown = try decode(AllergyDTO.self, allergyJSON(severity: nil, status: "ENTERED_IN_ERROR"))
        #expect(unknown.status == .unknown)
        #expect(unknown.status.localizedLabel != AllergyStatus.active.localizedLabel)
        let missing = try decode(AllergyDTO.self, allergyJSON(severity: nil, status: nil))
        #expect(missing.status == .unknown)
        let resolved = try decode(AllergyDTO.self, allergyJSON(severity: nil, status: "RESOLVED"))
        #expect(resolved.status == .resolved)
    }

    @Test("pickers offer only the real values; the cache round-trips unknown")
    func pickersAndCache() throws {
        #expect(AllergySeverity.allCases == [.mild, .moderate, .severe])
        #expect(AllergyStatus.allCases == [.active, .inactive, .resolved])
        #expect(IllnessLifecycle.allCases == [.acute, .chronicOngoing, .recurring, .flare])
        // SWR caches the DTO encoded; the neutral state must survive a relaunch.
        let dto = try decode(AllergyDTO.self, allergyJSON(severity: "ANAPHYLACTIC", status: "ENTERED_IN_ERROR"))
        let again = try JSONDecoder.hlDefault.decode(AllergyDTO.self, from: JSONEncoder.hlDefault.encode(dto))
        #expect(again.severity == .unknown)
        #expect(again.status == .unknown)
    }

    @Test("an untouched unknown allergy value is not sent on edit")
    func untouchedUnknownIsNotSent() throws {
        let severity: RecordPatchField<AllergySeverity> = triState(new: .unknown, old: .unknown)
        #expect(severity == .unchanged)
        let patch = AllergyPatch(severity: severity)
        let body = try #require(String(data: JSONEncoder.hlDefault.encode(patch), encoding: .utf8))
        #expect(!body.contains("UNKNOWN"))
        #expect(!body.contains("severity"))
    }

    // MARK: - Illness course

    @Test("an unknown or missing illness course is unknown, not acute")
    func unknownLifecycle() throws {
        let unknown = try decode(IllnessEpisodeDTO.self, episodeJSON(lifecycle: "REMISSION", parent: "cond-1"))
        #expect(unknown.lifecycle == .unknown)
        #expect(unknown.lifecycle.localizedLabel != IllnessLifecycle.acute.localizedLabel)
        let missing = try decode(IllnessEpisodeDTO.self, episodeJSON(lifecycle: nil, parent: nil))
        #expect(missing.lifecycle == .unknown)
        let flare = try decode(IllnessEpisodeDTO.self, episodeJSON(lifecycle: "FLARE", parent: "cond-1"))
        #expect(flare.lifecycle == .flare)
    }

    @Test("editing an episode with an unknown course keeps its parent link")
    func unknownLifecycleKeepsParent() throws {
        let episode = try decode(IllnessEpisodeDTO.self, episodeJSON(lifecycle: "REMISSION", parent: "cond-1"))
        // The edit sheet always sends `parentConditionId`; a `null` unlinks.
        let parent = episode.lifecycle.parentForPatch(chosen: nil, stored: episode.parentConditionId)
        #expect(parent == "cond-1")
        let patch = IllnessEpisodePatch(parentConditionId: parent, note: "edited")
        let body = try #require(String(data: JSONEncoder.hlDefault.encode(patch), encoding: .utf8))
        #expect(body.contains(#""parentConditionId":"cond-1""#))
        #expect(!body.contains("lifecycle"))
        // Known courses are unchanged: a flare sends the chosen parent, an acute
        // episode sends null.
        #expect(IllnessLifecycle.flare.parentForPatch(chosen: "cond-2", stored: "cond-1") == "cond-2")
        #expect(IllnessLifecycle.acute.parentForPatch(chosen: "cond-2", stored: "cond-1") == nil)
    }

    // MARK: - Document fact type

    @Test("an unknown document fact type is unknown and not counted as a lab value")
    func unknownFactType() throws {
        let facts = try decode(
            [ExtractedFact].self,
            "[" + [
                factJSON(id: "f1", type: "IMMUNIZATION"),
                factJSON(id: "f2", type: nil),
                factJSON(id: "f3", type: "OBSERVATION"),
                factJSON(id: "f4", type: "OBSERVATION", status: "REJECTED")
            ].joined(separator: ",") + "]"
        )
        #expect(facts.map(\.factType) == [.unknown, .unknown, .observation, .observation])
        #expect(InboundDocumentDetail.labFactCount(in: facts) == 1)
    }
}

/// **#115 Phase 2 — vaccinations and document links (v1.39): not applicable.**
///
/// The app lists no vaccinations (no call to `GET /api/vaccinations`), so it
/// neither shows `renewals` nor offers a vaccination to link. What it must not
/// do is break or rewrite a document that carries such links: the v1.39 detail
/// adds a required `vaccinationLinks` (`null` without the health-background
/// grant), and `PATCH` treats `vaccinationIds` as a replace-set that only a
/// PRESENT key touches (`src/app/api/documents/inbound/[id]/route.ts` at
/// v1.39.0, `parsed.data.vaccinationIds !== undefined`). These pins keep both.
@Suite("C1 — document vaccination links (v1.39) decode and are never rewritten")
struct DocumentVaccinationLinksToleranceTests {
    private func detailJSON(vaccinationLinks: String) -> Data {
        Data(#"""
        {"id":"d1","kind":"VACCINATION","title":"Impfpass","filename":"impfpass.pdf","mimeType":"application/pdf",
         "byteSize":1200,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-09-01",
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"encounterLinks":[],
         "servingClass":"inline","hasContentIndex":false,"contentIndexSource":null,"lastIndexAttemptAt":null,
         "lastIndexOutcome":null,"hasThumbnail":false,"createdAt":"2026-09-01T08:00:00.000Z",
         "updatedAt":"2026-09-01T08:00:00.000Z","facts":[],"vaccinationLinks":\#(vaccinationLinks),
         "summary":null,"summaryGeneratedAt":null,"summaryState":"NONE"}
        """#.utf8)
    }

    @Test("a v1.39 detail with vaccination links, or null, decodes intact")
    func detailDecodes() throws {
        let links = #"[{"vaccinationId":"vac-1","occurredAt":"2019-05-02","catalogSlug":"tetanus","vaccineName":null}]"#
        for payload in [links, "null", "[]"] {
            let detail = try JSONDecoder.hlDefault.decode(InboundDocumentDetail.self, from: detailJSON(vaccinationLinks: payload))
            #expect(detail.document.id == "d1")
            #expect(detail.document.kind == .vaccination)
        }
    }

    @Test("a document edit never sends vaccinationIds")
    func patchNeverSendsVaccinationIds() throws {
        let patches: [DocumentPatch] = [.title("Impfpass"), .kind(.vaccination), .episodeIds(["ep-1"]), .documentDate(nil)]
        for patch in patches {
            let body = try #require(String(data: JSONEncoder.hlDefault.encode(patch), encoding: .utf8))
            #expect(!body.contains("vaccinationIds"))
        }
    }
}
