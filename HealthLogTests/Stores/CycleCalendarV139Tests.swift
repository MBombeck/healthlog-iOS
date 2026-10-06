import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 1.6 — the v1.39 cycle calendar.**
///
/// Calendar days carry `cycleDay` and `periodEndable`, resolved per date by the
/// server (`src/lib/cycle/engine-adapter.ts` `buildCalendar` at v1.39.0). The
/// capture sheet labels a chosen date with its own cycle day and offers "period
/// ended" only where the server says an end can land. A stored period boundary
/// can absorb a start tapped within ten days after it or give an absorbed one
/// back (`src/lib/cycle/cycle-boundaries.ts`), and neither the period route nor
/// the cycle DELETE says so in its response, so the grid is refetched after
/// every boundary that landed.
///
/// Fixtures follow the v1.39.0 `CycleCalendarEnvelope` (every required day key)
/// with the values the server's own `engine-adapter.test.ts` asserts for starts
/// on 2026-01-26 and 2026-09-17, today 2026-09-24. Real `APIClient` over a
/// per-test `MockURLProtocolSession`.
@MainActor
@Suite("#115 1.6 — v1.39 cycle calendar")
struct CycleCalendarV139Tests {
    // MARK: - Fixtures (v1.39.0 wire shape)

    /// One `data.days[]` entry. `endable == nil` drops BOTH v1.39 keys: the
    /// shape a server older than v1.39 sends.
    private nonisolated static func day(
        _ date: String,
        cycleDay: Int?,
        endable: Bool?,
        isCycleStart: Bool = false,
        flow: String? = nil
    ) -> String {
        let v139 = endable.map { #""cycleDay":\#(cycleDay.map(String.init) ?? "null"),"periodEndable":\#($0),"# } ?? ""
        let flowValue = flow.map { "\"\($0)\"" } ?? "null"
        return """
        {"date":"\(date)","phase":null,"isPredictedPeriod":false,"isFertileWindow":false,\
        "isPredictedOvulation":false,"isPeriodLogged":\(flow != nil),"isCycleStart":\(isCycleStart),\
        \(v139)"flow":\(flowValue),"hasSymptoms":false,"confidence":0.3,"basalBodyTempC":null,\
        "temperatureExcluded":false,"ovulationTest":null,"cervicalMucus":null,"cervixPosition":null,\
        "cervixFirmness":null,"cervixOpening":null}
        """
    }

    /// Today's verdict for the open cycle that started 2026-09-17 (day 8 on
    /// 2026-09-24) — deliberately NOT the chosen date's day.
    private nonisolated static let verdict = """
    {"state":"IN_CYCLE","dayOfCycle":8,"cycleLength":28,"phase":"FOLLICULAR",\
    "spans":[{"phase":"MENSTRUAL","fraction":0.18},{"phase":"FOLLICULAR","fraction":0.29},\
    {"phase":"OVULATORY","fraction":0.07},{"phase":"LUTEAL","fraction":0.46}],\
    "cycleStartDate":"2026-09-17","overdueDays":null,"daysUntilNext":21,\
    "fertileWindow":{"start":"2026-09-25","end":"2026-09-30","active":false}}
    """

    private nonisolated static func calendar(_ days: [String]) -> String {
        """
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,\
        "cyclesObserved":2},"prediction":null,"verdict":\(verdict),"stillLearning":false,\
        "days":[\(days.joined(separator: ","))],"meta":{"generatedAt":"2026-09-24T08:00:00.000Z"}},\
        "error":null,"meta":{"requestId":"req-cal"}}
        """
    }

    /// The v1.39 grid from the server's own test: 2026-01-25 before the start,
    /// 2026-01-26 day 1, 2026-01-28 day 3 (endable), 2026-02-20 day 26 (past
    /// `PERIOD_MAX` 10, not endable).
    private nonisolated static let v139Days = [
        day("2026-01-25", cycleDay: nil, endable: false),
        day("2026-01-26", cycleDay: 1, endable: true, isCycleStart: true, flow: "MEDIUM"),
        day("2026-01-28", cycleDay: 3, endable: true),
        day("2026-02-20", cycleDay: 26, endable: false)
    ]

    private static func decodeDays(_ days: [String]) throws -> [CalendarDayDTO] {
        let envelope = try JSONDecoder.hlDefault.decode(
            APIEnvelope<CycleCalendarResponse>.self,
            from: Data(calendar(days).utf8)
        )
        return try #require(envelope.data).days
    }

    // MARK: - Decode

    @Test("v1.39 days decode cycleDay and periodEndable; null stays unknown")
    func decodesV139Fields() throws {
        let days = try Self.decodeDays(Self.v139Days)
        #expect(days.map(\.cycleDay) == [nil, 1, 3, 26])
        #expect(days.map(\.periodEndable) == [false, true, true, false])
    }

    @Test("a server older than v1.39 decodes with both fields absent, not invented")
    func olderServerDecodesWithoutFields() throws {
        let days = try Self.decodeDays([Self.day("2026-01-28", cycleDay: nil, endable: nil)])
        #expect(days.count == 1)
        #expect(days[0].cycleDay == nil)
        #expect(days[0].periodEndable == nil)
    }

    @Test("a malformed cycleDay does not fail the day or the grid")
    func malformedFieldIsTolerated() throws {
        let odd = Self.day("2026-01-28", cycleDay: 3, endable: true)
            .replacingOccurrences(of: #""cycleDay":3"#, with: #""cycleDay":"3""#)
        let days = try Self.decodeDays([odd])
        #expect(days.first?.cycleDay == nil)
        #expect(days.first?.periodEndable == true)
    }

    // MARK: - What the sheet says about a chosen date

    @Test("a chosen past date shows its own cycle day, not today's")
    func chosenDateCarriesItsOwnCycleDay() throws {
        let days = try Self.decodeDays(Self.v139Days)
        let context = CycleCaptureDayContext(date: "2026-01-28", days: days)
        #expect(context.cycleDay == 3) // today's verdict says 8
        #expect(context.offersPeriodEnd)
    }

    @Test("period ended is withheld where the server says it cannot land")
    func periodEndFollowsPeriodEndable() throws {
        let days = try Self.decodeDays(Self.v139Days)
        let late = CycleCaptureDayContext(date: "2026-02-20", days: days)
        #expect(late.cycleDay == 26)
        #expect(late.offersPeriodEnd == false)
        let beforeFirstStart = CycleCaptureDayContext(date: "2026-01-25", days: days)
        #expect(beforeFirstStart.cycleDay == nil)
        #expect(beforeFirstStart.offersPeriodEnd == false)
    }

    @Test("a date outside a v1.39 grid gets no claims at all")
    func dateOutsideGridClaimsNothing() throws {
        let days = try Self.decodeDays(Self.v139Days)
        let context = CycleCaptureDayContext(date: "2025-06-01", days: days)
        #expect(context.cycleDay == nil)
        #expect(context.offersPeriodEnd == false)
    }

    @Test("an older server or an unloaded grid keeps the earlier behaviour")
    func olderServerKeepsEarlierBehaviour() throws {
        let old = try Self.decodeDays([Self.day("2026-01-28", cycleDay: nil, endable: nil)])
        let context = CycleCaptureDayContext(date: "2026-01-28", days: old)
        #expect(context.cycleDay == nil)
        #expect(context.offersPeriodEnd)
        let unloaded = CycleCaptureDayContext(date: "2026-01-28", days: [])
        #expect(unloaded.cycleDay == nil)
        #expect(unloaded.offersPeriodEnd)
    }

    // MARK: - Refetch after a boundary write

    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var calendarReads = 0

        func record(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let path = request.url?.path ?? ""
            entries.append("\(request.httpMethod ?? "GET") \(path)")
            if path == "/api/cycle/calendar" { calendarReads += 1 }
            return calendarReads
        }

        var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeStore(_ session: MockURLProtocolSession) throws -> CycleStore {
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.1.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        let defaults = UserDefaults(suiteName: "CycleCalendarV139Tests.\(UUID().uuidString)")!
        let settings = SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
        let gate = CycleGate(settings: settings, moduleGate: ModuleGate(modules: [ModuleKey.cycle.wireKey: true]))
        #expect(gate.isCycleTrackingAvailable)
        let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
        return CycleStore(repository: repo, gate: gate)
    }

    private nonisolated static func respond(_ request: URLRequest, _ status: Int, _ body: String?) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body.map { Data($0.utf8) })
    }

