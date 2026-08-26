import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the v1.25 structured-records (allergy + family-history) DATA layer
/// against the server contract: tolerant DTO decode (incl. null decrypted PHI +
/// unknown-enum fallback), the **tri-state PATCH encoding** (omit vs send-null vs
/// set), envelope unwrapping, the CRUD verbs, and the soft-delete
/// `{deleted:true}` body. Real `APIClient` + stub `URLProtocol` (no mock server)
/// per PROJECT_GUIDE.md.
@Suite("Structured-records data layer (v1.25 W-RECORDS)", .serialized)
struct RecordsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeAllergiesRepo() throws -> AllergiesRepository {
        try AllergiesRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
    }

    private func makeFamilyRepo() throws -> FamilyHistoryRepository {
        try FamilyHistoryRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
    }

    // MARK: - Allergy DTO decode

    @Test("Allergy decodes incl. null severity/onset + decrypted-null reaction/note")
    func decodeAllergyNulls() throws {
        let json = Data(#"""
        {"id":"a1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
         "severity":null,"status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
         "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(AllergyDTO.self, from: json)
        #expect(dto.id == "a1")
        #expect(dto.substance == "Penicillin")
        #expect(dto.category == .medication)
        #expect(dto.severity == nil) // key-rotation gap / unknown — fail-soft nil
        #expect(dto.onsetAt == nil)
        #expect(dto.reaction == nil)
        #expect(dto.note == nil)
    }

    @Test("Allergy decodes a fully-populated row incl. decrypted PHI")
    func decodeAllergyPopulated() throws {
        let json = Data(#"""
        {"id":"a2","substance":"Peanut","category":"FOOD","type":"ALLERGY",
         "severity":"SEVERE","status":"ACTIVE","onsetAt":"2010-06-01T00:00:00.000Z",
         "reaction":"Anaphylaxis","note":"Carries an epi-pen",
         "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(AllergyDTO.self, from: json)
        #expect(dto.severity == .severe)
        #expect(dto.reaction == "Anaphylaxis")
        #expect(dto.note == "Carries an epi-pen")
    }

    @Test("Unknown allergy enums fall back tolerantly")
    func decodeAllergyUnknownEnums() throws {
        let json = Data(#"""
        {"id":"a3","substance":"X","category":"NEW_CAT","type":"NEW_TYPE",
         "severity":"NEW_SEV","status":"NEW_STATUS","onsetAt":null,"reaction":null,"note":null,
         "createdAt":"","updatedAt":""}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(AllergyDTO.self, from: json)
        #expect(dto.category == .other)
        #expect(dto.type == .allergy)
        #expect(dto.severity == .mild) // present-but-unknown clamps to a valid member
        #expect(dto.status == .active)
    }

    // MARK: - Family-history DTO decode

    @Test("Family-history decodes incl. null ageAtOnset/note + unknown relationship")
    func decodeFamilyNulls() throws {
        let json = Data(#"""
        {"id":"f1","relationship":"NEW_REL","condition":"Diabetes","ageAtOnset":null,"note":null,
         "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(FamilyHistoryEntryDTO.self, from: json)
        #expect(dto.relationship == .other) // tolerant fallback
        #expect(dto.condition == "Diabetes")
        #expect(dto.ageAtOnset == nil)
        #expect(dto.note == nil)
    }

    @Test("Family-history decodes a populated row")
    func decodeFamilyPopulated() throws {
        let json = Data(#"""
        {"id":"f2","relationship":"MOTHER","condition":"Breast cancer","ageAtOnset":52,
         "note":"BRCA1","createdAt":"","updatedAt":""}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(FamilyHistoryEntryDTO.self, from: json)
        #expect(dto.relationship == .mother)
        #expect(dto.ageAtOnset == 52)
        #expect(dto.note == "BRCA1")
    }

    // MARK: - Tri-state PATCH encoding (omit vs null vs set)

    @Test("AllergyPatch: unchanged omits the key entirely")
    func patchUnchangedOmits() throws {
        let patch = AllergyPatch() // every field .unchanged
        let json = try encodeToObject(patch)
        #expect(json.isEmpty) // no keys at all
    }

    @Test("AllergyPatch: clear emits an explicit JSON null; set emits the value")
    func patchClearVsSet() throws {
        let patch = AllergyPatch(
            substance: .set("Updated"),
            severity: .clear,
            onsetAt: .clear,
            reaction: .set("Hives"),
            note: .clear
        )
        let raw = try JSONEncoder.hlDefault.encode(patch)
        let obj = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        // set → value present.
        #expect(obj["substance"] as? String == "Updated")
        #expect(obj["reaction"] as? String == "Hives")
        // clear → key present AND value is NSNull (an explicit null), not absent.
        #expect(obj.keys.contains("severity"))
        #expect(obj["severity"] is NSNull)
        #expect(obj.keys.contains("onsetAt"))
        #expect(obj["onsetAt"] is NSNull)
        #expect(obj.keys.contains("note"))
        #expect(obj["note"] is NSNull)
        // unchanged fields are absent.
        #expect(!obj.keys.contains("category"))
        #expect(!obj.keys.contains("type"))
        #expect(!obj.keys.contains("status"))
    }

    @Test("AllergyPatch round-trips through Codable (outbox replay fidelity)")
    func patchRoundTrips() throws {
        let patch = AllergyPatch(
            category: .set(.food),
            severity: .clear,
            note: .set("epi-pen")
        )
        let raw = try JSONEncoder.hlDefault.encode(patch)
        let decoded = try JSONDecoder.hlDefault.decode(AllergyPatch.self, from: raw)
        #expect(decoded == patch)
        // Specifically: clear survives as clear (not unchanged).
        if case .clear = decoded.severity {} else { Issue.record("severity should decode as .clear") }
        if case .unchanged = decoded.status {} else { Issue.record("status should decode as .unchanged") }
        if case let .set(cat) = decoded.category { #expect(cat == .food) } else { Issue.record("category should be .set(.food)") }
    }

    @Test("FamilyHistoryPatch: clear ageAtOnset emits null; unchanged omits")
    func familyPatchTriState() throws {
        let patch = FamilyHistoryPatch(ageAtOnset: .clear)
        let obj = try encodeToObject(patch)
        #expect(obj.keys.contains("ageAtOnset"))
        #expect(obj["ageAtOnset"] is NSNull)
        #expect(!obj.keys.contains("note"))
        #expect(!obj.keys.contains("relationship"))
        // And a set int survives the round-trip.
        let setPatch = FamilyHistoryPatch(ageAtOnset: .set(40))
        let decoded = try JSONDecoder.hlDefault.decode(
            FamilyHistoryPatch.self, from: JSONEncoder.hlDefault.encode(setPatch)
        )
        #expect(decoded == setPatch)
        #expect(decoded.ageAtOnset.value == 40)
    }

    // MARK: - List + CRUD envelope

    @Test("GET /api/allergies unwraps the data array + builds includeInactive query")
    func listAllergiesEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/allergies")
            #expect(req.url?.query?.contains("includeInactive=false") == true)
            #expect(req.url?.query?.contains("limit=100") == true)
            let body = Data(#"""
            {"data":[{"id":"a1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
             "severity":"MODERATE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
             "createdAt":"","updatedAt":""}],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeAllergiesRepo()
        let list = try await repo.list(includeInactive: false)
        #expect(list.count == 1)
        #expect(list.first?.substance == "Penicillin")
    }

    @Test("POST /api/allergies posts the create body + returns the row (201)")
    func createAllergy() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/allergies")
            #expect(req.httpMethod == "POST")
            let body = Data(#"""
            {"data":{"id":"a9","substance":"Latex","category":"ENVIRONMENT","type":"ALLERGY",
             "severity":null,"status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
             "createdAt":"","updatedAt":""},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeAllergiesRepo()
        let created = try await repo.create(AllergyCreate(substance: "Latex", category: .environment))
        #expect(created.id == "a9")
    }

    @Test("PATCH /api/allergies/{id} uses PATCH + returns the updated row")
    func updateAllergy() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/allergies/a1")
            #expect(req.httpMethod == "PATCH")
            let body = Data(#"""
            {"data":{"id":"a1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
             "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
             "createdAt":"","updatedAt":""},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeAllergiesRepo()
        let updated = try await repo.update(id: "a1", AllergyPatch(severity: .set(.severe)))
        #expect(updated.severity == .severe)
    }

    @Test("DELETE /api/allergies/{id} decodes {deleted:true} (soft, 200 not 204)")
    func deleteAllergy() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/allergies/a1")
            #expect(req.httpMethod == "DELETE")
            let body = Data(#"{"data":{"deleted":true},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeAllergiesRepo()
        let deleted = try await repo.delete(id: "a1")
        #expect(deleted == true)
    }

    @Test("DELETE tolerates an empty/{}-style body (deleted defaults false)")
    func deleteAllergyTolerant() async throws {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{}}"#.utf8))
        }
        let repo = try makeAllergiesRepo()
        let deleted = try await repo.delete(id: "a1")
        #expect(deleted == false)
    }

    @Test("Family-history CRUD: list + PATCH route + soft delete")
    func familyCrud() async throws {
        // list
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/family-history")
            let body = Data(#"""
            {"data":[{"id":"f1","relationship":"FATHER","condition":"Hypertension","ageAtOnset":45,
             "note":null,"createdAt":"","updatedAt":""}],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeFamilyRepo()
        let list = try await repo.list()
        #expect(list.first?.relationship == .father)

        // PATCH (not PUT)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PATCH")
            #expect(req.url?.path == "/api/family-history/f1")
            let body = Data(#"""
            {"data":{"id":"f1","relationship":"FATHER","condition":"Hypertension","ageAtOnset":null,
             "note":null,"createdAt":"","updatedAt":""},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let updated = try await repo.update(id: "f1", FamilyHistoryPatch(ageAtOnset: .clear))
        #expect(updated.ageAtOnset == nil)

        // soft delete
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }
        #expect(try await repo.delete(id: "f1") == true)
    }

    @Test("404 on a tombstoned id is recognised by isNotFound")
    func notFound() async throws {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Allergy not found"}"#.utf8)
            )
        }
        let repo = try makeAllergiesRepo()
        do {
            _ = try await repo.get(id: "missing")
            Issue.record("expected a 404")
        } catch {
            #expect(AllergiesRepository.isNotFound(error))
        }
    }

    // MARK: - Helpers

    private func encodeToObject(_ value: some Encodable) throws -> [String: Any] {
        let raw = try JSONEncoder.hlDefault.encode(value)
        return try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }
}

// swiftlint:enable force_unwrapping
