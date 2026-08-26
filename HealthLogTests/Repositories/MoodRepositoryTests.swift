import Foundation
@testable import HealthLog
import Testing

@Suite("Server v1.37.3 additive mood compatibility")
struct MoodRepositoryTests {
    @Test("existing mood decoder ignores additive level-A and context fields")
    func additiveMoodFieldsRemainForwardCompatible() throws {
        let fixture = try Self.loadFixture()
        let responseJSON = try #require(fixture["response"] as? [String: Any])
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)

        let response = try JSONDecoder.hlDefault.decode(MoodListResponse.self, from: responseData)
        let entry = try #require(response.entries.first)

        #expect(entry.id == "fixture-mood-additive-1")
        #expect(entry.mood == .good)
        #expect(entry.tags == ["fixture-calm"])
        #expect(entry.tagKeys == ["fixture-reflection"])
        #expect(entry.note == "Synthetic fixture note")
        #expect(entry.ratedFactors == [RatedFactorOutput(key: "fixture-energy", rating: 4)])

        let rawEntries = try #require(responseJSON["entries"] as? [[String: Any]])
        let rawEntry = try #require(rawEntries.first)
        #expect(Set(["a1", "a2", "a3", "a4", "a5", "context"]).isSubset(of: Set(rawEntry.keys)))

        let reencoded = try JSONEncoder.hlDefault.encode(entry)
        let reencodedJSON = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        for additiveKey in ["a1", "a2", "a3", "a4", "a5", "context"] {
            #expect(reencodedJSON[additiveKey] == nil)
        }
    }

    private static func loadFixture(file: String = #filePath) throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Repositories
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
        let fixtureURL = repoRoot
            .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.3/mood-entry-additive.json")
        let data = try Data(contentsOf: fixtureURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
