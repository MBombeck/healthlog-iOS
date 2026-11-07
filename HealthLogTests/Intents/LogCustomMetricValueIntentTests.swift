import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **1.5 SHORTCUT (#155, public #1295)** — the custom-metric value intent
/// and its entity query, against a stub API and an in-memory outbox and cache.
///
/// Every way a run can end has its own answer: online, offline (outbox),
/// deleted metric (404), refused (403 / `module.disabled`), signed out, a
/// value, date or note the server would refuse. The picker offers the cached
/// list without network.
@Suite("Log custom metric value — intent + entity query")
@MainActor
struct LogCustomMetricValueIntentTests {
    private static let metric = CustomMetricEntity(id: "cm-mood", name: "Mood scale", unit: "points", decimals: 0)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Write

    @Test("Online: POSTs the rounded value to the metric's entries and confirms with name and unit")
    func onlineLogs() async throws {
        let harness = try Self.harness(.succeed)
        let api = harness.api
        let outbox = harness.outbox
        let deps = harness.deps
        let outcome = await LogCustomMetricValue.run(
            metric: Self.metric, value: 4.6, date: nil, note: "  after lunch ", deps: deps, now: Self.now
        )

        #expect(outcome == .logged(name: "Mood scale", shown: "5 points"))
        #expect(await api.sentPaths == ["/api/custom-metrics/cm-mood/entries"])
        let body = try #require(await api.lastBody)
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(sent?["value"] as? Double == 5)
        #expect(sent?["note"] as? String == "after lunch")
        #expect(sent?["measuredAt"] as? String == ISO8601DateFormatter.fractional.string(from: Self.now))
        #expect(await outbox.snapshot.isEmpty)
        #expect(outcome.resource.key == "intents.logCustomMetric.confirmed")
    }

    @Test("Offline: the value lands on the outbox with an idempotency key and the offline answer")
    func offlineQueues() async throws {
        let harness = try Self.harness(.offline)
        let outbox = harness.outbox
        let deps = harness.deps
        let outcome = await LogCustomMetricValue.run(
            metric: Self.metric, value: 3, date: nil, note: nil, deps: deps, now: Self.now
        )

        #expect(outcome == .queued(.offline))
        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createCustomMetricEntry)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
        #expect(outcome.resource.key == IntentCopy.queuedResource(after: .offline).key)
    }

    @Test("Deleted metric (404): says so, nothing queued")
    func deletedMetric() async throws {
        let harness = try Self.harness(.fail(.server(status: 404, code: nil, message: "Custom metric not found")))
        let outbox = harness.outbox
        let deps = harness.deps
        let outcome = await LogCustomMetricValue.run(
            metric: Self.metric, value: 3, date: nil, note: nil, deps: deps, now: Self.now
        )

        #expect(outcome == .metricGone)
        #expect(outcome.resource.key == "intents.logCustomMetric.metricGone")
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("Refused (module.disabled or 403): the feature-disabled sentence, nothing queued")
    func refused() async throws {
        for error in [HLError.moduleDisabled("customMetrics"), .server(status: 403, code: "auth.scope.insufficient", message: "")] {
            let harness = try Self.harness(.fail(error))
            let outbox = harness.outbox
            let deps = harness.deps
            let outcome = await LogCustomMetricValue.run(
                metric: Self.metric, value: 3, date: nil, note: nil, deps: deps, now: Self.now
            )
            #expect(outcome == .disabled)
            #expect(outcome.resource.key == "feature_disabled.title")
            #expect(await outbox.snapshot.isEmpty)
        }
    }

    @Test("Other server refusal (422): the generic could-not-save answer")
    func otherRefusal() async throws {
        let harness = try Self.harness(.fail(.server(status: 422, code: nil, message: "invalid")))
        let deps = harness.deps
        let outcome = await LogCustomMetricValue.run(
            metric: Self.metric, value: 3, date: nil, note: nil, deps: deps, now: Self.now
        )
        #expect(outcome == .failed)
    }

    @Test("Signed out: sign-in answer, no request, nothing queued")
    func signedOut() async throws {
        let harness = try Self.harness(.succeed, signedIn: false)
        let api = harness.api
        let outbox = harness.outbox
        let deps = harness.deps
        let outcome = await LogCustomMetricValue.run(
            metric: Self.metric, value: 3, date: nil, note: nil, deps: deps, now: Self.now
        )

        #expect(outcome == .signedOut)
        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("Value, date and note the server would refuse are answered before any request")
    func refusedBeforeRequest() async throws {
        let harness = try Self.harness(.succeed)
        let api = harness.api
        let outbox = harness.outbox
        let deps = harness.deps
        let cases = [
            RefusalCase(value: .nan, date: nil, note: nil, expected: .invalidValue),
            RefusalCase(value: .infinity, date: nil, note: nil, expected: .invalidValue),
            RefusalCase(value: 3, date: Self.now.addingTimeInterval(3600), note: nil, expected: .invalidDate),
            RefusalCase(value: 3, date: Self.now.addingTimeInterval(-51 * 365.25 * 86400), note: nil, expected: .invalidDate),
            RefusalCase(value: 3, date: nil, note: String(repeating: "x", count: 2001), expected: .noteTooLong)
        ]
        for item in cases {
            let outcome = await LogCustomMetricValue.run(
                metric: Self.metric, value: item.value, date: item.date, note: item.note, deps: deps, now: Self.now
            )
            #expect(outcome == item.expected)
        }
        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("A date a few seconds ahead counts as now; a past date is sent as chosen")
    func dateHandling() async throws {
        let harness = try Self.harness(.succeed)
        let api = harness.api
        let deps = harness.deps
        _ = await LogCustomMetricValue.run(
            metric: Self.metric, value: 3, date: Self.now.addingTimeInterval(20), note: nil, deps: deps, now: Self.now
        )
        let past = Self.now.addingTimeInterval(-7200)
        _ = await LogCustomMetricValue.run(metric: Self.metric, value: 3, date: past, note: nil, deps: deps, now: Self.now)

        let bodies = await api.bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(bodies.map { $0["measuredAt"] as? String } == [
            ISO8601DateFormatter.fractional.string(from: Self.now),
            ISO8601DateFormatter.fractional.string(from: past)
        ])
        #expect(bodies.allSatisfy { $0["note"] == nil })
    }

    @Test("An unresolved metric (empty name) still writes and confirms without a name")
    func unnamedMetric() async throws {
        let harness = try Self.harness(.succeed)
        let deps = harness.deps
        let unnamed = CustomMetricEntity(id: "cm-x", name: "", unit: "", decimals: nil)
        let outcome = await LogCustomMetricValue.run(
            metric: unnamed, value: 2.345, date: nil, note: nil, deps: deps, now: Self.now
        )
        #expect(outcome == .logged(name: "", shown: CustomMetricFormat.number(2.345, decimals: nil)))
        #expect(outcome.resource.key == "intents.logCustomMetric.confirmedUnnamed")
    }

    @Test("Rounding follows the metric's decimals, half away from zero; none leaves the value as given")
    func rounding() {
        #expect(LogCustomMetricValue.roundedValue(4.5, decimals: 0) == 5)
        #expect(LogCustomMetricValue.roundedValue(-4.5, decimals: 0) == -5)
        #expect(LogCustomMetricValue.roundedValue(3.25, decimals: 1) == 3.3)
        #expect(LogCustomMetricValue.roundedValue(1.23456, decimals: 2) == 1.23)
        #expect(LogCustomMetricValue.roundedValue(1.23456, decimals: 9) == 1.234_56)
        #expect(LogCustomMetricValue.roundedValue(2.345, decimals: nil) == 2.345)
    }

    // MARK: - Entity query

    @Test("Suggestions come from the cached list when the network is gone")
    func suggestionsFromCacheOffline() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let list = ListCustomMetricsResponse(customMetrics: [
            CustomMetricDTO(id: "cm-mood", name: "Mood scale", unit: "points", decimals: 0),
            CustomMetricDTO(id: "cm-grip", name: "Grip strength", unit: "kg", decimals: 1)
        ])
        // An hour old, so the SWR ladder would go to the network first; the
        // stub reports "online" like a freshly started intent process does.
        try await cache.write(.customMetrics, payload: JSONEncoder.hlDefault.encode(list), at: .now.addingTimeInterval(-3600))
        let swr = SWRCoordinator(cache: cache, reachability: AlwaysOnlineReachability())
        let harness = try Self.harness(.offline, swr: swr, install: true)
        let api = harness.api
        defer { IntentDependencies.testOverride = nil }

        let suggested = try await CustomMetricEntityQuery().suggestedEntities()
        #expect(suggested.map(\.name) == ["Mood scale", "Grip strength"])
        #expect(suggested.first?.decimals == 0)
        #expect(await api.sentPaths == ["/api/custom-metrics"])

        let matched = try await CustomMetricEntityQuery().entities(matching: "GRIP")
        #expect(matched.map(\.id) == ["cm-grip"])

        let resolved = try await CustomMetricEntityQuery().entities(for: ["cm-mood", "cm-gone"])
        #expect(resolved.map(\.name) == ["Mood scale", ""])
    }

    @Test("Online suggestions come from the live list")
    func suggestionsOnline() async throws {
        _ = try Self.harness(.succeed, install: true)
        defer { IntentDependencies.testOverride = nil }

        let suggested = try await CustomMetricEntityQuery().suggestedEntities()
        #expect(suggested.map(\.name) == ["Mood scale"])
    }

    @Test("Signed out: no suggestions, but a saved shortcut still resolves so the intent can ask to sign in")
    func signedOutQuery() async throws {
        let harness = try Self.harness(.succeed, signedIn: false, install: true)
        let api = harness.api
        defer { IntentDependencies.testOverride = nil }

        #expect(try await CustomMetricEntityQuery().suggestedEntities().isEmpty)
        let resolved = try await CustomMetricEntityQuery().entities(for: ["cm-mood"])
        #expect(resolved.map(\.id) == ["cm-mood"])
        #expect(await api.sentPaths.isEmpty)
    }

    @Test("Offline with no cached list: suggestions fail loudly, a saved id still resolves")
    func offlineWithoutCache() async throws {
        _ = try Self.harness(.offline, install: true)
        defer { IntentDependencies.testOverride = nil }

        await #expect(throws: HLError.self) {
            _ = try await CustomMetricEntityQuery().suggestedEntities()
        }
        let resolved = try await CustomMetricEntityQuery().entities(for: ["cm-mood"])
        #expect(resolved.map(\.id) == ["cm-mood"])
    }

    @Test("Name search ignores case, accents and surrounding blanks")
    func nameMatching() {
        #expect(CustomMetricEntityQuery.matches("Müdigkeit", query: " mudig "))
        #expect(CustomMetricEntityQuery.matches("Mood scale", query: ""))
        #expect(CustomMetricEntityQuery.matches("Mood scale", query: "grip") == false)
    }

    @Test("The shortcut is registered and the provider stays within Apple's ten")
    func providerRegistersShortcut() {
        let shortcuts = HealthLogAppShortcuts.appShortcuts
        #expect(shortcuts.count <= 10)
        #expect(shortcuts.count == 8)
    }

    // MARK: - Harness

    private static func harness(
        _ behaviour: CustomMetricStubAPI.Behaviour,
        signedIn: Bool = true,
        swr: SWRCoordinator? = nil,
        install: Bool = false
    ) throws -> Harness {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = CustomMetricStubAPI(behaviour: behaviour)
        let outbox = try OutboxQueue(inMemory: true)
        let deps = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            customMetricsRepo: CustomMetricsRepository(api: api, outbox: outbox, swr: swr)
        )
        if install { IntentDependencies.testOverride = deps }
        return Harness(api: api, outbox: outbox, deps: deps)
    }

    private struct Harness {
        let api: CustomMetricStubAPI
        let outbox: OutboxQueue
        let deps: IntentDependencies.Resolved
    }

    private struct RefusalCase {
        let value: Double
        let date: Date?
        let note: String?
        let expected: LogCustomMetricValue.Outcome
    }
}