    /// `POST /api/cycle/period` 200 at v1.39.0: `{ cycle, dayLog }` — and no
    /// word about the start it folded in.
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

    /// Before the tap the grid holds the start on 2026-09-17; after it the
    /// server has folded that start into 2026-09-14.
    private nonisolated static let before = calendar([
        day("2026-09-14", cycleDay: 29, endable: false),
        day("2026-09-17", cycleDay: 1, endable: true, isCycleStart: true, flow: "MEDIUM")
    ])
    private nonisolated static let after = calendar([
        day("2026-09-14", cycleDay: 1, endable: true, isCycleStart: true, flow: "MEDIUM"),
        day("2026-09-17", cycleDay: 4, endable: true, flow: "MEDIUM")
    ])

    private func install(_ session: MockURLProtocolSession, ledger: Ledger, dayLogStatus: Int) {
        session.install { request in
            let reads = ledger.record(request)
            switch request.url?.path ?? "" {
            case "/api/cycle/calendar": return Self.respond(request, 200, reads == 1 ? Self.before : Self.after)
            case "/api/cycle/cycles": return Self.respond(request, 200, Self.cyclesBody)
            case "/api/cycle/profile": return Self.respond(request, 200, Self.profileBody)
            case "/api/cycle/period": return Self.respond(request, 200, Self.periodBody)
            case "/api/cycle/day-logs" where dayLogStatus == 422:
                // `returnAllZodIssues(…, 422, { errorCode: "cycle.day-log.invalid" })`.
                return Self.respond(request, 422, """
                {"data":null,"error":"Validation failed","details":{"issues":[]},\
                "meta":{"errorCode":"cycle.day-log.invalid"}}
                """)
            case "/api/cycle/day-logs":
                return Self.respond(request, 201, #"{"data":{"id":"dl-1","date":"2026-09-14","flow":"MEDIUM"},"error":null}"#)
            default: return Self.respond(request, 404, #"{"data":null,"error":"Not found"}"#)
            }
        }
    }

    private static let startOn0914 = CyclePeriodRequest(
        action: .start,
        date: "2026-09-14",
        loggedAt: "2026-09-24T08:00:00Z",
        externalId: "cycle-period:start:2026-09-14"
    )

    private func write() -> CycleDayLogWrite {
        CycleCaptureSheet.buildWrite(
            date: ProfileDay.startOfDay(forKey: "2026-09-14") ?? .now,
            flow: .medium,
            selectedSymptoms: [],
            symptomSeverity: [:],
            hasBBT: false,
            bbt: 36.5,
            ovulationTest: nil,
            cervicalMucus: nil,
            sexualActivity: false,
            protectedSex: false,
            note: ""
        )
    }

    @Test("a stored start is refetched even when the day log after it is refused")
    func storedStartRefetchesWhenDayLogFails() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger, dayLogStatus: 422)
        let store = try makeStore(session)
        await store.load()
        #expect(store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-17")

        let ok = await store.commitCapture(dayLog: write(), period: Self.startOn0914)

        #expect(ok == false)
        #expect(store.lastError != nil) // the refetch does not swallow the refusal
        let requests = ledger.requests
        let periodIndex = try #require(requests.firstIndex(of: "POST /api/cycle/period"))
        #expect(requests[(periodIndex + 1)...].contains("GET /api/cycle/calendar"))
        // The grid now shows what the server did: 09-17 folded into 09-14.
        #expect(store.calendar?.days.first { $0.isCycleStart }?.date == "2026-09-14")
    }

