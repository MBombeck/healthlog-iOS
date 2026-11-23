import Foundation
@testable import HealthLog
import Testing

// Reminder settings in words and the reminder phases for every scheduled
// medication (server 1.49.0, UX point 6; `phase-config` route).

// MARK: - Wire DTO

@Suite("Phase config — the wire shape of /api/medications/{id}/phase-config")
struct MedicationPhaseConfigWireTests {
    private func decode(_ json: String) throws -> MedicationPhaseConfig {
        try JSONDecoder.hlDefault.decode(MedicationPhaseConfig.self, from: Data(json.utf8))
    }

    @Test("a stored row decodes; id, medicationId and timestamps are ignored")
    func decodesStoredRow() throws {
        let config = try decode("""
        {"id":"pc1","medicationId":"m1","greenValue":45,"greenMode":"MINUTES",
         "yellowValue":20,"yellowMode":"PERCENT","orangeValue":10,"orangeMode":"MINUTES",
         "redValue":300,"redMode":"MINUTES","createdAt":"2026-11-01T08:00:00.000Z",
         "updatedAt":"2026-11-02T08:00:00.000Z"}
        """)
        #expect(config.due == .init(value: 45, mode: .minutes))
        #expect(config.stillDue == .init(value: 20, mode: .percent))
        #expect(config.overdue == .init(value: 10, mode: .minutes))
        #expect(config.missed == .init(value: 300, mode: .minutes))
    }

    @Test("the server's defaults answer (no row stored) equals the app's defaults")
    func decodesServerDefaults() throws {
        let config = try decode("""
        {"greenValue":60,"greenMode":"MINUTES","yellowValue":30,"yellowMode":"MINUTES",
         "orangeValue":0,"orangeMode":"MINUTES","redValue":240,"redMode":"MINUTES"}
        """)
        #expect(config == .defaults)
    }

    @Test("update path: an older or partial answer without the phase fields reads as the defaults")
    func olderAnswerFallsBackToDefaults() throws {
        #expect(try decode("{}") == .defaults)
        #expect(try decode(#"{"reset":true}"#) == .defaults)
        let partial = try decode(#"{"redValue":120,"greenMode":"HOURS","yellowValue":"x"}"#)
        #expect(partial.missed.value == 120)
        #expect(partial.due.mode == .minutes)
        #expect(partial.stillDue.value == 30)
    }

    @Test("the PUT body carries exactly the eight schema fields")
    func encodesSchemaFields() throws {
        var config = MedicationPhaseConfig.defaults
        config[.missed] = .init(value: 50, mode: .percent)
        let data = try JSONEncoder.hlDefault.encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "greenValue", "greenMode", "yellowValue", "yellowMode",
            "orangeValue", "orangeMode", "redValue", "redMode"
        ])
        #expect(object["redValue"] as? Int == 50)
        #expect(object["redMode"] as? String == "PERCENT")
        #expect(object["greenValue"] as? Int == 60)
        #expect(try JSONDecoder.hlDefault.decode(MedicationPhaseConfig.self, from: data) == config)
    }

    @Test("values outside 0 to 1440 are caught before the save")
    func boundsBeforeSave() {
        var config = MedicationPhaseConfig.defaults
        #expect(config.phasesOutOfRange.isEmpty)
        config[.overdue].value = 1441
        config[.due].value = -1
        #expect(config.phasesOutOfRange == [.due, .overdue])
    }
}

// MARK: - 422 bounds