/// Reports "online" like the fresh `Reachability` of an intent process before
/// its first path update, so the SWR ladder tries the network first.
private final class AlwaysOnlineReachability: ReachabilityProviding, @unchecked Sendable {
    var isOnlineStream: AsyncStream<Bool> {
        get async {
            AsyncStream { continuation in
                continuation.yield(true)
                continuation.finish()
            }
        }
    }

    func isCurrentlyOnline() async -> Bool {
        true
    }
}

/// Answers the custom-metric list and the entry POST, or fails every call the
/// way the test asks.
private actor CustomMetricStubAPI: APIClientProtocol {
    enum Behaviour {
        case succeed
        case offline
        case fail(HLError)
    }

    private let behaviour: Behaviour
    private(set) var sentPaths: [String] = []
    private(set) var bodies: [Data] = []
    var lastBody: Data? {
        bodies.last
    }

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        sentPaths.append(request.path)
        if let body = request.body { bodies.append(body) }
        switch behaviour {
        case .offline: throw HLError.offline
        case let .fail(error): throw error
        case .succeed: break
        }
        let json = if request.path == "/api/custom-metrics" {
            """
            {"customMetrics":[{"id":"cm-mood","name":"Mood scale","unit":"points","decimals":0}]}
            """
        } else {
            """
            {"id":"e-1","customMetricId":"cm-mood","value":5,"unit":"points","measuredAt":"2027-01-15T08:00:00.000Z"}
            """
        }
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
