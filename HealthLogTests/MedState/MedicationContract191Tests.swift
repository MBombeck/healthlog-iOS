import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable file_length type_body_length

// #191 — the server 1.49.0 medication contract as the server team fixed it,
// every behaviour behind a key of `GET /api/version` `features`, never behind
// a version.

private func testDefaults(_ label: String = #function) throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "test-191-\(label)-\(UUID().uuidString)"))
}

/// Answers by path with canned JSON (decoded like the real client) or a
/// scripted error, and records every request.
private final class ScriptedAPI: APIClientProtocol, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let bodyData: Data?

        var body: [String: Any]? {
            bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let lock = Mutex<[Call]>([])
    private let answers: [String: Result<String, HLError>]

    init(_ answers: [String: Result<String, HLError>]) {
        self.answers = answers
    }

    var calls: [Call] {
        lock.withLock { $0 }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let call = Call(
            method: request.method.rawValue,
            path: request.path,
            query: Dictionary(request.query, uniquingKeysWith: { $1 }),
            bodyData: request.body
        )
        lock.withLock { $0.append(call) }
        let key = answers.keys.first { request.path.hasSuffix($0) } ?? ""
        switch answers[key] {
        case let .success(json): return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        case let .failure(error): throw error
        case nil: throw HLError.unknown("not stubbed: \(request.path)")
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await send(request)
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("not stubbed")
    }
}

// MARK: - Capabilities

@Suite("#191 — capabilities come from /api/version features, never from a version number")
struct MedicationCapabilityGateTests {
    @Test("the keys come from /api/version features; unknown keys are ignored")
    func decodesFeatures() throws {
        let json = """
        {"version":"1.49.0","buildSha":null,"builtAt":null,
         "features":["medication.intake-recorded-push","medication.live-activity-tokens","push.relay","something.new"]}
        """
        let info = try JSONDecoder().decode(ServerVersionInfo.self, from: Data(json.utf8))
        #expect(info.medicationCapabilities == [.intakeRecordedPush, .liveActivityTokensPerActivity])
        let old = try JSONDecoder().decode(ServerVersionInfo.self, from: Data(#"{"version":"1.48.6"}"#.utf8))
        #expect(old.features.isEmpty)
        #expect(old.medicationCapabilities.isEmpty, "a 1.48 server opens nothing, whatever its version")
    }

    @Test("every key is spelled as #191 fixes it")
    func keyNames() {
        #expect(MedicationCapability.allCases.map(\.rawValue).sorted() == [
            "medication.already-taken", "medication.bulk-already-taken", "medication.current-dose-open-slot",
            "medication.dose-state", "medication.intake-recorded-push", "medication.intake-sync-version",
            "medication.live-activity-tokens", "medication.snooze-setting",
            "medication.undo-precondition", "sync.medications-last-updated"
        ])
    }

    @Test("recorded flags open their gate, a later answer without them closes it")
    func recordAndForget() throws {
        let defaults = try testDefaults()
        for capability in MedicationCapability.allCases {
            #expect(!MedicationCapabilities.isOpen(capability, defaults: defaults))
        }
        MedicationCapabilities.record([.undoPrecondition], defaults: defaults)
        #expect(MedicationCapabilities.isOpen(.undoPrecondition, defaults: defaults))
        #expect(!MedicationCapabilities.isOpen(.doseState, defaults: defaults))
        MedicationCapabilities.forget(defaults: defaults)
        #expect(!MedicationCapabilities.isOpen(.undoPrecondition, defaults: defaults))
    }

    @Test("update path: the 1.7 draft's version gate no longer opens the push handling")
    func legacyVersionGateIsRetired() throws {
        let defaults = try testDefaults()
        // A phone that saw "server ≥ 1.48.6" with the pre-contract build.
        defaults.set(true, forKey: MedicationCapabilities.legacyVersionGateKey)
        #expect(!MedicationIntakeRecordedGate.isOpen(defaults: defaults))
        MedicationCapabilities.record([], defaults: defaults)
        #expect(defaults.object(forKey: MedicationCapabilities.legacyVersionGateKey) == nil)
        #expect(!MedicationIntakeRecordedGate.isOpen(defaults: defaults))
    }

    @Test("the list reader takes only medication keys")
    func listReader() {
        let flags = MedicationCapabilities.flags(inFeatures: [
            "medication.bulk-already-taken", "measurement.reading-timezone", "MEDICATION.DOSE-STATE"
        ])
        #expect(flags == [.bulkAlreadyTaken])
    }
}

// MARK: - Live Activity content state (stable)

#if canImport(ActivityKit)
    @Suite("#191 — the server's Live Activity end state decodes exactly")
    struct ServerContentStateFixtureTests {
        private static func fixtureData(file: String = #filePath) throws -> Data {
            let url = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/LiveActivity/server-1.49.0-medication-live-activity-content-state.json")
            return try Data(contentsOf: url)
        }

        @Test("the golden server fixture decodes to the taken end state")
        func goldenServerFixture() throws {
            let state = try JSONDecoder().decode(MedicationActivityAttributes.ContentState.self, from: Self.fixtureData())
            #expect(state.status == .taken)
            #expect(state.countdownTarget.timeIntervalSinceReferenceDate == 805_000_000)
            #expect(!state.confirmed)
            #expect(!state.pendingConfirm)
            #expect(!state.isOverdue)
            #expect(state.timeFormatRaw == "H24")
            #expect(state.pendingConfirmStartedAt == nil)
        }

        @Test("every time format the server sends survives", arguments: ["AUTO", "H12", "H24"])
        func timeFormats(raw: String) throws {
            let json = """
            {"status":"taken","countdownTarget":805000000,"confirmed":false,"pendingConfirm":false,"isOverdue":false,"timeFormatRaw":"\(raw)"}
            """
            let state = try JSONDecoder().decode(MedicationActivityAttributes.ContentState.self, from: Data(json.utf8))
            #expect(state.timeFormatRaw == raw)
            #expect(state.status == .taken)
        }
    }
#endif

// MARK: - MEDICATION_INTAKE_RECORDED (stable)

@Suite("#191 — the MEDICATION_INTAKE_RECORDED payload")
struct IntakeRecordedPayloadTests {
    private static var taken: [AnyHashable: Any] {
        [
            "aps": [
                "alert": ["title": "Dose recorded", "body": "A dose was recorded as taken on another device."],
                "mutable-content": 1,
                "interruption-level": "passive",
                "thread-id": "medication-med-7"
            ],
            "eventType": "MEDICATION_INTAKE_RECORDED",
            "medicationId": "med-7",
            "intakeId": "row-42",
            "slotInstant": "2026-11-21T07:00:00.000Z",
            "outcome": "taken",
            "takenAt": "2026-11-21T07:12:00.000Z",
            "takenVia": "INTEGRATION"
        ]
    }

    @Test("the posted take parses field by field")
    func taken() throws {
        let dose = try #require(MedicationIntakeRecordedPush.parse(userInfo: Self.taken))
        #expect(dose.medicationId == "med-7")
        #expect(dose.intakeId == "row-42")
        #expect(dose.outcome == .taken)
        #expect(dose.wasTaken)
        #expect(dose.source == "INTEGRATION")
        #expect(dose.slotAt == ISO8601DateFormatter().date(from: "2026-11-21T07:00:00Z"))
        #expect(dose.takenAt == ISO8601DateFormatter().date(from: "2026-11-21T07:12:00Z"))
        #expect(MedicationIntakeRecordedPush.threadIdentifier(medicationId: dose.medicationId) == "medication-med-7")
    }

    @Test("a skip has no takenAt and still resolves the slot")
    func skipped() throws {
        var payload = Self.taken
        payload["outcome"] = "skipped"
        payload["takenAt"] = NSNull()
        payload["takenVia"] = NSNull()
        let dose = try #require(MedicationIntakeRecordedPush.parse(userInfo: payload))
        #expect(dose.outcome == .skipped)
        #expect(!dose.wasTaken)
        #expect(dose.takenAt == nil)
        // The withdrawal does not look at the outcome: a skipped slot's
        // reminders go too.
        let reminder = ResolvedReminderPlan.Reminder(identifier: "r", medicationId: "med-7", slotAt: dose.slotAt)
        #expect(ResolvedReminderPlan.identifiersToRemove([reminder], doses: [dose]) == ["r"])
    }

    @Test("an outcome this build does not know is no confirmation")
    func unknownOutcome() {
        var payload = Self.taken
        payload["outcome"] = "edited"
        #expect(MedicationIntakeRecordedPush.parse(userInfo: payload) == nil)
    }

    @Test("a relayed plaintext without aps parses the same")
    func relayedPlaintext() {
        var plaintext = Self.taken
        plaintext.removeValue(forKey: "aps")
        #expect(MedicationIntakeRecordedPush.parse(userInfo: plaintext)?.intakeId == "row-42")
    }

    @Test("update path: a ledger written before the outcome decodes as a take")
    func legacyLedger() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-191-\(UUID().uuidString).json")
        let legacy = #"[{"medicationId":"m","slotAt":"2026-11-21T07:00:00Z","recordedAt":"2026-11-21T07:01:00Z","source":"API"}]"#
        try Data(legacy.utf8).write(to: url)
        let entries = ResolvedDoseLedger(url: url).read()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == nil)
        #expect(entries.first?.wasTaken == true)
    }

    @Test("the final takenVia values have labels; INTEGRATION is the pill box, unknown is another device")
    func takenViaLabels() {
        for via in ["WEB", "APP", "INTEGRATION", "TELEGRAM", "APPLE_HEALTH", "IMPORT", "AUTO"] {
            #expect(MedicationAlreadyTaken.sourceLabel(via) != nil, "\(via)")
        }
        #expect(MedicationTakenVia(wire: "APP") == .app)
        #expect(MedicationTakenVia(wire: "IOS") == .app, "rows written before 1.49.0")
        #expect(MedicationTakenVia(wire: "SOMETHING_NEW") == .other)
        #expect(MedicationTakenVia(wire: nil) == nil)
        #expect(MedicationAlreadyTaken.sourceLabel("INTEGRATION") == String(
            localized: "med.already_taken.source.integration", defaultValue: "pill box or connected device"
        ))
        #expect(MedicationAlreadyTaken.sourceLabel("SOMETHING_NEW") == String(
            localized: "med.already_taken.source.other", defaultValue: "another device"
        ))
    }
}

