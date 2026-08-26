import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.1 — locks the warm-in-flight re-poll on `DerivedInsightsStore`.
///
/// On a cold first-login session the server is still computing the daily derived
/// scores out of band and returns the batch envelopes with `revalidating: true`
/// (no value). The store must NOT settle the empty grid (which would freeze the
/// overview until the next Berlin-day rollover); instead it exposes a `warming`
/// flag + schedules a bounded re-poll so a freshly-warmed grid appears in the
/// SAME session (mirrors `NarrativeStore`'s pattern).
///
/// Covers:
/// - a `revalidating: true` envelope sets `warming` + re-polls
/// - the re-poll picks up the settled grid + clears `warming`
/// - a settled-from-the-start grid never warms
@MainActor
@Suite("DerivedInsightsStore — warm-in-flight re-poll", .serialized)
struct DerivedInsightsStoreWarmingTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// A batch body for READINESS with the given `revalidating` + optional score.
    /// `nonisolated static` so the off-actor `MockURLProtocol` handler can call it.
    private nonisolated static func batchBody(revalidating: Bool, score: Int?) -> Data {
        let valueJSON = score.map { "{\"score\":\($0),\"band\":\"green\"}" } ?? "null"
        let revJSON = revalidating ? "true" : "false"
        return Data(#"""
        {"data":{"metrics":{
          "READINESS":{"metric":"READINESS","status":"\#(score == nil ? "insufficient" : "ok")",
            "value":\#(valueJSON),
            "coverage":{"requiredInputs":5,"presentInputs":4,"historyDays":21,"missing":[]},
            "confidence":\#(score == nil ? "null" : "{\"score\":78,\"band\":\"high\"}"),
            "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                          "computedAt":"2026-06-02T22:00:00+02:00"},
            "reason":null,"revalidating":\#(revJSON)}
        }},"error":null}
        """#.utf8)
    }

    @Test("revalidating:true → warming flag set, then re-poll settles the grid")
    func warmingThenSettles() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        let store = DerivedInsightsStore(repo: repo)

        // First read: server still warming (revalidating:true, no value).
        // Second read (the scheduled re-poll): settled with a score.
        let callCount = Counter()
        MockURLProtocol.handler = { req in
            let n = callCount.next()
            let body = n == 0
                ? Self.batchBody(revalidating: true, score: nil)
                : Self.batchBody(revalidating: false, score: 78)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await store.load()
        // First load saw revalidating:true → warming, nothing presentable yet.
        #expect(store.warming == true)
        #expect(store.presentable.isEmpty)

        // The re-poll is delayed (~4s); poll the store until it settles.
        try await waitUntil { store.warming == false }
        #expect(store.warming == false)
        #expect(store.presentable.first?.value?.score == 78)
    }

    @Test("settled-from-start grid never warms")
    func noWarmWhenSettled() async {
        let repo = DerivedMetricsRepository(api: makeAPI())
        let store = DerivedInsightsStore(repo: repo)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.batchBody(revalidating: false, score: 80)
            )
        }
        await store.load()
        #expect(store.warming == false)
        #expect(store.presentable.first?.value?.score == 80)
    }

    // MARK: - Helpers

    /// Polls `condition` every 50ms up to ~10s (the re-poll delay is ~4s).
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Condition never became true within the timeout")
    }

    /// Thread-safe call counter for the mock handler (it runs off-actor). Uses
    /// the iOS-18 `Mutex` so no `@unchecked Sendable` escape hatch is needed.
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func next() -> Int {
            value.withLock { current in
                defer { current += 1 }
                return current
            }
        }
    }
}
