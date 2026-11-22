import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #137 (server v1.43, #116 item 9) — merged and restored cycle starts in the
/// response. Fixtures follow `docs/api/openapi.yaml` at `MBombeck/HealthLog`
/// tag `v1.43.0` (`2f5c4659f`): `CyclePeriodEnvelope.absorbed`,
/// `CycleDayLogPatchEnvelope.restored`, `CycleDeleteOutcome` behind
/// `Prefer: return=representation`. Real `APIClient` over a per-test
/// `MockURLProtocolSession`.
@MainActor
@Suite("#137 — merged and restored cycle starts")
struct CycleStartMergeV143Tests {
    // MARK: - Wire fixtures

    private nonisolated static let cycle0914 = """
    {"id":"cyc-0914","startDate":"2026-09-14","endDate":null,"periodEndDate":null,"lengthDays":null,\
    "ovulationDate":null,"ovulationConfirmed":false,"isPredicted":false,"syncVersion":3,\
    "updatedAt":"2026-10-16T08:01:00.000Z"}
    """

    /// v1.43: the start on 09-14 folded the later start on 09-17 into itself.
    private nonisolated static let periodV143 = """
    {"data":{"cycle":\(cycle0914),"dayLog":null,"absorbed":{"cycleId":"cyc-0917","startDate":"2026-09-17"}},\
    "error":null,"meta":{"requestId":"req-p"}}
    """

    /// v1.42: the same write, and no word about the start it folded in.
    private nonisolated static let periodV142 = """
    {"data":{"cycle":\(cycle0914),"dayLog":null},"error":null,"meta":{"requestId":"req-p"}}
    """

