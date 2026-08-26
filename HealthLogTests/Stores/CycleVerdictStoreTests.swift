import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Z1 (#72) — the cut between forecast and judgement, at the store.**
///
/// The on-device engine keeps computing the FORECAST offline (dates, bands,
/// expected next start), labelled ``CyclePredictionProvenance/onDevice``. It no
/// longer produces a VERDICT. `state`, `phase` and `overdueDays` come from the
/// server or from the last thing the server said — never from this device —
/// because the server resolves "today" from the PROFILE timezone, and a
/// travelling device offline can be a day out. A day out in a forecast is a
/// rounding error; a day out in "overdue" is a false statement about a person's
/// body, and she cannot see why.
///
/// Real `APIClient` + `MockURLProtocol` per the test doctrine — never a mock
/// server. `.serialized` because the handler is global.
@MainActor
@Suite("Z1 — server verdict, stored and restored", .serialized)
struct CycleVerdictStoreTests {
    private struct StubReach: ReachabilityProviding, @unchecked Sendable {
        var online = true
        func isCurrentlyOnline() async -> Bool {
            online
        }

        var isOnlineStream: AsyncStream<Bool> {
            AsyncStream { $0.finish() }
        }
    }

    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeFlagsEnabled() async -> FeatureFlagsStore {
        let repo = FeatureFlagsRepository(api: makeClient())
        let store = FeatureFlagsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"cycle.tracking":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        return store
    }

    private func makeFemaleSettings() async -> SettingsStore {
        let defaults = UserDefaults(suiteName: "CycleVerdictStoreTests.\(UUID().uuidString)")!
        let settings = SettingsStore(repo: SettingsRepository(api: makeClient()), defaults: defaults)
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":"female","heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String? = switch path {
            case "/api/user/profile": profileJSON
            case "/api/auth/me": #"{"data":{"id":"u1","username":"u","email":"u@example.com","avatarUrl":null},"error":null}"#
            case "/api/integrations/healthkit": #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
            default: nil
            }
            guard let body else {
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        await settings.load()
        return settings
    }

    private func makeGate() async -> CycleGate {
        let flags = await makeFlagsEnabled()
        let settings = await makeFemaleSettings()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable)
        return gate
    }

    /// The `IN_CYCLE` verdict block, forecast to end in `until` days.
    private func verdictJSON(until: Int) -> String {
        """
        {"state":"IN_CYCLE","dayOfCycle":9,"cycleLength":28,"phase":"FOLLICULAR",\
        "spans":[{"phase":"MENSTRUAL","fraction":0.18},{"phase":"FOLLICULAR","fraction":0.29},\
        {"phase":"OVULATORY","fraction":0.07},{"phase":"LUTEAL","fraction":0.46}],\
        "cycleStartDate":"2026-06-01","overdueDays":null,"daysUntilNext":\(until),\
        "fertileWindow":{"start":"2026-06-09","end":"2026-06-15","active":true}}
        """
    }

    private func installCalendarHandler(verdict: String, generatedAt: String?) {
        let meta = generatedAt.map { ",\"meta\":{\"generatedAt\":\"\($0)\"}" } ?? ""
        let calendarJSON = """
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,\
        "predictionEnabled":true,"cyclesObserved":4},"prediction":null,\
        "verdict":\(verdict),"days":[],"stillLearning":false\(meta)},"error":null}
        """
        let profileJSON = """
        {"data":{"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,\
        "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,\
        "typicalCycleLength":null,"typicalPeriodLength":null,"lutealPhaseLength":null,\
        "secondarySymptom":"MUCUS","updatedAt":"2026-06-10T00:00:00.000Z"},"error":null}
        """
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String = switch path {
            case "/api/cycle/calendar": calendarJSON
            case "/api/cycle/cycles": #"{"data":{"cycles":[],"stats":null},"error":null}"#
            case "/api/cycle/profile": profileJSON
            default: #"{"data":null,"error":null}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    // MARK: - The server path

    @Test("the server verdict is consumed verbatim and stamped with meta.generatedAt")
    func serverVerdictIsCanonical() async throws {
        let gate = await makeGate()
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        let store = CycleStore(repository: repo, gate: gate)
        installCalendarHandler(verdict: verdictJSON(until: 20), generatedAt: "2026-06-09T12:20:00Z")
        await store.load()

        let snapshot = try #require(store.verdict)
        #expect(snapshot.verdict.stateValue == .inCycle)
        #expect(snapshot.verdict.dayOfCycle == 9)
        #expect(snapshot.verdict.phaseValue == .follicular)
        #expect(snapshot.verdict.spans.count == 4)
        // Stamped with the SERVER's generation time, not the receive time — the
        // envelope can be served from the persistent cache, and "when we read
        // it" would overstate how fresh the judgement is.
        #expect(snapshot.asOf == ISO8601DateFormatter.plain.date(from: "2026-06-09T12:20:00Z"))
        // A live server answer is not dated on screen.
        #expect(store.verdictIsRestored == false)
    }

    /// A server older than v1.35.2 publishes no verdict. The app makes no state
    /// claim at all rather than reconstructing one from `dayOfCycle` and
    /// `cycleLength` — that reconstruction is exactly what this unit removed.
    @Test("a server without a verdict yields no verdict, not a reconstructed one")
    func serverWithoutVerdictClaimsNothing() async throws {
        let gate = await makeGate()
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        let store = CycleStore(repository: repo, gate: gate)
        installCalendarHandler(verdict: "null", generatedAt: nil)
        await store.load()
        #expect(store.verdict == nil)
        #expect(store.verdictIsRestored == false)
    }

    // MARK: - The offline path

    /// Offline the ring shows the LAST SERVER verdict, flagged so the surface
    /// dates it. Nothing about the state is recomputed on the device.
    @Test("offline restores the stored verdict and flags it as dated")
    func offlineRestoresStoredVerdict() async throws {
        let gate = await makeGate()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach())
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true), swr: swr)

        // First run: online, the verdict lands and is persisted.
        let online = CycleStore(repository: repo, gate: gate)
        let generatedAt = ISO8601DateFormatter.plain.string(from: Date().addingTimeInterval(-3600))
        installCalendarHandler(verdict: verdictJSON(until: 20), generatedAt: generatedAt)
        await online.load()
        #expect(online.verdict?.verdict.dayOfCycle == 9)

        // Second run on the same device, now offline: a fresh store, cold
        // memory, no network. `BackendAvailability(nil, nil)` is unreachable.
        let offline = CycleStore(
            repository: repo,
            gate: gate,
            availability: BackendAvailability(syncMode: nil, authStore: nil)
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await offline.load()

        let restored = try #require(offline.verdict)
        #expect(restored.verdict.dayOfCycle == 9)
        #expect(restored.verdict.phaseValue == .follicular)
        #expect(offline.verdictIsRestored)
        // The calendar itself was never fetched — this is purely the stored
        // judgement, dated.
        #expect(offline.calendar == nil)
    }

    /// Past its own horizon the stored verdict is not shown at all. A week-old
    /// "everything is within range" whose own forecast said "period in two days"
    /// cannot answer whether the period arrived — and the reader would take
    /// exactly that from it.
    @Test("a stored verdict past its own horizon is dropped, not shown stale")
    func expiredStoredVerdictIsDropped() async throws {
        let gate = await makeGate()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach())
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true), swr: swr)

        // A verdict that forecast the cycle ending in 2 days, generated 9 days ago.
        let stale = ISO8601DateFormatter.plain.string(from: Date().addingTimeInterval(-9 * 86400))
        let online = CycleStore(repository: repo, gate: gate)
        installCalendarHandler(verdict: verdictJSON(until: 2), generatedAt: stale)
        await online.load()
        #expect(online.verdict != nil)

        let offline = CycleStore(
            repository: repo,
            gate: gate,
            availability: BackendAvailability(syncMode: nil, authStore: nil)
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await offline.load()
        #expect(offline.verdict == nil)
        #expect(offline.verdictIsRestored == false)
    }

    /// The forecast half of the cut still works offline — and stays labelled.
    /// The verdict half does not follow it.
    @Test("the on-device engine still forecasts offline; it does not judge")
    func offlineForecastSurvivesTheCut() async throws {
        let gate = await makeGate()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach())
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true), swr: swr)
        let store = CycleStore(
            repository: repo,
            gate: gate,
            availability: BackendAvailability(syncMode: nil, authStore: nil)
        )
        // Seed a real history so the engine has something to forecast from.
        let today = CycleCalendarWindow.todayKey()
        let starts = [84, 56, 28, 0].map { CyclePredictionEngine.addDays(today, -$0) }
        let rows = starts.map { start in
            """
            {"id":"c-\(start)","startDate":"\(start)","endDate":null,"periodEndDate":null,\
            "lengthDays":null,"ovulationDate":null,"ovulationConfirmed":false,\
            "isPredicted":false,"syncVersion":1,"updatedAt":null}
            """
        }
        let cyclesJSON = "{\"data\":{\"cycles\":[\(rows.joined(separator: ","))],\"stats\":null},\"error\":null}"
        let calendarJSON = """
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,\
        "predictionEnabled":true,"cyclesObserved":4},"prediction":null,\
        "verdict":\(verdictJSON(until: 20)),"days":[],"stillLearning":false},"error":null}
        """
        // Bring the history in while online, then go offline.
        let warm = CycleStore(repository: repo, gate: gate)
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String = switch path {
            case "/api/cycle/cycles": cyclesJSON
            case "/api/cycle/calendar": calendarJSON
            default: #"{"data":null,"error":null}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        await warm.load()
        #expect(warm.predictionProvenance == .onDevice)

        // Offline store, cold memory: no history in memory → no forecast, and
        // the verdict comes from the store rather than from an on-device guess.
        await store.load()
        #expect(store.verdictIsRestored)
        #expect(store.predictionProvenance != .server)
    }
}