@Suite("Phase config — a 422 names the allowed range from details.issues[]")
struct MedicationPhaseConfigRefusalTests {
    private func body(_ issues: String) -> Data {
        Data(#"{"data":null,"error":"Validation failed","details":{"issues":\#(issues)}}"#.utf8)
    }

    @Test("too_big on redValue: the maximum is the server's, the minimum the schema's")
    func parsesMaximum() throws {
        let data = body(#"[{"path":"redValue","code":"too_big","message":"Too big","maximum":1440,"inclusive":true,"origin":"number"}]"#)
        let refusal = try #require(MedicationPhaseConfigRefusal.from(
            path: "/api/medications/m1/phase-config",
            status: 422,
            body: data
        ))
        #expect(refusal.phases == [.missed])
        #expect(refusal.allowedRange(for: .missed) == 0 ... 1440)
        #expect(refusal.message.contains("1440"))
        #expect(refusal.message.contains(MedicationReminderPhase.missed.title))
    }

    @Test("too_small with a minimum, a path as segments, and an issue without bounds")
    func parsesMinimumAndSegments() {
        let issues = MedicationPhaseConfigRefusal.parseIssues(body(
            #"[{"path":["greenValue"],"code":"too_small","minimum":5},{"path":"yellowMode","code":"invalid_value"}]"#
        ))
        let refusal = MedicationPhaseConfigRefusal(issues: issues)
        #expect(refusal.phases == [.due, .stillDue])
        #expect(refusal.allowedRange(for: .due) == 5 ... 1440)
        #expect(refusal.allowedRange(for: .stillDue) == 0 ... 1440)
    }

    @Test("no issue names a phase: one line for all values")
    func messageWithoutPhase() {
        let refusal = MedicationPhaseConfigRefusal(issues: [])
        #expect(refusal.phases.isEmpty)
        #expect(refusal.message.contains("0"))
        #expect(refusal.message.contains("1440"))
    }

    @Test("other routes, other statuses and an unreadable body")
    func onlyThisRoute() {
        let data = body(#"[{"path":"redValue","maximum":1440}]"#)
        #expect(MedicationPhaseConfigRefusal.from(path: "/api/medications/m1", status: 422, body: data) == nil)
        #expect(MedicationPhaseConfigRefusal.from(path: "/api/medications/m1/phase-config", status: 400, body: data) == nil)
        #expect(MedicationPhaseConfigRefusal.parseIssues(Data("not json".utf8)).isEmpty)
    }

    @Test("the repository turns a bare 422 into a refusal with the schema's range")
    func repositoryMapsBare422() async throws {
        let api = PhaseConfigStubAPI(error: HLError.server(status: 422, code: nil, message: "Validation failed"))
        let repository = MedicationPhaseConfigRepository(api: api)
        await #expect(throws: MedicationPhaseConfigRefusal(issues: [])) {
            _ = try await repository.savePhaseConfig(.defaults, medicationID: "m1")
        }
        let sent = try #require(api.lastRequest)
        #expect(sent.method == .put)
        #expect(sent.path == "/api/medications/m1/phase-config")
        #expect(!sent.idempotencyKey.raw.isEmpty)
    }
}

/// Answers every request with one config, or throws one error; keeps the last
/// request.
private final class PhaseConfigStubAPI: APIClientProtocol, @unchecked Sendable {
    struct Sent {
        let method: HTTPMethod
        let path: String
        let idempotencyKey: IdempotencyKey
    }

    let error: Error?
    let answer: MedicationPhaseConfig
    private(set) var lastRequest: Sent?

    init(error: Error? = nil, answer: MedicationPhaseConfig = .defaults) {
        self.error = error
        self.answer = answer
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        lastRequest = Sent(method: request.method, path: request.path, idempotencyKey: request.idempotencyKey)
        if let error { throw error }
        guard let typed = answer as? T else { throw HLError.decoding("unexpected \(T.self)") }
        return typed
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.canceled
    }
}

// MARK: - Words

@Suite("Reminder settings in words")
struct MedicationReminderWordsTests {
    private let german = Locale(identifier: "de_DE")

