import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **1.4 B1 — the detail chart says „Noch keine Daten" only when it is true.**
///
/// R2 1.4 item 8: `ChartCard` fell back to „Noch keine Daten" three seconds into
/// a load that had not finished, and after a failed one. ``ChartCardPhase`` is
/// the pure rule the card now renders from; the second suite drives the real
/// store through the two ways the old card lied.
@Suite("1.4 B1 · ChartCardPhase — Laden, Fehler und leer sind drei Zustände")
struct ChartCardPhaseTests {
    private static let sample = HealthLog.Measurement(
        id: "m1",
        kind: .weight,
        recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
        value: .scalar(72)
    )

    @Test("Punkte entscheiden zuerst, auch während eines Ladevorgangs oder nach einem Fehler")
    func pointsDecideFirst() {
        #expect(ChartCardPhase.resolve(pointCount: 2, dataState: .loading, isLoading: true, hasError: true) == .chart)
        #expect(ChartCardPhase.resolve(pointCount: 1, dataState: .loading, isLoading: true, hasError: false) == .singlePoint)
    }

    @Test("Ein laufender Ladevorgang ist ein Spinner, auch wenn ein früherer leer endete")
    func inFlightLoadIsLoadingNotEmpty() {
        #expect(
            ChartCardPhase.resolve(pointCount: 0, dataState: .empty(reason: .noData), isLoading: true, hasError: false)
                == .loading
        )
        #expect(ChartCardPhase.resolve(pointCount: 0, dataState: .loading, isLoading: true, hasError: false) == .loading)
    }

    @Test("Noch nichts gefragt ist ein Spinner, kein Leerzustand")
    func nothingAskedYetIsLoading() {
        #expect(ChartCardPhase.resolve(pointCount: 0, dataState: .unknown, isLoading: false, hasError: false) == .loading)
    }

    @Test("Ein gescheiterter Ladevorgang zeigt den Fehler, nicht „Noch keine Daten“")
    func failedLoadIsFailed() {
        // The store collapses a failed load to `.empty(.noData)` so nothing spins
        // forever; the error is what tells the two apart.
        #expect(
            ChartCardPhase.resolve(pointCount: 0, dataState: .empty(reason: .noData), isLoading: false, hasError: true)
                == .failed
        )
    }

    @Test("Nur ein fertiger Ladevorgang ohne Punkte und ohne Fehler ist leer")
    func finishedEmptyLoadIsEmpty() {
        #expect(
            ChartCardPhase.resolve(pointCount: 0, dataState: .empty(reason: .noData), isLoading: false, hasError: false)
                == .empty
        )
        #expect(
            ChartCardPhase.resolve(
                pointCount: 0,
                dataState: .empty(reason: .outsideRange(latestAt: Self.sample.recordedAt)),
                isLoading: false,
                hasError: false
            ) == .empty
        )
        // A settled page with rows but no drawable series never spins forever.
        #expect(
            ChartCardPhase.resolve(
                pointCount: 0,
                dataState: .ready(latest: Self.sample, samples: [Self.sample]),
                isLoading: false,
                hasError: false
            ) == .empty
        )
    }
}

@Suite("1.4 B1 · ChartDetailStore — langsames Netz und Fehler", .serialized, .mockURLSession)
@MainActor
struct ChartCardLoadingHonestyTests {
    private func makeStore(kind: MetricKind, preLoadHook: (@Sendable () async -> Void)? = nil) throws -> ChartDetailStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return try ChartDetailStore(
            kind: kind,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" },
            preLoadHook: preLoadHook
        )
    }

    private func phase(_ store: ChartDetailStore) -> ChartCardPhase {
        ChartCardPhase.resolve(
            pointCount: store.chartPoints.count,
            dataState: store.dataState,
            isLoading: store.isLoading,
            hasError: store.error != nil
        )
    }

    private nonisolated static func respond(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// Every account read answers „no rows"; the insights reads 404.
    private func installEmptyServer() {
        MockURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/insights/") {
                return Self.respond(request, status: 404, body: "{}")
            }
            if path.contains("/api/measurements/series") {
                return Self.respond(
                    request,
                    status: 200,
                    body: #"{"data":{"kind":"weight","points":[],"stats":{"mean":0,"min":0,"max":0,"stdDev":0,"count":0}}}"#
                )
            }
            return Self.respond(request, status: 200, body: #"{"data":{"measurements":[]}}"#)
        }
    }

    @Test("Ein abgelöster Ladevorgang beendet den Spinner seines Nachfolgers nicht")
    func supersededLoadKeepsTheSpinner() async throws {
        let gate = HookGate()
        let store = try makeStore(kind: .weight, preLoadHook: { await gate.enter() })
        installEmptyServer()

        // Load 1 finishes its fan-out (empty) and parks in the pre-load hook.
        let first = Task { await store.load() }
        await gate.waitUntilEntered(1)
        #expect(store.isLoading)

        // Load 2 replaces it (a range change, a pull, a page re-entry) and parks
        // as well, standing for a request that is still on the wire.
        let second = Task { await store.load() }
        await gate.waitUntilEntered(2)

        // Load 1 unwinds only now, after load 2 has begun: the order a slow
        // network produces.
        await gate.release(1)
        await first.value

        #expect(store.isLoading, "the superseded load ended the spinner of the load still in flight")
        #expect(phase(store) == .loading, "a load in flight must not read „Noch keine Daten“")

        await gate.release(2)
        await second.value

        #expect(!store.isLoading)
        #expect(store.error == nil)
        #expect(phase(store) == .empty, "only the finished, empty load shows „Noch keine Daten“")
    }

    @Test("Eine Seite ohne Serie, die nicht lädt, ist ein Fehler und keine leere Historie")
    func failedPageWithoutSeriesIsAFailure() async throws {
        // `.bodyTemperature` has no `/series`, so the page is the only evidence.
        let store = try makeStore(kind: .bodyTemperature)
        MockURLProtocol.install { request in
            Self.respond(request, status: 500, body: "{}")
        }
        await store.load()

        #expect(!store.isLoading)
        #expect(store.error != nil, "a failed read without a series must surface as an error")
        #expect(phase(store) == .failed)
    }

    @Test("Scheitern Serie und Seite, zeigt die Karte den Fehler")
    func failedSeriesIsAFailure() async throws {
        let store = try makeStore(kind: .weight)
        MockURLProtocol.install { request in
            Self.respond(request, status: 500, body: "{}")
        }
        await store.load()

        #expect(store.error != nil)
        #expect(phase(store) == .failed)
    }

    @Test("Ein leerer Server bleibt „Noch keine Daten“")
    func emptyServerIsEmpty() async throws {
        let store = try makeStore(kind: .weight)
        installEmptyServer()
        await store.load()

        #expect(store.error == nil)
        #expect(phase(store) == .empty)
    }

    /// Parks each pre-load hook call until the test releases that call.
    private actor HookGate {
        private var entered = 0
        private var released: Set<Int> = []
        private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
        private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func enter() async {
            entered += 1
            let call = entered
            let ready = entryWaiters.filter { $0.count <= entered }
            entryWaiters.removeAll { $0.count <= entered }
            ready.forEach { $0.continuation.resume() }
            guard !released.contains(call) else { return }
            await withCheckedContinuation { releaseWaiters[call] = $0 }
        }

        func waitUntilEntered(_ count: Int) async {
            guard entered < count else { return }
            await withCheckedContinuation { entryWaiters.append((count, $0)) }
        }

        func release(_ call: Int) {
            released.insert(call)
            releaseWaiters.removeValue(forKey: call)?.resume()
        }
    }
}
