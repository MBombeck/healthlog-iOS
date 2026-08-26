import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-25 (#72) — one authoritative prediction, with its origin on the record.**
///
/// The server DTO is canonical. The on-device engine survives ONLY as the
/// offline / degraded fallback, and only under two conditions: it renders
/// through the same wire type (so there is no second rendering path), and it is
/// labelled ``CyclePredictionProvenance/onDevice`` so the screen can say where
/// the number came from.
///
/// This suite also covers a straight bug: before CU-25 the offline engine was
/// computed into `offlinePrediction` and then rendered by nothing — the screen
/// reads `prediction`, which the offline branch deliberately left `nil`. The
/// documented "renders from cache + the on-device engine" promise was not kept;
/// the surface silently fell back to "still learning".
///
/// Real `APIClient` + `MockURLProtocol` per the test doctrine — never a mock
/// server. `.serialized` because the handler is global.
@MainActor
@Suite("CU-25 — prediction provenance", .serialized)
struct CyclePredictionProvenanceTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeSettings() -> SettingsStore {
        let repo = SettingsRepository(api: makeClient())
        let defaults = UserDefaults(suiteName: "CyclePredictionProvenanceTests.\(UUID().uuidString)")!
        return SettingsStore(repo: repo, defaults: defaults)
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
        let settings = makeSettings()
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":"female","heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        let meJSON = #"{"data":{"id":"u1","username":"u","email":"u@example.com","avatarUrl":null},"error":null}"#
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String
            switch path {
            case "/api/user/profile": body = profileJSON
            case "/api/auth/me": body = meJSON
            case "/api/integrations/healthkit": body = hkJSON
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        await settings.load()
        return settings
    }

    /// An open-gate store whose calendar route answers with `predictionJSON`
    /// and whose cycles route answers with `cyclesJSON`.
    private func makeStore(predictionJSON: String, cyclesJSON: String) async throws -> CycleStore {
        let flags = await makeFlagsEnabled()
        let settings = await makeFemaleSettings()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable)
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        let store = CycleStore(repository: repo, gate: gate)
        let calendarJSON = """
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,\
        "predictionEnabled":true,"cyclesObserved":4},"prediction":\(predictionJSON),\
        "days":[],"from":"2026-01-01","to":"2026-12-31"},"error":null}
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
            case "/api/cycle/cycles": cyclesJSON
            case "/api/cycle/profile": profileJSON
            default: #"{"data":null,"error":null}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return store
    }

    /// Four cycles at 28-day spacing, ending recently enough that the engine has
    /// a real (non-priors) history whatever "today" is when the suite runs.
    private var cyclesJSON: String {
        let today = CycleCalendarWindow.todayKey()
        let starts = [84, 56, 28, 0].map { CyclePredictionEngine.addDays(today, -$0) }
        let rows = starts.map { start in
            """
            {"id":"c-\(start)","startDate":"\(start)","endDate":null,"periodEndDate":null,\
            "lengthDays":null,"ovulationDate":null,"ovulationConfirmed":false,\
            "isPredicted":false,"syncVersion":1,"updatedAt":null}
            """
        }
        return "{\"data\":{\"cycles\":[\(rows.joined(separator: ","))],\"stats\":null},\"error\":null}"
    }

    // MARK: - Server path

    @Test("a server prediction is consumed verbatim and marked .server")
    func serverPredictionIsCanonical() async throws {
        let serverPrediction = """
        {"method":"CALENDAR","nextPeriodStart":"2026-04-27","nextPeriodStartLow":"2026-04-25",\
        "nextPeriodStartHigh":"2026-04-29","fertileWindowStart":null,"fertileWindowEnd":null,\
        "predictedOvulation":null,"ovulationConfirmed":false,"confidence":0.3,\
        "cyclesObserved":3,"stillLearning":false,"disclaimer":"Server-Hinweis"}
        """
        let store = try await makeStore(predictionJSON: serverPrediction, cyclesJSON: cyclesJSON)
        await store.load()

        #expect(store.predictionProvenance == .server)
        #expect(store.prediction?.nextPeriodStart == "2026-04-27")
        #expect(store.prediction?.nextPeriodStartHigh == "2026-04-29")
        // The server's own disclaimer survives — the client never rewrites it.
        #expect(store.prediction?.disclaimer == "Server-Hinweis")
        // The on-device engine did NOT run: the server answered.
        #expect(store.offlinePrediction == nil)
    }

    // MARK: - Offline / no-server-prediction path

    /// The dead-path fix: when the server sends no prediction, the on-device
    /// result is actually rendered — and labelled.
    @Test("no server prediction → the on-device engine renders, marked .onDevice")
    func offlineFallbackRendersAndIsLabelled() async throws {
        let store = try await makeStore(predictionJSON: "null", cyclesJSON: cyclesJSON)
        await store.load()

        #expect(store.predictionProvenance == .onDevice)
        let rendered = try #require(store.prediction)
        let engine = try #require(store.offlinePrediction)
        // Rendered through the SAME wire type, field-for-field from the engine.
        #expect(rendered.nextPeriodStart == engine.nextPeriodStart)
        #expect(rendered.nextPeriodStartLow == engine.nextPeriodStartLow)
        #expect(rendered.nextPeriodStartHigh == engine.nextPeriodStartHigh)
        #expect(rendered.cyclesObserved == engine.cyclesObserved)
        #expect(rendered.stillLearning == engine.stillLearning)
        #expect(!rendered.nextPeriodStart.isEmpty)
        // GENERAL_HEALTH → the bridge applies the server's own fertility
        // suppression, so the offline path never paints a window the online path
        // refuses to show.
        #expect(rendered.fertileWindowStart == nil)
        #expect(rendered.predictedOvulation == nil)
        // The client invents no disclaimer — the card falls back to its local key.
        #expect(rendered.disclaimer.isEmpty)
    }

    @Test("no history at all → no prediction and no provenance claim")
    func noHistoryNoPrediction() async throws {
        let store = try await makeStore(
            predictionJSON: "null",
            cyclesJSON: #"{"data":{"cycles":[],"stats":null},"error":null}"#
        )
        await store.load()
        #expect(store.prediction == nil)
        #expect(store.predictionProvenance == nil)
        #expect(store.offlinePrediction == nil)
    }

    // MARK: - Reconciliation bookkeeping

    @Test("declining the period prompt is remembered in memory and cleared on logout")
    func declinedSetLifecycle() async throws {
        let store = try await makeStore(predictionJSON: "null", cyclesJSON: cyclesJSON)
        #expect(store.flowReconciliationDeclined.isEmpty)
        store.declineFlowReconciliation(for: "2026-05-21")
        #expect(store.flowReconciliationDeclined == ["2026-05-21"])
        store.clearOnLogout()
        #expect(store.flowReconciliationDeclined.isEmpty)
        #expect(store.predictionProvenance == nil)
    }
}
