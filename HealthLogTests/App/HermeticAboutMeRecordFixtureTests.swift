import Foundation
@testable import HealthLog
import Testing

/// Allergies and family history are lists on the server (`{ data: [...] }`).
/// The hermetic world answered both with `{}`, which no list decodes, so the
/// two screens showed their load error instead of content or the empty state.
/// Decoded here the way the repositories decode them.
@Suite("Hermetic allergy and family-history fixtures")
struct HermeticAboutMeRecordFixtureTests {
    @Test("The sweep answers allergies with two rows in the server's shape")
    func sweepAllergies() throws {
        let answer = try #require(SweepFixtures.response(forPath: "/api/allergies", method: "GET", query: []))
        #expect(answer.status == 200)
        let rows = try #require(JSONDecoder.hlDefault.decode(APIEnvelope<[AllergyDTO]>.self, from: answer.body).data)
        #expect(rows.count == 2)
        #expect(rows.map(\.category) == [.medication, .food])
        #expect(rows.allSatisfy { $0.status == .active })
    }

    @Test("The sweep answers family history with two rows in the server's shape")
    func sweepFamilyHistory() throws {
        let answer = try #require(SweepFixtures.response(forPath: "/api/family-history", method: "GET", query: []))
        let rows = try #require(JSONDecoder.hlDefault.decode(APIEnvelope<[FamilyHistoryEntryDTO]>.self, from: answer.body).data)
        #expect(rows.map(\.relationship) == [.father, .grandmotherMaternal])
        #expect(rows.allSatisfy { $0.ageAtOnset != nil })
    }

    @Test("Without the sweep both routes answer an empty list, not an object", arguments: ["/api/allergies", "/api/family-history"])
    func defaultIsEmptyList(path: String) {
        let answer = HermeticFixtures.response(forPath: path, method: "GET")
        #expect(answer.status == 200)
        #expect(String(bytes: answer.body, encoding: .utf8) == "[]")
    }

    @Test("A single record keeps the object default")
    func singleRecordStaysObject() {
        let answer = HermeticFixtures.response(forPath: "/api/allergies/abc", method: "GET")
        #expect(String(bytes: answer.body, encoding: .utf8) == "{}")
    }
}