    private nonisolated static func dayLog(restored: String?) -> String {
        let extra = restored.map { #","restored":\#($0)"# } ?? ""
        return """
        {"data":{"id":"dl-0914","date":"2026-09-14","cycleId":"cyc-0914","flow":null,\
        "intermenstrualBleeding":null,"basalBodyTempC":null,"ovulationTest":null,"cervicalMucus":null,\
        "sexualActivity":null,"protectedSex":null,"pregnancyTest":null,"progesteroneTest":null,\
        "contraceptive":null,"symptoms":[],"note":null,"source":"MANUAL",\
        "externalId":"cycle-manual:2026-09-14","syncVersion":2,"updatedAt":"2026-10-16T08:00:00.000Z",\
        "deletedAt":null\(extra)},"error":null}
        """
    }

    private nonisolated static let deleteOutcome = """
    {"data":{"removedCycleId":"cyc-0914","restored":[{"cycleId":"cyc-0917","startDate":"2026-09-17"}]},\
    "error":null,"meta":{"requestId":"req-d"}}
    """

    private nonisolated static let calendarBody = """
    {"data":{"profile":null,"prediction":null,"verdict":null,"stillLearning":true,"days":[],\
    "meta":{"generatedAt":"2026-10-16T08:00:00.000Z"}},"error":null}
    """

    private nonisolated static let cyclesBody = #"{"data":{"cycles":[],"stats":null},"error":null}"#

    private nonisolated static let profileBody = """
    {"data":{"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,\
    "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,\
    "typicalCycleLength":null,"typicalPeriodLength":null,"lutealPhaseLength":null,\
    "secondarySymptom":"MUCUS","updatedAt":"2026-09-01T00:00:00.000Z"},"error":null}
    """

    // MARK: - Harness

    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(line: String, prefer: String?)] = []

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")", request.value(forHTTPHeaderField: "Prefer")))
        }

        var requests: [(line: String, prefer: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private nonisolated static func respond(_ request: URLRequest, _ status: Int, _ body: String?) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body.map { Data($0.utf8) })
    }

    private func install(_ session: MockURLProtocolSession, ledger: Ledger, period: String, patch: String) {
        session.install { request in
            ledger.record(request)
            switch request.url?.path ?? "" {
            case "/api/cycle/calendar": return Self.respond(request, 200, Self.calendarBody)
            case "/api/cycle/cycles": return Self.respond(request, 200, Self.cyclesBody)
            case "/api/cycle/profile": return Self.respond(request, 200, Self.profileBody)
            case "/api/cycle/period": return Self.respond(request, 200, period)
            case "/api/cycle/day-logs": return Self.respond(request, 201, Self.dayLog(restored: nil))
            case "/api/cycle/day-logs/dl-0914": return Self.respond(request, 200, patch)
            default: return Self.respond(request, 404, #"{"data":null,"error":"Not found"}"#)
            }
        }
    }

    private func makeRepository(_ session: MockURLProtocolSession) throws -> CycleRepository {
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.3.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        return try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    private func makeStore(_ session: MockURLProtocolSession) throws -> CycleStore {
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.3.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        let defaults = UserDefaults(suiteName: "CycleStartMergeV143Tests.\(UUID().uuidString)")!
        let settings = SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
        let gate = CycleGate(settings: settings, moduleGate: ModuleGate(modules: [ModuleKey.cycle.wireKey: true]))
        let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
        return CycleStore(repository: repo, gate: gate)
    }

    private static let startOn0914 = CyclePeriodRequest(
        action: .start,
        date: "2026-09-14",
        loggedAt: "2026-10-16T08:00:00Z",
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

    // MARK: - Start: absorbed

    @Test("Acceptance: logging 14 Sep after 17 Sep says the merge, and the calendar is still refetched")
    func mergeSentence() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger, period: Self.periodV143, patch: Self.dayLog(restored: nil))
        let store = try makeStore(session)

        let ok = await store.commitCapture(dayLog: write(), period: Self.startOn0914)

        #expect(ok)
        #expect(store.startNotice == CycleStartNotice(kind: .merged(absorbed: "2026-09-17", into: "2026-09-14")))
        let lines = ledger.requests.map(\.line)
        let periodIndex = try #require(lines.firstIndex(of: "POST /api/cycle/period"))
        #expect(lines[(periodIndex + 1)...].contains("GET /api/cycle/calendar"))
        store.dismissStartNotice()
        #expect(store.startNotice == nil)
    }

    @Test("A v1.42 answer says nothing; a later save clears an earlier notice")
    func olderServerSilent() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger, period: Self.periodV142, patch: Self.dayLog(restored: nil))
        let store = try makeStore(session)
        #expect(await store.setPeriod(Self.startOn0914))
        #expect(store.startNotice == nil)
    }

    // MARK: - Edit: restored

    @Test("Clearing the flow on a start day that gave a start back says so")
    func restoreOnPatch() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(
            session, ledger: ledger, period: Self.periodV142,
            patch: Self.dayLog(restored: #"[{"cycleId":"cyc-0917","startDate":"2026-09-17"}]"#)
        )
        let store = try makeStore(session)
        let ok = await store.commitCapture(
            dayLog: write(), period: nil, existingID: "dl-0914", patch: CycleDayLogPatch(flow: .clear)
        )
        #expect(ok)
        #expect(store.startNotice == CycleStartNotice(kind: .restored(["2026-09-17"])))
    }

    @Test("A PATCH answer without `restored` (v1.42) leaves the notice empty and the row intact")
    func patchOlderServer() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        install(session, ledger: ledger, period: Self.periodV142, patch: Self.dayLog(restored: nil))
        let repo = try makeRepository(session)
        let result = try await repo.updateDayLogReportingStarts(id: "dl-0914", patch: CycleDayLogPatch(flow: .clear))
        #expect(result.dayLog.id == "dl-0914")
        #expect(result.restored.isEmpty)
    }

    // MARK: - Delete: Prefer + 200 or 204

    @Test("The replayed day-log delete asks for the outcome and reads 200 with the restored start")
    func deleteWithRepresentation() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        session.install { request in
            ledger.record(request)
            return Self.respond(request, 200, Self.deleteOutcome)
        }
        let repo = try makeRepository(session)
        try await repo.replayDeleteDayLog(id: "dl-0914", idempotencyKey: "idem-dl-0914")
        #expect(ledger.requests.map(\.prefer) == ["return=representation"])
        let outcome = CycleDeleteOutcome.decode(Data(Self.deleteOutcome.utf8))
        #expect(outcome.removedCycleId == "cyc-0914")
        #expect(outcome.restored == [CycleRestoredStart(cycleId: "cyc-0917", startDate: "2026-09-17")])
        #expect(CycleStartNotice.restored(outcome.restored)?.kind == .restored(["2026-09-17"]))
    }

    @Test("Acceptance: against a v1.42 server the delete still succeeds (204) and nothing is said")
    func deleteOlderServer() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        session.install { request in
            ledger.record(request)
            return Self.respond(request, 204, nil)
        }
        let repo = try makeRepository(session)
        try await repo.replayDeleteDayLog(id: "dl-0914", idempotencyKey: "idem-dl-0914")
        #expect(ledger.requests.map(\.line) == [
            "DELETE /api/cycle/day-logs/dl-0914"
        ])
        #expect(CycleStartNotice.restored([]) == nil)
    }

    // MARK: - Decoding and the sentence

    @Test("Outcome decoding never fails a write: empty body, data null and garbage are \"nothing to say\"")
    func tolerantDecoding() throws {
        #expect(CycleDeleteOutcome.decode(Data()) == .unchanged)
        #expect(CycleDeleteOutcome.decode(Data("<html>".utf8)) == .unchanged)
        #expect(CycleDeleteOutcome.decode(Data(#"{"data":null,"error":null}"#.utf8)) == .unchanged)
        let partial = CycleDeleteOutcome
            .decode(
                Data(#"{"data":{"removedCycleId":null,"restored":[{"cycleId":"c"},{"cycleId":"d","startDate":"2026-09-20"}]},"error":null}"#
                    .utf8)
            )
        #expect(partial.restored == [CycleRestoredStart(cycleId: "d", startDate: "2026-09-20")])
        let decoder = JSONDecoder.hlDefault
        #expect(try decoder.decode(CyclePeriodOutcome.self, from: Data(#"{"data":null,"error":null}"#.utf8)).absorbed == nil)
        let odd = try decoder.decode(CyclePeriodOutcome.self, from: Data(#"{"absorbed":"yes","cycle":{"startDate":"2026-09-14"}}"#.utf8))
        #expect(odd.absorbed == nil)
        #expect(odd.startDate == "2026-09-14")
    }

    @Test("The sentence names both days, read as calendar days in any zone")
    func sentence() {
        let english = Locale(identifier: "en_GB")
        #expect(CycleStartNotice.dayLabel("2026-09-17", locale: english).contains("17"))
        #expect(!CycleStartNotice.dayLabel("2026-09-17", locale: english).contains("16"))
        #expect(CycleStartNotice.dayLabel("not-a-day", locale: english) == "not-a-day")
        let merged = CycleStartNotice(kind: .merged(absorbed: "2026-09-17", into: "2026-09-14"))
        let from = CycleStartNotice.dayLabel("2026-09-17", locale: english)
        let into = CycleStartNotice.dayLabel("2026-09-14", locale: english)
        #expect(merged.sentence(locale: english) == String(localized: "cycle.startNotice.merged \(from) \(into)"))
        let restored = CycleStartNotice.restored([
            CycleRestoredStart(cycleId: "b", startDate: "2026-09-20"),
            CycleRestoredStart(cycleId: "a", startDate: "2026-09-17"),
            CycleRestoredStart(cycleId: "a2", startDate: "2026-09-17")
        ])
        #expect(restored?.kind == .restored(["2026-09-17", "2026-09-20"]))
        #expect(CycleStartNotice.merged(CyclePeriodOutcome(), requestedDate: "2026-09-14") == nil)
        #expect(CycleStartNotice.merged(
            CyclePeriodOutcome(absorbed: CycleRestoredStart(cycleId: "x", startDate: "2026-09-17")),
            requestedDate: "2026-09-14"
        )?.kind == .merged(absorbed: "2026-09-17", into: "2026-09-14"))
    }
}
