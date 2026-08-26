import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.11 W56 (#56 / #55) regression guard — the chart-detail first paint must
/// NOT block on the cumulative pre-load hook (the HealthKit daily-stats
/// refresh wired for active energy / steps). Pre-fix, `ChartDetailStore.load()`
/// `await`ed `preLoadHook()` INLINE at the very top, before the SWR series
/// fan-out, so opening a cumulative chart waited on a HealthKit aggregate
/// round-trip + server POST before it could paint a single point (operator:
/// "active energy takes extremely long") and a range change held the previous
/// range's series until both the HK block AND the new fetch finished (it looked
/// frozen — #55).
///
/// These tests pin the structural fix: the series fan-out paints FIRST, the
/// pre-load hook runs OFF the first-paint path. The harness uses the real
/// `APIClient` over a stub `URLSession` (per the repo's "no mock-server for
/// repository paths" doctrine) so the SWR series path is exercised end-to-end.
@Suite("ChartDetailStore — non-blocking pre-load (#56) + range re-fetch (#55)", .serialized)
@MainActor
struct ChartDetailPreloadNonBlockingTests {
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.11.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo(api: APIClient) throws -> MeasurementsRepository {
        try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// A small two-point weight series so the chart counts as "populated".
    private func weightSeriesPayload() -> Data {
        let now = Date.now
        let p1 = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
        let p2 = ISO8601DateFormatter().string(from: now)
        let json = """
        {"data":{"kind":"weight","points":[\
        {"id":"a","at":"\(p1)","value":80.0},\
        {"id":"b","at":"\(p2)","value":80.5}\
        ],"stats":{"mean":80.25,"min":80.0,"max":80.5,"stdDev":0.25,"count":2}}}
        """
        return Data(json.utf8)
    }

    private func installSeriesHandler() {
        let series = weightSeriesPayload()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = HTTPURLResponse(
                url: request.url!,
                statusCode: path.contains("/api/insights/") ? 404 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if path.contains("/api/insights/") {
                return (ok, Data("{}".utf8))
            }
            if path.contains("/api/measurements/series") {
                return (ok, series)
            }
            // recent page
            return (ok, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
    }

    // MARK: - #55 — range change re-fires the query

    @Test("Changing the range bumps queryKey (the .task(id:) re-fires load)")
    func rangeChangeBumpsQueryKey() throws {
        let api = makeAPIClient()
        let repo = try makeRepo(api: api)
        let store = ChartDetailStore(
            kind: .weight,
            measurementsRepo: repo,
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" }
        )
        let before = store.queryKey
        store.range = .week
        let after = store.queryKey
        #expect(before != after, "A range change must move queryKey so .task(id:) re-fires")
        #expect(after.contains("-7-"), "queryKey must encode the new range window (7d)")
        // Idempotent: re-setting the same range must NOT bump again.
        store.range = .week
        #expect(store.queryKey == after)
    }

    // MARK: - #56 — first paint does not block on the pre-load hook

    @Test("Series paints BEFORE the cumulative pre-load hook resolves")
    func firstPaintDoesNotBlockOnPreloadHook() async throws {
        let api = makeAPIClient()
        installSeriesHandler()
        let repo = try makeRepo(api: api)

        // Gate the pre-load hook on a continuation we only resume AFTER asserting
        // the series already painted. If `load()` awaited the hook before the
        // fan-out (the pre-fix bug), `load()` would deadlock here and the test
        // would time out — exactly the "extremely long" symptom, made fatal.
        let gate = HookGate()
        let store = ChartDetailStore(
            kind: .steps, // cumulative kind — the real wiring attaches a hook here
            measurementsRepo: repo,
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" },
            preLoadHook: { await gate.wait() }
        )

        // Kick the load; do NOT await it yet (the hook is still gated).
        let loadTask = Task { await store.load() }

        // Poll until the series has painted. This must happen WITHOUT the hook
        // having been released — proving the first paint is off the hook path.
        var painted = false
        for _ in 0 ..< 200 where !painted {
            if store.series != nil || store.dataState.isPending == false {
                painted = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(painted, "The chart must paint from the SWR series before the pre-load hook resolves")
        #expect(await gate.released == false, "The pre-load hook must not have been awaited before first paint")

        // Release the hook so the post-preload revalidate + load() complete.
        await gate.release()
        await loadTask.value
        #expect(store.isLoading == false)
    }

    @Test("Non-cumulative kind never wires a pre-load hook — load completes without one")
    func nonCumulativeKindHasNoPreloadBlock() async throws {
        let api = makeAPIClient()
        installSeriesHandler()
        let repo = try makeRepo(api: api)
        let store = ChartDetailStore(
            kind: .weight, // spot kind — no pre-load hook in production wiring
            measurementsRepo: repo,
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" },
            preLoadHook: nil
        )
        await store.load()
        #expect(store.isLoading == false)
        #expect(store.series != nil, "A spot-kind chart paints its series with no pre-load step")
    }
}

/// Test-only async gate so a `@Sendable` pre-load closure can be held open until
/// the test releases it. An `actor` keeps the released flag race-free across the
/// load task + the asserting task.
private actor HookGate {
    private(set) var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for cont in pending {
            cont.resume()
        }
    }
}

// swiftlint:enable force_unwrapping
