import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// A State-of-Mind sample that could not be delivered must replay under the
    /// identity of the HealthKit sample, not of the attempt, so a relaunch that
    /// re-reads the same sample cannot turn into a second mood row.
    @Suite("State of Mind import — restart-stable retry identity", .mockURLSession)
    struct MoodImportRetryIdentityTests {
        @Test("a queued sample carries the key derived from its HealthKit UUID, again after a relaunch")
        func queuedSampleReplaysUnderTheSampleDerivedKey() async throws {
            MockURLProtocol.install { req in
                let url = req.url ?? URL(fileURLWithPath: "/api/mood")
                let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
                guard let response else { throw URLError(.badServerResponse) }
                return (response, nil)
            }
            let sample = HKStateOfMind(
                date: Date(timeIntervalSince1970: 1_788_200_000),
                kind: .momentaryEmotion,
                valence: 0.5,
                labels: [],
                associations: []
            )
            let expected = try #require(
                HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: sample.uuid.uuidString)
            )

            // Two harnesses over two queues: the second stands in for the
            // process that relaunched and re-read the same sample.
            var keys: [String] = []
            for _ in 0 ..< 2 {
                let harness = try ModuleGateHarness()
                let page = await harness.importer.consume([sample], requiring: harness.lease)
                #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit, "a queued sample is durable progress")
                let queued = await harness.outbox.snapshot
                #expect(queued.count == 1)
                keys += queued.map(\.idempotencyKey)
            }

            #expect(keys == [expected.idempotencyKey, expected.idempotencyKey])
        }
    }

#endif