    @Test("a stored start and day log refetch the grid the server rewrote")
    func storedStartRefetches() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger, dayLogStatus: 201)
        let store = try makeStore(session)
        await store.load()

        let ok = await store.commitCapture(dayLog: write(), period: Self.startOn0914)

        #expect(ok)
        #expect(ledger.requests.filter { $0 == "GET /api/cycle/calendar" }.count == 2)
        let chosen = CycleCaptureDayContext(date: "2026-09-17", days: store.calendar?.days ?? [])
        #expect(chosen.cycleDay == 4)
    }

    // MARK: - DELETE of an already-deleted cycle

    @Test("a 204 without a body is a successful delete, also for an already-deleted cycle")
    func deleteOfTombstoneIsSuccess() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        session.install { request in
            _ = ledger.record(request)
            // `cycles/[id]/route.ts` at v1.39.0: `existing.deletedAt !== null`
            // → `new Response(null, { status: 204 })`.
            return Self.respond(request, 204, nil)
        }
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.1.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))

        try await repo.deleteCycle(id: "cyc-0917")
        try await repo.deleteCycle(id: "cyc-0917")
        // `day-logs/[id]` answers the same way; its Outbox replay goes the same path.
        try await repo.deleteDayLog(id: "dl-0917")
        try await repo.replayDeleteDayLog(id: "dl-0917", idempotencyKey: "idem-dl-0917")

        #expect(ledger.requests == [
            "DELETE /api/cycle/cycles/cyc-0917",
            "DELETE /api/cycle/cycles/cyc-0917",
            "DELETE /api/cycle/day-logs/dl-0917",
            "DELETE /api/cycle/day-logs/dl-0917"
        ])
    }
}