    private func medication(
        _ entries: [ScheduleEntry],
        notificationsEnabled: Bool = true,
        asNeeded: Bool = false
    ) -> Medication {
        Medication(
            id: "m1",
            name: "Substanz A",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: entries),
            notificationsEnabled: notificationsEnabled,
            asNeeded: asNeeded
        )
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
        TimeOfDay(hour: hour, minute: minute)
    }

    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    /// 2026-11-21 in Berlin at `hour`.
    private func instant(_ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: hour, minute: minute)) ?? .distantPast
    }

    private func current(_ hour: Int) -> ComplianceCurrentDose {
        ComplianceCurrentDose(
            status: "due",
            targetAt: instant(hour),
            state: "due",
            dueAt: instant(hour - 1),
            overdueSince: instant(hour + 1),
            missedAfter: instant(hour + 5)
        )
    }

    @Test("the current dose's instants come from the server, nothing is computed")
    func currentDoseFromServer() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(8)], windowStart: at(8))
        let summary = try #require(MedicationReminderWords.summary(for: medication([entry]), currentDose: current(8)))
        #expect(summary.offersPhaseConfig)
        let text = MedicationReminderWords.text(summary, locale: german, timeZone: berlin)
        for clock in ["08:00", "07:00", "09:00", "13:00"] {
            #expect(text.contains(clock), "\(clock)")
        }
    }

    @Test("the times follow the hour cycle of the account, never a fixed HH:mm")
    func twelveHourClock() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(20)], windowStart: at(20))
        let summary = try #require(MedicationReminderWords.summary(for: medication([entry]), currentDose: current(20)))
        let twelve = HLTimeFormat.twelveHour.formattingLocale
        let text = MedicationReminderWords.text(summary, locale: twelve, timeZone: berlin)
        #expect(text.contains(HLTimeFormat.clock(minutesAfterMidnight: 20 * 60, locale: twelve)))
        #expect(!text.contains("20:00"))
    }

    @Test("several times a day: all times named")
    func multipleTimes() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(20), at(8)], windowStart: at(8))
        let summary = try #require(MedicationReminderWords.summary(for: medication([entry]), currentDose: nil))
        #expect(summary == .schedule(times: [480, 1200], current: nil))
        let text = MedicationReminderWords.text(summary, locale: german)
        #expect(text.contains("08:00"))
        #expect(text.contains("20:00"))
    }

    @Test("no current dose (targetAt null) or a block without instants: only the times")
    func withoutCurrentDose() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(8)], windowStart: at(8))
        let none = ComplianceCurrentDose(status: "upcoming", targetAt: nil)
        let summary = try #require(MedicationReminderWords.summary(for: medication([entry]), currentDose: none))
        #expect(summary == .schedule(times: [480], current: nil))
        let bare = ComplianceCurrentDose(targetAt: instant(8))
        let partial = try #require(MedicationReminderWords.summary(for: medication([entry]), currentDose: bare))
        #expect(!MedicationReminderWords.text(partial, locale: german, timeZone: berlin).contains("07:00"))
    }

    @Test("update path: complianceDisplay without currentDose, and a mistyped one, still decode")
    func decodesCurrentDose() throws {
        let base = #""shortDays":7,"longDays":30,"short":{"rate":90},"long":{"rate":80}"#
        let old = try JSONDecoder.hlDefault.decode(ComplianceDisplay.self, from: Data("{\(base)}".utf8))
        #expect(old.currentDose == nil)
        let dose = """
        "currentDose":{"status":"due","targetAt":"2026-11-21T07:00:00.000Z","state":"overdue","takenLate":false,\
        "dueAt":"2026-11-21T06:00:00.000Z","overdueSince":"2026-11-21T08:00:00.000Z",\
        "missedAfter":"2026-11-21T12:00:00.000Z","lateTakeCounts":true}
        """
        let modern = try JSONDecoder.hlDefault.decode(ComplianceDisplay.self, from: Data("{\(base),\(dose)}".utf8))
        #expect(modern.currentDose?.state == "overdue")
        #expect(modern.currentDose?.lateTakeCounts == true)
        #expect(modern.currentDose?.missedAfter == ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let odd = try JSONDecoder.hlDefault.decode(ComplianceDisplay.self, from: Data("{\(base),\"currentDose\":{\"targetAt\":42}}".utf8))
        #expect(odd.currentDose?.targetAt == nil)
    }

    @Test("doses recorded automatically: no reminders, no phases")
    func autoRecorded() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(8)], windowStart: at(8))
        var med = medication([entry])
        med.autoMarkTaken = true
        med.remindersActive = false
        let summary = try #require(MedicationReminderWords.summary(for: med, currentDose: nil))
        #expect(summary == .autoRecorded)
        #expect(!summary.offersPhaseConfig)
        #expect(MedicationReminderWords.text(summary) == String(
            localized: "med.reminders.autoRecorded",
            defaultValue: "Doses are recorded automatically, so no reminders are sent."
        ))
    }

    @Test("reminders switched off still offer the phases (they decide when a dose is missed)")
    func remindersOff() throws {
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: [at(8)], windowStart: at(8))
        let summary = try #require(MedicationReminderWords.summary(
            for: medication([entry], notificationsEnabled: false),
            currentDose: nil
        ))
        #expect(summary == .remindersOff)
        #expect(summary.offersPhaseConfig)
    }

    @Test("as needed: the section shows nothing")
    func asNeeded() {
        #expect(MedicationReminderWords.summary(for: medication([], asNeeded: true), currentDose: nil) == nil)
        let prn = ScheduleEntry(cadence: .asNeeded, timesOfDay: [], windowStart: at(8))
        #expect(MedicationReminderWords.summary(for: medication([prn]), currentDose: nil) == nil)
    }

    @Test("update path: a cached medication without schedule rows shows nothing")
    func legacyEmptySchedule() {
        let cached = Medication(id: "m1", name: "Substanz A", dose: "5 mg", schedule: MedicationSchedule(times: []))
        #expect(MedicationReminderWords.summary(for: cached, currentDose: nil) == nil)
    }
}