// MARK: - alreadyTaken (stable on the single routes, changing on bulk)

@Suite("#191 — alreadyTaken")
struct AlreadyTakenContractTests {
    private static let row = """
    "id":"row-1","medicationId":"med-1","scheduledFor":"2026-11-21T07:00:00.000Z",\
    "takenAt":"2026-11-21T07:12:00.000Z","skipped":false,"takenVia":"TELEGRAM","syncVersion":3
    """

    @Test("the flat single-route answer carries the first take")
    func flatAnswer() throws {
        let wire = try JSONDecoder.hlDefault.decode(MedicationIntakeWireDTO.self, from: Data("{\(Self.row),\"alreadyTaken\":true}".utf8))
        let already = try #require(wire.alreadyTakenError)
        #expect(already.source == "TELEGRAM")
        #expect(already.takenAt == ISO8601DateFormatter().date(from: "2026-11-21T07:12:00Z"))
        #expect(wire.toDomain().syncVersion == 3)
    }

    @Test("a normal write is no already-taken")
    func normalWrite() throws {
        let wire = try JSONDecoder.hlDefault.decode(MedicationIntakeWireDTO.self, from: Data("{\(Self.row)}".utf8))
        #expect(wire.alreadyTakenError == nil)
    }

    @Test("POST /api/medications/{id}/intake throws the first take instead of a success")
    func singleRouteThrows() async throws {
        let api = ScriptedAPI(["/intake": .success("{\(Self.row),\"alreadyTaken\":true}")])
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        await #expect(throws: MedicationAlreadyTaken.self) {
            _ = try await repo.logIntake(medicationId: "med-1", scheduledFor: nil, takenAt: .now, skipped: false)
        }
    }

    @Test("the bulk alreadyTaken entry throws the first take; a duplicate is still a replay")
    func bulkEntry() async throws {
        let taken = """
        {"processed":1,"inserted":0,"updated":0,"duplicates":1,"skipped":[],"entries":[{"index":0,"status":"alreadyTaken","id":"b7","intake":{"id":"b7","medicationId":"m2",\
        "scheduledFor":"2026-11-21T06:00:00.000Z","takenAt":"2026-11-21T06:12:00.000Z","takenVia":"INTEGRATION"},\
        "takenAt":"2026-11-21T06:12:00.000Z","takenVia":"INTEGRATION"}]}
        """
        let repo = try MedicationsRepository(api: ScriptedAPI(["/intake/bulk": .success(taken)]), outbox: OutboxQueue(inMemory: true))
        do {
            _ = try await repo.recordFromReminder(medicationId: "m2", scheduledFor: .now, status: .taken)
            Issue.record("expected alreadyTaken")
        } catch let already as MedicationAlreadyTaken {
            #expect(already.source == "INTEGRATION")
            #expect(already.takenAt == ISO8601DateFormatter().date(from: "2026-11-21T06:12:00Z"))
        }
        let duplicate = #"{"processed":1,"inserted":0,"duplicates":1,"entries":[{"index":0,"status":"duplicate","id":"a1"}]}"#
        let replayRepo = try MedicationsRepository(
            api: ScriptedAPI(["/intake/bulk": .success(duplicate)]),
            outbox: OutboxQueue(inMemory: true)
        )
        let id = try await replayRepo.recordFromReminder(medicationId: "m1", scheduledFor: .now, status: .taken)
        #expect(id == "a1", "duplicate keeps its meaning: an idempotent replay")
    }

    @Test("update path: a 1.48 bulk answer under entries with a flat id still works")
    func legacyBulkAnswer() async throws {
        let legacy = #"{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"row-3"}]}"#
        let repo = try MedicationsRepository(api: ScriptedAPI(["/intake/bulk": .success(legacy)]), outbox: OutboxQueue(inMemory: true))
        let id = try await repo.recordFromReminder(medicationId: "m1", scheduledFor: .now, status: .taken)
        #expect(id == "row-3")
    }

    @Test("the bulk entry goes out under the key the caller holds")
    func bulkKeyIsTheCallers() async throws {
        let api =
            ScriptedAPI(
                ["/intake/bulk": .success(#"{"processed":1,"inserted":1,"entries":[{"index":0,"status":"inserted","id":"row-9"}]}"#)]
            )
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let key = IdempotencyKey()
        let id = try await repo.recordFromReminder(medicationId: "med-1", scheduledFor: .now, status: .taken, idempotencyKey: key)
        #expect(id == "row-9")
        let entries = api.calls.first?.body?["entries"] as? [[String: Any]]
        #expect(entries?.first?["idempotencyKey"] as? String == key.raw)
    }

    @MainActor
    @Test("with the bulk capability the re-read before a take is skipped")
    func bulkCapabilitySkipsReread() throws {
        let store = try MedicationsStore(
            repo: MedicationsRepository(api: ScriptedAPI([:]), outbox: OutboxQueue(inMemory: true)),
            swr: nil
        )
        let defaults = try testDefaults()
        store.contract.capabilityDefaults = defaults
        #expect(!store.bulkAnswersAlreadyTaken)
        MedicationCapabilities.record([.bulkAlreadyTaken], defaults: defaults)
        #expect(store.bulkAnswersAlreadyTaken)
    }
}

// MARK: - takenVia, per-slot snooze, dose state on today rows

@Suite("#191 — today rows: takenVia, per-slot snooze, resolved dose state")
struct TodayRowContractTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("takenVia, syncVersion and idempotencyKey decode; a 1.48 row is unchanged")
    func decodesNewFields() throws {
        let row = """
        [{"id":"a","medicationId":"m","scheduledAt":"2026-11-21T07:00:00.000Z","takenAt":"2026-11-21T07:12:00.000Z",\
        "status":"taken","snoozedUntil":null,"takenVia":"INTEGRATION","syncVersion":4,"idempotencyKey":"k-1"},
         {"id":"b","medicationId":"m","scheduledAt":"2026-11-21T19:00:00.000Z","takenAt":null,"status":"pending","snoozedUntil":null}]
        """
        let rows = try JSONDecoder.hlDefault.decode([MedicationIntake].self, from: Data(row.utf8))
        #expect(rows[0].takenVia == "INTEGRATION")
        #expect(rows[0].syncVersion == 4)
        #expect(rows[0].idempotencyKey == "k-1")
        #expect(rows[0].doseState == nil)
        #expect(rows[1].takenVia == nil)
        #expect(rows[1].status == .pending)
    }

    @Test("update path: a row cached by the previous build decodes and round-trips")
    func cachedRowRoundTrip() throws {
        let cached = #"{"id":"a","medicationId":"m","scheduledAt":"2026-11-21T07:00:00Z","status":"taken","takenAt":"2026-11-21T07:01:00Z"}"#
        let row = try JSONDecoder.hlDefault.decode(MedicationIntake.self, from: Data(cached.utf8))
        #expect(row.status == .taken)
        let withState = MedicationIntake(
            id: "b", medicationId: "m", scheduledAt: slot, status: .pending, takenVia: nil,
            doseState: ServerDoseState(state: "overdue", dueAt: slot, overdueSince: slot, slotInstant: slot)
        )
        let again = try JSONDecoder.hlDefault.decode(MedicationIntake.self, from: JSONEncoder.hlDefault.encode(withState))
        #expect(again == withState)
    }

    @Test("a today row names who took the dose; the phone's own take stays quiet")
    func takenNote() {
        let elsewhere = MedicationIntake(
            id: "a",
            medicationId: "m",
            scheduledAt: slot,
            takenAt: slot,
            status: .taken,
            takenVia: "INTEGRATION"
        )
        let note = MedicationTakenNote.text(for: elsewhere)
        #expect(note?.contains(MedicationAlreadyTaken.sourceLabel("INTEGRATION") ?? "-") == true)
        #expect(note?.contains(slot.formatted(date: .omitted, time: .shortened)) == true)
        let own = MedicationIntake(id: "b", medicationId: "m", scheduledAt: slot, takenAt: slot, status: .taken, takenVia: "APP")
        #expect(MedicationTakenNote.text(for: own) == nil)
        let open = MedicationIntake(id: "c", medicationId: "m", scheduledAt: slot, status: .pending, takenVia: "WEB")
        #expect(MedicationTakenNote.text(for: open) == nil)
    }

    @Test("a snooze holds its own slot only")
    func snoozeIsPerSlot() {
        let now = slot.addingTimeInterval(60)
        let snoozed = MedicationIntake(
            id: "a", medicationId: "m", scheduledAt: slot, status: .pending, snoozedUntil: now.addingTimeInterval(1800)
        )
        let sibling = MedicationIntake(id: "b", medicationId: "m", scheduledAt: slot.addingTimeInterval(-600), status: .pending)
        #expect(MedicationsStore.computeDueOrMissedCount(intakes: [snoozed, sibling], now: now) == 1)
    }

    @Test("the dose state reads from state; status keeps its own meaning")
    func flatDoseState() throws {
        let json = """
        [{"id":"a","medicationId":"m","scheduledAt":"2026-11-21T07:00:00.000Z","takenAt":null,"status":"pending",\
        "state":"overdue","dueAt":"2026-11-21T07:00:00.000Z","overdueSince":"2026-11-21T08:00:00.000Z",\
        "slotInstant":"2026-11-21T07:00:00.000Z"},
         {"id":"b","medicationId":"m","scheduledAt":"2026-11-21T19:00:00.000Z","takenAt":"2026-11-21T19:40:00.000Z",\
        "status":"taken","state":"taken","takenLate":true,"overdueSince":null,"takenVia":"APP"}]
        """
        let rows = try JSONDecoder.hlDefault.decode([MedicationIntake].self, from: Data(json.utf8))
        #expect(rows[0].status == .pending)
        let state = try #require(rows[0].doseState)
        #expect(state.state == "overdue")
        #expect(state.isOverdue)
        #expect(state.overdueSince != nil)
        #expect(rows[1].doseState?.takenLate == true)
        #expect(rows[1].doseState?.overdueSince == nil)
        #expect(rows[1].doseState?.isOverdue == false)
    }

    @Test("the server's verdict is read only behind the capability, never from the clock")
    func verdictBehindCapability() {
        let row = MedicationIntake(
            id: "a", medicationId: "m", scheduledAt: slot, status: .pending,
            doseState: ServerDoseState(state: "overdue", dueAt: slot, overdueSince: slot, slotInstant: slot)
        )
        let due = MedicationIntake(
            id: "c", medicationId: "n", scheduledAt: slot, status: .pending,
            doseState: ServerDoseState(state: "due", dueAt: slot, slotInstant: slot)
        )
        let later = slot.addingTimeInterval(7200)
        let resolver = MedicationServerResolvedSlots.self
        #expect(resolver.serverOverdue(medicationId: "m", slot: slot, intakes: [row], now: later, enabled: false) == nil)
        #expect(resolver.serverOverdue(medicationId: "m", slot: slot, intakes: [row], now: later, enabled: true) == true)
        #expect(resolver.serverOverdue(medicationId: "n", slot: slot, intakes: [due], now: later, enabled: true) == false)
        let plain = MedicationIntake(id: "b", medicationId: "m", scheduledAt: slot, status: .pending)
        #expect(resolver.serverOverdue(medicationId: "m", slot: slot, intakes: [plain], now: later, enabled: true) == nil)
    }

    @Test("today's sheet grades overdue from the row's dose state when the capability is open")
    func sheetUsesServerVerdict() {
        let medication = Medication(id: "m", name: "Substanz A", dose: "5 mg", schedule: MedicationSchedule(times: []))
        let now = slot.addingTimeInterval(120)
        let row = MedicationIntake(
            id: "a", medicationId: "m", scheduledAt: slot, status: .pending,
            doseState: ServerDoseState(state: "overdue", overdueSince: slot, slotInstant: slot)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let open = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [row], medications: [medication], now: now, calendar: calendar, serverDoseState: true
        )
        #expect(open.rows.first?.isOverdue == true)
        let shut = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [row], medications: [medication], now: now, calendar: calendar, serverDoseState: false
        )
        #expect(shut.rows.first?.isOverdue == false, "without the capability the medication flag decides")
    }
}

