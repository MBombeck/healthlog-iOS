import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// End-to-end coverage for `MeasurementsRepository.state(kind:rangeDays:)`.
/// This is the function every tile + chart-detail empty-predicate should
/// route through after the PB5 refactor (PA4 §"Recommended unified
/// data-source pattern"). The fixtures pin the three failure modes the
/// user has hit on real-device — see PROJECT_GUIDE.md anti-pattern "Mock-Server
/// in Tests fuer Outbox-Replay-Pfade" → we keep the real APIClient and
/// stub the network at URLProtocol level.
@Suite("MeasurementsRepository.state(kind:rangeDays:)", .serialized)
struct MeasurementsRepositoryStateTests {
    private func makeRepo() throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// ISO-encoded date formatter matching `JSONDecoder.hlDefault` — the
    /// server emits ISO-8601 with fractional seconds. We hand-build wire
    /// JSON here instead of round-tripping the encoder so the test stays
    /// explicit about the bytes on the wire.
    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Lightweight per-row fixture used by `listPayload`. Struct (not
    /// 5-tuple) to satisfy the repo's `large_tuple` SwiftLint rule.
    private struct WireRow {
        let id: String
        let type: String
        let value: Double
        let at: Date
        let source: String?
    }

    /// Builds the `{ data: { measurements: [...] } }` envelope the list
    /// endpoint emits. Lightweight per-row JSON — only the fields the
    /// domain decoder cares about (we exercise the empty/ready paths, not
    /// the full BP pair-merge here).
    private func listPayload(measurements: [WireRow]) -> Data {
        let items = measurements.map { m -> String in
            let sourceFragment = m.source.map { ",\"source\":\"\($0)\"" } ?? ""
            return """
            {"id":"\(m.id)","type":"\(m.type)","value":\(m.value),"measuredAt":"\(iso(m.at))"\(sourceFragment)}
            """
        }
        let body = "{\"data\":{\"measurements\":[\(items.joined(separator: ","))]}}"
        return Data(body.utf8)
    }

    // MARK: - Scenarios

    @Test("no data at all → .empty(.noData)")
    func noData() async throws {
        let repo = try makeRepo()
        let payload = listPayload(measurements: [])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let state = try await repo.state(kind: .weight, rangeDays: 30)
        #expect(state == .empty(reason: .noData))
    }

    @Test("series populated within range → .ready(latest:samples:) with newest first")
    func readyInsideRange() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = WireRow(id: "a", type: "WEIGHT", value: 73.0, at: now.addingTimeInterval(-86400 * 10), source: nil)
        let newer = WireRow(id: "b", type: "WEIGHT", value: 72.0, at: now.addingTimeInterval(-86400 * 2), source: nil)
        let payload = listPayload(measurements: [older, newer])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let state = try await repo.state(kind: .weight, rangeDays: 30, now: now)
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == "b")
        #expect(samples.count == 2)
    }

    @Test("has data but all outside range → .empty(.outsideRange(latestAt:))")
    func outsideRange() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let veryOld = WireRow(id: "a", type: "WEIGHT", value: 80.0, at: now.addingTimeInterval(-86400 * 120), source: nil)
        let payload = listPayload(measurements: [veryOld])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let state = try await repo.state(kind: .weight, rangeDays: 30, now: now)
        guard case let .empty(reason) = state, case let .outsideRange(latestAt) = reason else {
            Issue.record("Expected .empty(.outsideRange), got \(state)")
            return
        }
        // Server emits ISO with fractional seconds; equality at second-resolution.
        #expect(abs(latestAt.timeIntervalSince(veryOld.at)) < 1)
    }

    @Test("source filter removes every in-range row → .empty(.sourceFiltered)")
    func sourceFiltered() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let appleOnly = WireRow(id: "a", type: "WEIGHT", value: 71.0, at: now.addingTimeInterval(-86400 * 3), source: "APPLE_HEALTH")
        let payload = listPayload(measurements: [appleOnly])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let state = try await repo.state(
            kind: .weight,
            rangeDays: 30,
            sourceFilter: .manual,
            now: now
        )
        #expect(state == .empty(reason: .sourceFiltered))
    }

    // The PA4 §1 surprise — summary-endpoint says "no latestValue" while the
    // series endpoint has rows. After the refactor, the tile reads through
    // `state(kind:)`, which goes through the same `/api/measurements` page
    // the detail does → no false-empty. Pinned here as a regression guard.
    @Test("PA4 regression guard: series populated → tile state is .ready")
    func pa4RegressionGuard() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentPulse = WireRow(id: "p1", type: "PULSE", value: 64.0, at: now.addingTimeInterval(-3600), source: "APPLE_HEALTH")
        let payload = listPayload(measurements: [recentPulse])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let state = try await repo.state(kind: .pulse, rangeDays: 30, now: now)
        #expect(state.hasValue, "Tile state must be .ready when the recent endpoint has data, even if the summary endpoint would say nil")
        #expect(state.latestMeasurement?.id == "p1")
    }
}
