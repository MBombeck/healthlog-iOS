import Foundation
@testable import HealthLog
import Testing

@Suite("Server v1.37.3 workout contract")
struct WorkoutV1373ContractTests {
    @Test("workout batch route matches the pinned server contract")
    func workoutBatchRouteMatchesPinnedContract() {
        #expect(HealthIngestRoute.workoutsBatch == "/api/workouts/batch")
    }

    @Test("fixture request encodes the exact {t, hr} workout sample shape")
    func workoutRequestEncodingMatchesPinnedFixture() throws {
        let fixture = try Self.loadFixture()
        let expectedRequest = try #require(fixture["request"] as? [String: Any])
        let expectedWorkouts = try #require(expectedRequest["workouts"] as? [[String: Any]])
        let expectedWorkout = try #require(expectedWorkouts.first)
        let expectedSamples = try #require(expectedWorkout["samples"] as? [[String: Any]])

        let formatter = ISO8601DateFormatter()
        let startedAtString = try #require(expectedWorkout["startedAt"] as? String)
        let endedAtString = try #require(expectedWorkout["endedAt"] as? String)
        let startedAt = try #require(formatter.date(from: startedAtString))
        let endedAt = try #require(formatter.date(from: endedAtString))
        let samples = try expectedSamples.map { sample in
            let timestamp = try #require(sample["t"] as? String)
            return try WorkoutIngestDTO.Sample(
                t: #require(formatter.date(from: timestamp)),
                hr: #require(sample["hr"] as? Int)
            )
        }
        let dto = try WorkoutIngestDTO(
            sportType: #require(expectedWorkout["sportType"] as? String),
            startedAt: startedAt,
            endedAt: endedAt,
            source: #require(expectedWorkout["source"] as? String),
            externalId: #require(expectedWorkout["externalId"] as? String),
            samples: samples
        )

        let encoded = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [dto]))
        let encodedRequest = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(NSDictionary(dictionary: encodedRequest).isEqual(to: expectedRequest))
        #expect(expectedSamples.allSatisfy { Set($0.keys) == ["t", "hr"] })
    }

    @Test("inserted, enriched and skipped outcomes decode from the pinned release")
    func responseOutcomesDecode() throws {
        let fixture = try Self.loadFixture()
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        let expected: [String: WorkoutBatchResponseDTO.Status] = [
            "inserted": .inserted,
            "enriched": .enriched,
            "skipped": .skipped
        ]

        for (name, status) in expected {
            let responseJSON = try #require(responses[name])
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = try JSONDecoder().decode(WorkoutBatchResponseDTO.self, from: data)
            #expect(response.entries.count == 1)
            #expect(response.entries.first?.status == status)
            #expect(response.processed == 1)
        }
    }

    @Test("unknown additive response fields and status values remain decodable")
    func additiveResponseFieldsRemainForwardCompatible() throws {
        let fixture = try Self.loadFixture()
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        let responseJSON = try #require(responses["future-additive"])
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try JSONDecoder().decode(WorkoutBatchResponseDTO.self, from: data)

        #expect(response.entries.first?.status.rawValue == "reconciled")
        #expect(response.entries.first?.reason == nil)
    }

    private static func loadFixture(file: String = #filePath) throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Contracts
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
        let fixtureURL = repoRoot
            .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.3/workouts-batch.json")
        let data = try Data(contentsOf: fixtureURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
