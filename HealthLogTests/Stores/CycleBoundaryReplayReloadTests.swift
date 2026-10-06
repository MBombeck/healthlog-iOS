import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 B6 — a period boundary replayed from the outbox refreshes the grid.**
///
/// Offline, `commitCapture` queues `POST /api/cycle/period` and keeps the old
/// calendar on screen. When the outbox later delivers it, the server can fold
/// a start into the new one (`cycle-boundaries.ts` at v1.39.0), and nothing
/// reloaded the store: the grid kept showing the pre-boundary state until the
/// next manual refresh. The store now follows boundary replays.
@MainActor
@Suite("#115 B6 — cycle store reloads after a replayed boundary")
struct CycleBoundaryReplayReloadTests {
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            entries.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            return entries.count(where: { $0 == "GET /api/cycle/calendar" })
        }

        var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private nonisolated static func day(_ date: String, cycleDay: Int, start: Bool) -> String {
        """
        {"date":"\(date)","phase":null,"isPredictedPeriod":false,"isFertileWindow":false,\
        "isPredictedOvulation":false,"isPeriodLogged":\(start),"isCycleStart":\(start),\
        "cycleDay":\(cycleDay),"periodEndable":true,"flow":\(start ? "\"MEDIUM\"" : "null"),\
        "hasSymptoms":false,"confidence":0.3,"basalBodyTempC":null,"temperatureExcluded":false,\
        "ovulationTest":null,"cervicalMucus":null,"cervixPosition":null,"cervixFirmness":null,\
        "cervixOpening":null}
        """
    }

    private nonisolated static func calendar(_ days: [String]) -> String {
        """
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,\
        "cyclesObserved":2},"prediction":null,"verdict":null,"stillLearning":false,\
        "days":[\(days.joined(separator: ","))],"meta":{"generatedAt":"2026-09-24T08:00:00.000Z"}},\
        "error":null,"meta":{"requestId":"req-cal"}}
        """
    }

    /// Before the replay the start sits on 09-17; the replayed start on 09-14
    /// folds it in.
    private nonisolated static let before = calendar([
        day("2026-09-14", cycleDay: 29, start: false),
        day("2026-09-17", cycleDay: 1, start: true)
    ])
    private nonisolated static let after = calendar([
        day("2026-09-14", cycleDay: 1, start: true),
        day("2026-09-17", cycleDay: 4, start: false)
    ])
    private nonisolated static let periodBody = """
    {"data":{"cycle":{"id":"cyc-0914","startDate":"2026-09-14","endDate":null,"periodEndDate":null,\
    "lengthDays":null,"ovulationDate":null,"ovulationConfirmed":false,"isPredicted":false,"syncVersion":3,\
    "updatedAt":"2026-09-24T08:01:00.000Z"},"dayLog":null},"error":null,"meta":{"requestId":"req-p"}}
    """
    private nonisolated static let cyclesBody = #"{"data":{"cycles":[],"stats":null},"error":null}"#
    private nonisolated static let profileBody = """
    {"data":{"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,\
    "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,\
    "typicalCycleLength":null,"typicalPeriodLength":null,"lutealPhaseLength":null,\
    "secondarySymptom":"MUCUS","updatedAt":"2026-09-01T00:00:00.000Z"},"error":null}
    """

    private nonisolated static func respond(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private struct Harness {
        let store: CycleStore
        let repo: CycleRepository
        let replay: OutboxReplayService
        let outbox: OutboxQueue
    }

    private func makeHarness(_ session: MockURLProtocolSession) throws -> Harness {
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.1.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        let defaults = UserDefaults(suiteName: "CycleBoundaryReplayReloadTests.\(UUID().uuidString)")!
        let settings = SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
        let gate = CycleGate(settings: settings, moduleGate: ModuleGate(modules: [ModuleKey.cycle.wireKey: true]))
        let outbox = try OutboxQueue(inMemory: true)
        let repo = CycleRepository(api: api, outbox: outbox)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            cycleRepo: repo,
            currentUserProvider: { "user-b6" }
        )
        return Harness(store: CycleStore(repository: repo, gate: gate), repo: repo, replay: replay, outbox: outbox)
    }

    private func install(_ session: MockURLProtocolSession, ledger: Ledger) {
        session.install { request in
            let reads = ledger.record(request)
            switch request.url?.path ?? "" {
            case "/api/cycle/calendar": return Self.respond(request, 200, reads <= 1 ? Self.before : Self.after)
            case "/api/cycle/cycles": return Self.respond(request, 200, Self.cyclesBody)
            case "/api/cycle/profile": return Self.respond(request, 200, Self.profileBody)
            case "/api/cycle/period": return Self.respond(request, 200, Self.periodBody)
            default: return Self.respond(request, 404, #"{"data":null,"error":"Not found"}"#)
            }
        }
    }

    private func queueStart(_ outbox: OutboxQueue) async throws {
        let request = CyclePeriodRequest(
            action: .start,
            date: "2026-09-14",
            loggedAt: "2026-09-14T07:00:00Z",
            externalId: "cycle-period:start:2026-09-14"
        )
        try await outbox.enqueue(OutboxQueue.Operation(
            kind: .cyclePeriod,
            payload: JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.CyclePeriod(request: request)),
            idempotencyKey: "idem-period-0914",
            ownerUserID: "user-b6"
        ))
    }

    @Test("the replayed start refetches the calendar the server rewrote")
    func replayedBoundaryReloadsStore() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger)
        let harness = try makeHarness(session)
        await harness.store.followBoundaryReplays()
        await harness.store.load()
        #expect(harness.store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-17")

        try await queueStart(harness.outbox)
        await harness.replay.runOnce()

        let requests = ledger.requests
        let periodIndex = try #require(requests.firstIndex(of: "POST /api/cycle/period"))
        #expect(requests[(periodIndex + 1)...].contains("GET /api/cycle/calendar"))
        #expect(harness.store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-14")
    }

    @Test("a boundary replayed before the store followed is flushed when it starts following")
    func replayBeforeSinkIsNotLost() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger)
        let harness = try makeHarness(session)
        await harness.store.load()

        try await queueStart(harness.outbox)
        await harness.replay.runOnce()
        #expect(harness.store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-17")

        await harness.store.followBoundaryReplays()

        #expect(harness.store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-14")
    }
}