// MARK: - Undo precondition (stable)

@Suite("#191 — undo sends the version the person saw")
struct UndoPreconditionTests {
    @Test("nothing known is no precondition; version and key both go out")
    func precondition() throws {
        #expect(IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: nil) == nil)
        #expect(IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: "") == nil)
        let defaults = try testDefaults()
        let both = try #require(IntakeUndoPrecondition(syncVersion: 7, idempotencyKey: "k"))
        #expect(both.queryItems(capabilities: defaults).isEmpty, "shut: the request is unchanged")
        MedicationCapabilities.record([.undoPrecondition], defaults: defaults)
        #expect(both.queryItems(capabilities: defaults).map { "\($0.0)=\($0.1)" } == ["expectedSyncVersion=7", "expectedIdempotencyKey=k"])
        let key = try #require(IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: "k-1"))
        #expect(key.queryItems(capabilities: defaults).map { "\($0.0)=\($0.1)" } == ["expectedIdempotencyKey=k-1"])
    }

    @Test("the DELETE carries the precondition once the capability is open")
    func deleteCarriesIt() async throws {
        let api = ScriptedAPI(["/intake/row-1": .success(#"{"deleted":true}"#)])
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let suite = "test-191-delete-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        await repo.useCapabilitySuite(suite)
        let expected = IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: "k-1")
        try await repo.deleteIntake(medicationId: "med-1", eventId: "row-1", expected: expected)
        MedicationCapabilities.record([.undoPrecondition], defaults: defaults)
        try await repo.deleteIntake(medicationId: "med-1", eventId: "row-1", expected: expected)
        #expect(api.calls.map(\.query) == [[:], ["expectedIdempotencyKey": "k-1"]])
        #expect(api.calls.allSatisfy { $0.method == "DELETE" })
    }

    @Test("update path: a delete queued by the previous build replays without a precondition")
    func legacyOutboxPayload() throws {
        let legacy = #"{"medicationId":"m","eventId":"e"}"#
        let payload = try JSONDecoder().decode(OutboxQueue.Payloads.DeleteIntake.self, from: Data(legacy.utf8))
        #expect(payload.expected == nil)
        let modern = OutboxQueue.Payloads.DeleteIntake(medicationId: "m", eventId: "e", expectedSyncVersion: 2)
        let again = try JSONDecoder().decode(OutboxQueue.Payloads.DeleteIntake.self, from: JSONEncoder().encode(modern))
        #expect(again.expected?.syncVersion == 2)
    }

    @MainActor
    @Test("409 changedSinceSeen says in plain words that nothing was undone, and queues nothing")
    func changedSinceSeen() async throws {
        let conflict = HLError.server(status: 409, code: IntakeUndoPrecondition.changedSinceSeenCode, message: "changed")
        let store = try MedicationsStore(
            repo: MedicationsRepository(api: ScriptedAPI(["/intake/row-1": .failure(conflict)]), outbox: OutboxQueue(inMemory: true)),
            swr: nil
        )
        let outcome = await store.deleteIntake(
            medicationId: "med-1",
            eventId: "row-1",
            expected: IntakeUndoPrecondition(syncVersion: 3, idempotencyKey: nil)
        )
        guard case let .failed(error) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(IntakeUndoPrecondition.isChangedSinceSeen(error))
        #expect(store.error?.userFacingDescription.isEmpty == false)
        #expect(!IntakeUndoPrecondition.isChangedSinceSeen(HLError.server(status: 409, code: "other", message: "")))
    }
}

// MARK: - Freshness (stable)

@MainActor
@Suite("#191 — medications.lastUpdatedAt decides a reload", .serialized)
struct MedicationFreshnessTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var stamp: MedicationFreshnessStamp {
        MedicationFreshnessStamp(medicationsUpdatedAt: date, intakesUpdatedAt: date, intakesLive: 3, intakesTombstoned: 1)
    }

    private func later(_ seconds: TimeInterval) -> MedicationFreshnessStamp {
        MedicationFreshnessStamp(
            medicationsUpdatedAt: date.addingTimeInterval(seconds),
            intakesUpdatedAt: date,
            intakesLive: 3,
            intakesTombstoned: 1
        )
    }

    @Test("no stamp never reloads; a new stamp does")
    func decision() {
        #expect(!MedicationsStore.freshnessNeedsReload(serverStamp: nil, loadedStamp: nil))
        #expect(MedicationsStore.freshnessNeedsReload(serverStamp: stamp, loadedStamp: nil))
        #expect(!MedicationsStore.freshnessNeedsReload(serverStamp: stamp, loadedStamp: stamp))
        #expect(MedicationsStore.freshnessNeedsReload(serverStamp: later(1), loadedStamp: stamp))
    }

    @Test("a dose change moves only the intakes block, and that alone reloads")
    func intakesBlockReloads() {
        let doseChanged = MedicationFreshnessStamp(
            medicationsUpdatedAt: date,
            intakesUpdatedAt: date.addingTimeInterval(5),
            intakesLive: 3,
            intakesTombstoned: 1
        )
        let undone = MedicationFreshnessStamp(medicationsUpdatedAt: date, intakesUpdatedAt: date, intakesLive: 2, intakesTombstoned: 2)
        #expect(MedicationsStore.freshnessNeedsReload(serverStamp: doseChanged, loadedStamp: stamp))
        #expect(MedicationsStore.freshnessNeedsReload(serverStamp: undone, loadedStamp: stamp), "a tombstone with the same stamp")
    }

    @Test("the handshake's intakes block becomes the stamp; neither block is no stamp")
    func stampFromHandshake() throws {
        let base = #""userId":"u","timezone":"Europe/Berlin","lastSyncedAt":null,"serverNow":"2026-11-21T07:00:00Z","measurements":{"lastUpdatedAt":null,"liveCount":1,"tombstonedCount":0}"#
        let full = try JSONDecoder.hlDefault.decode(
            ServerSyncStateDTO.self,
            from: Data(
                "{\(base),\"medications\":{\"lastUpdatedAt\":\"2026-11-21T07:12:00.000Z\"},\"intakes\":{\"lastUpdatedAt\":\"2026-11-21T07:13:00.000Z\",\"liveCount\":9,\"tombstonedCount\":2}}"
                    .utf8
            )
        )
        let made = try #require(MedicationFreshnessStamp(state: full))
        #expect(made.intakesUpdatedAt == ISO8601DateFormatter().date(from: "2026-11-21T07:13:00Z"))
        #expect(made.intakesLive == 9)
        #expect(made.intakesTombstoned == 2)
        let old = try JSONDecoder.hlDefault.decode(ServerSyncStateDTO.self, from: Data("{\(base)}".utf8))
        #expect(MedicationFreshnessStamp(state: old) == nil)
    }

    @Test("the handshake decodes the stamp; a 1.48 server and a mistyped stamp decode too")
    func handshakeDecodes() throws {
        let base = #""userId":"u","timezone":"Europe/Berlin","lastSyncedAt":null,"serverNow":"2026-11-21T07:00:00Z","measurements":{"lastUpdatedAt":null,"liveCount":1,"tombstonedCount":0}"#
        let modern = try JSONDecoder.hlDefault.decode(
            ServerSyncStateDTO.self,
            from: Data("{\(base),\"medications\":{\"lastUpdatedAt\":\"2026-11-21T07:12:00.000Z\"}}".utf8)
        )
        #expect(modern.medications?.lastUpdatedAt == ISO8601DateFormatter().date(from: "2026-11-21T07:12:00Z"))
        let old = try JSONDecoder.hlDefault.decode(ServerSyncStateDTO.self, from: Data("{\(base)}".utf8))
        #expect(old.medications == nil)
        let odd = try JSONDecoder.hlDefault.decode(
            ServerSyncStateDTO.self,
            from: Data("{\(base),\"medications\":{\"lastUpdatedAt\":42}}".utf8)
        )
        #expect(odd.medications?.lastUpdatedAt == nil)
    }

    @Test("an unchanged stamp costs no reload, a changed one reloads once")
    func reconcile() async throws {
        let api = ScriptedAPI([
            "/api/medications/intake": .success("[]"),
            "/api/medications": .success("[]")
        ])
        let store = try MedicationsStore(repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true)), swr: nil)
        await store.reconcileFreshness(serverStamp: nil)
        #expect(api.calls.isEmpty, "an older server: nothing happens")
        await store.reconcileFreshness(serverStamp: stamp)
        let afterFirst = api.calls.count
        #expect(afterFirst > 0)
        await store.reconcileFreshness(serverStamp: stamp)
        #expect(api.calls.count == afterFirst, "the data already carries this stamp")
        #expect(store.contract.loadedStamp == stamp)
        await store.reconcileFreshness(serverStamp: later(60))
        #expect(api.calls.count > afterFirst)
    }
}

