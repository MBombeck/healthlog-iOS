import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for `GET / PUT /api/auth/me/source-priority`
/// (server v1.4.25 W5e + W8c).
///
/// Covers:
/// - GET decodes the fully-defaulted shape
/// - GET with both flat + nested shape: `ladder(forMetric:)` prefers nested
/// - PUT round-trip echoes the persisted shape
/// - cache fresh / cache stale ladder
@Suite("SourcePriorityRepository — wire contract", .serialized)
struct SourcePriorityRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    @Test("fetch — decodes the fully-defaulted W5e shape")
    func fetchDefaultedShape() async throws {
        let repo = SourcePriorityRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"steps":["APPLE_HEALTH","WITHINGS","MANUAL"],"activeEnergy":["APPLE_HEALTH","WITHINGS","MANUAL"],"weight":["WITHINGS","APPLE_HEALTH","MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let payload = try await repo.fetch()
        #expect(payload.steps == ["APPLE_HEALTH", "WITHINGS", "MANUAL"])
        #expect(payload.weight == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
        #expect(payload.ladder(forMetric: "weight") == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
    }

    @Test("ladder(forMetric:) — nested metricPriority wins over flat alias")
    func nestedWinsOverFlat() async throws {
        let repo = SourcePriorityRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"weight":["MANUAL","APPLE_HEALTH"],"metricPriority":{"weight":["WITHINGS","APPLE_HEALTH","MANUAL"]}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let payload = try await repo.fetch()
        #expect(payload.ladder(forMetric: "weight") == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
    }

    @Test("update — PUT round-trips the echoed shape into the cache")
    func updateRoundTrip() async throws {
        let repo = SourcePriorityRepository(api: makeAPI())
        nonisolated(unsafe) var lastMethod: String?
        MockURLProtocol.handler = { req in
            if req.targets("/api/auth/me/source-priority") { lastMethod = req.httpMethod }
            let body = Data(#"""
            {"data":{"weight":["APPLE_HEALTH","WITHINGS","MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let echoed = try await repo.update(SourcePriorityDTO(weight: ["APPLE_HEALTH", "WITHINGS", "MANUAL"]))
        #expect(lastMethod == "PUT")
        #expect(echoed.weight == ["APPLE_HEALTH", "WITHINGS", "MANUAL"])
    }

    @Test("update — PUT carries an Idempotency-Key header (M1)")
    func updateAttachesIdempotencyKey() async throws {
        // V0.5.2 R2 / M1: PROJECT_GUIDE.md contract requires Idempotency-Keys on
        // every POST/PUT. The default `IdempotencyKey()` flows through the
        // explicit overload — assert the header lands on the wire.
        let repo = SourcePriorityRepository(api: makeAPI())
        nonisolated(unsafe) var lastIdempotencyKey: String?
        MockURLProtocol.handler = { req in
            if req.targets("/api/auth/me/source-priority") {
                lastIdempotencyKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            }
            let body = Data(#"{"data":{"weight":["MANUAL"]},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.update(SourcePriorityDTO(weight: ["MANUAL"]))
        #expect(lastIdempotencyKey != nil, "PUT must carry an Idempotency-Key header")
        #expect(lastIdempotencyKey?.isEmpty == false)
    }

    @Test("update(_:idempotencyKey:) — replay overload passes the explicit key through")
    func updateReplayOverloadPropagatesKey() async throws {
        let repo = SourcePriorityRepository(api: makeAPI())
        nonisolated(unsafe) var lastIdempotencyKey: String?
        MockURLProtocol.handler = { req in
            if req.targets("/api/auth/me/source-priority") {
                lastIdempotencyKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            }
            let body = Data(#"{"data":{"weight":["MANUAL"]},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let fixed = IdempotencyKey(raw: "fixed-replay-key-0001")
        _ = try await repo.update(SourcePriorityDTO(weight: ["MANUAL"]), idempotencyKey: fixed)
        #expect(lastIdempotencyKey == "fixed-replay-key-0001")
    }

    @Test("fetch — second call within TTL hits cache")
    func fetchCacheHit() async throws {
        let repo = SourcePriorityRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/auth/me/source-priority") { calls += 1 }
            let body = Data(#"{"data":{"steps":["APPLE_HEALTH"]},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.fetch()
        _ = try await repo.fetch()
        #expect(calls == 1)
    }

    @Test("invalidateCache — drops the snapshot so next fetch hits the wire")
    func invalidateCacheWipesSnapshot() async throws {
        // V0.5.2 R2 / H1: logout must reach the per-repo actor cache so
        // the next user never sees the previous user's ladder.
        let repo = SourcePriorityRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/auth/me/source-priority") { calls += 1 }
            let body = Data(#"{"data":{"steps":["APPLE_HEALTH"]},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.fetch()
        _ = try await repo.fetch() // warm
        #expect(calls == 1)
        await repo.invalidateCache()
        _ = try await repo.fetch()
        #expect(calls == 2, "post-invalidate fetch must round-trip again")
    }
}

// swiftlint:enable force_unwrapping