// MARK: - Model

@MainActor
@Suite("Phase config model — draft, reset and save")
struct MedicationPhaseConfigModelTests {
    @Test("reset fills the defaults without saving; a blank field blocks the save")
    func resetAndBlank() async {
        var stored = MedicationPhaseConfig.defaults
        stored[.missed].value = 600
        let model = MedicationPhaseConfigModel(
            medicationID: "m1",
            repository: StubPhaseConfigProvider(stored: stored)
        )
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.draft == stored)
        model.resetToDefaults()
        #expect(model.draft == .defaults)
        #expect(model.isDirty)
        model.setValue(nil, for: .due)
        #expect(!model.canSave)
        model.setValue(15, for: .due)
        #expect(model.canSave)
    }

    @Test("a refused save keeps the draft and names the allowed range")
    func refusedSave() async {
        let refusal = MedicationPhaseConfigRefusal(issues: [.init(path: "redValue", maximum: 1440)])
        let model = MedicationPhaseConfigModel(
            medicationID: "m1",
            repository: StubPhaseConfigProvider(stored: .defaults, saveError: refusal)
        )
        await model.load()
        model.setValue(90, for: .missed)
        let closed = await model.save()
        #expect(!closed)
        #expect(model.draft.missed.value == 90)
        #expect(model.saveError == refusal.message)
    }
}

private actor StubPhaseConfigProvider: MedicationPhaseConfigProviding {
    private var stored: MedicationPhaseConfig
    private let saveError: Error?

    init(stored: MedicationPhaseConfig, saveError: Error? = nil) {
        self.stored = stored
        self.saveError = saveError
    }

    func phaseConfig(medicationID _: String) async throws -> MedicationPhaseConfig {
        stored
    }

    func savePhaseConfig(_ config: MedicationPhaseConfig, medicationID _: String) async throws -> MedicationPhaseConfig {
        if let saveError { throw saveError }
        stored = config
        return config
    }

    func resetPhaseConfig(medicationID _: String) async throws {
        stored = .defaults
    }
}