// MARK: - Live Activity tokens per Activity (changing)

@Suite("#191 — one Live Activity token per Activity on POST /api/devices")
struct LiveActivityTokensPerActivityTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the list carries token, medication and slot, earliest slot first")
    func wireEntries() throws {
        var registry = LiveActivityTokenRegistry()
        registry.upsert("tok-b", owner: LiveActivityTokenOwner(activityID: "b", medicationId: "med-2", slot: slot.addingTimeInterval(3600)))
        registry.upsert("tok-a", owner: LiveActivityTokenOwner(activityID: "a", medicationId: "med-1", slot: slot))
        let entries = LiveActivityPerActivityTokens.wireEntries(registry)
        #expect(entries.map(\.token) == ["tok-a", "tok-b"])
        #expect(entries.map(\.medicationId) == ["med-1", "med-2"])

        let body = DeviceRegistration(
            token: "device-1", bundleId: "b", locale: "de-DE", appVersion: "1.7", model: "iPhone",
            apnsToken: "aa", apnsEnvironment: .sandbox, liveActivityPushToken: "tok-a", liveActivityTokens: entries
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(body)) as? [String: Any]
        let list = try #require(object?["liveActivityTokens"] as? [[String: Any]])
        #expect(list.first?["medicationId"] as? String == "med-1")
        #expect(list.first?["slotInstant"] != nil)
        #expect(object?["liveActivityPushToken"] as? String == "tok-a", "the single field keeps going out")
    }

    @Test("without the list the body is byte-identical to the previous build's")
    func omittedWhenShut() throws {
        let body = DeviceRegistration(
            token: "device-1", bundleId: "b", locale: "de-DE", appVersion: "1.7", model: "iPhone",
            apnsToken: "aa", apnsEnvironment: .sandbox, liveActivityPushToken: "tok-a"
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(body)) as? [String: Any]
        #expect(object?["liveActivityTokens"] == nil)
        let cleared = DeviceRegistration(
            token: "device-1", bundleId: "b", locale: "de-DE", appVersion: "1.7", model: "iPhone",
            apnsToken: "aa", apnsEnvironment: .sandbox, liveActivityTokens: []
        )
        let clearedObject = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(cleared)) as? [String: Any]
        #expect((clearedObject?["liveActivityTokens"] as? [Any])?.isEmpty == true, "an empty list clears the server's")
    }

    #if canImport(UserNotifications) && canImport(UIKit)
        @MainActor
        @Test("update path: an unchanged registration keeps its fingerprint, the list changes it")
        func fingerprint() {
            let plain = NotificationService.RegistrationState(tokenHex: "aa", env: .sandbox, liveActivityPushToken: "tok-a")
            var withList = plain
            withList.liveActivityTokens = [LiveActivityTokenWire(token: "tok-a", medicationId: "med-1", slotInstant: slot)]
            let old = NotificationService.fingerprint(plain, owner: "u")
            #expect(old == NotificationService.fingerprint(plain, owner: "u"))
            #expect(old != NotificationService.fingerprint(withList, owner: "u"))
            var cleared = plain
            cleared.liveActivityTokens = []
            #expect(old != NotificationService.fingerprint(cleared, owner: "u"), "clearing the list must reach the server")
        }
    #endif
}

// MARK: - Snooze setting (changing)

@Suite("#191 — the snooze span follows the account's setting")
struct SnoozeSettingTests {
    @Test("shut: the server default 30 min; open: the setting, its default 30 min, out of 5...240 the default")
    func span() throws {
        let defaults = try testDefaults()
        MedicationSnooze.record(serverMinutes: 20, defaults: defaults)
        #expect(MedicationSnooze.interval(defaults: defaults) == 30 * 60, "the fixed 15 minutes are gone")
        MedicationCapabilities.record([.snoozeSetting], defaults: defaults)
        #expect(MedicationSnooze.interval(defaults: defaults) == 20 * 60)
        MedicationSnooze.record(serverMinutes: nil, defaults: defaults)
        #expect(MedicationSnooze.interval(defaults: defaults) == 30 * 60)
        MedicationSnooze.record(serverMinutes: 0, defaults: defaults)
        #expect(MedicationSnooze.interval(defaults: defaults) == 30 * 60)
        MedicationSnooze.record(serverMinutes: 4, defaults: defaults)
        #expect(MedicationSnooze.minutes(defaults: defaults) == 30)
        MedicationSnooze.record(serverMinutes: 241, defaults: defaults)
        #expect(MedicationSnooze.minutes(defaults: defaults) == 30)
        MedicationSnooze.record(serverMinutes: 240, defaults: defaults)
        #expect(MedicationSnooze.minutes(defaults: defaults) == 240)
        #expect(MedicationSnooze.choices.allSatisfy(MedicationSnooze.allowedMinutes.contains))
        #expect(MedicationSnooze.clamped(1) == 5)
        #expect(MedicationSnooze.clamped(999) == 240)
    }

    @Test("/api/auth/me carries the setting under notificationPrefs.medication")
    func decodesSetting() throws {
        let me = try JSONDecoder.hlDefault.decode(
            AuthMeModules.self,
            from: Data(#"{"modules":{},"notificationPrefs":{"medication":{"clientManaged":true,"snoozeMinutes":45}}}"#.utf8)
        )
        #expect(me.medicationSnoozeMinutes == 45)
        let old = try JSONDecoder.hlDefault.decode(AuthMeModules.self, from: Data(#"{"modules":{}}"#.utf8))
        #expect(old.medicationSnoozeMinutes == nil)
        let prefs = try JSONDecoder.hlDefault.decode(
            AuthNotificationPrefsPayload.Medication.self,
            from: Data(#"{"lowStockRunwayDays":7,"clientManaged":true,"snoozeMinutes":30}"#.utf8)
        )
        #expect(prefs.snoozeMinutes == 30)
    }
}
