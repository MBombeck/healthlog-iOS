import Foundation
@testable import HealthLog
import Synchronization
import Testing

// #191 — the web UX of 1.49.0 mirrored in the app: the term list and glyph
// rule, the snooze span, the final bulk and undo shapes, the open doses from
// the resolved state, and the stored HH:mm in the person's hour cycle.

/// Answers every request with one canned JSON and records the requests.
private final class CannedAPI: APIClientProtocol, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    private let lock = Mutex<[Call]>([])
    private let json: String

    init(_ json: String) {
        self.json = json
    }

    var calls: [Call] {
        lock.withLock { $0 }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let call = Call(
            method: request.method.rawValue,
            path: request.path,
            query: Dictionary(request.query, uniquingKeysWith: { $1 }),
            body: request.body
        )
        lock.withLock { $0.append(call) }
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await send(request)
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("not stubbed")
    }
}

private func suite(_ label: String = #function) throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "test-191-ux-\(label)-\(UUID().uuidString)"))
}

// MARK: - Term list and glyph rule

@Suite("#191 — one vocabulary and one glyph rule for a dose")
struct MedicationDoseVocabularyTests {
    @Test("the wire states map to the term list's phases; unknown words to nothing")
    func wireStates() {
        #expect(MedicationDosePhase(wire: "upcoming") == .pending)
        #expect(MedicationDosePhase(wire: "due") == .due)
        #expect(MedicationDosePhase(wire: "overdue") == .overdue)
        #expect(MedicationDosePhase(wire: "taken") == .taken)
        #expect(MedicationDosePhase(wire: "taken", takenLate: true) == .takenLate)
        #expect(MedicationDosePhase(wire: "skipped") == .skipped)
        #expect(MedicationDosePhase(wire: "missed") == .missed)
        #expect(MedicationDosePhase(wire: "snoozed") == nil)
        #expect(MedicationDosePhase(wire: nil) == nil)
    }

    @Test("clock for pending and due, alert for overdue, triangle for missed, check for taken, skip-forward")
    func glyphRule() {
        #expect(MedicationDoseLook(phase: .pending).glyph == .clock)
        #expect(MedicationDoseLook(phase: .due).glyph == .clock)
        #expect(MedicationDoseLook(phase: .overdue).glyph == .alert)
        #expect(MedicationDoseLook(phase: .overdue, lateInWindow: true).glyph == .triangle)
        #expect(MedicationDoseLook(phase: .missed).glyph == .triangle)
        #expect(MedicationDoseLook(phase: .taken).glyph == .check)
        #expect(MedicationDoseLook(phase: .takenLate).glyph == .check)
        #expect(MedicationDoseLook(phase: .takenLate).tone == .late, "amber when late")
        #expect(MedicationDoseLook(phase: .skipped).glyph == .skipForward)
    }

    @Test("never a check on a dose still to take")
    func neverACheckOnAnOpenDose() {
        for phase in MedicationDosePhase.allCases where phase.isOpen {
            #expect(MedicationDoseLook(phase: phase).glyph != .check, "\(phase)")
            #expect(MedicationDoseLook(phase: phase, lateInWindow: true).glyph != .check, "\(phase)")
        }
    }

    @Test("open now and next means upcoming, due or overdue")
    func upcomingOrDue() {
        let open = MedicationDosePhase.allCases.filter(\.isUpcomingOrDue)
        #expect(Set(open) == [.pending, .due, .overdue])
    }

    @Test("the snooze action names its span; the snoozed state names its time")
    func sentences() {
        #expect(MedicationDoseWords.snooze(minutes: 45).contains("45"))
        #expect(MedicationDoseWords.snoozedUntil("08:30").contains("08:30"))
        #expect(MedicationDoseWords.toastTaken(name: "Lisinopril", time: "08:12").contains("Lisinopril"))
        #expect(MedicationDoseWords.toastSkipped(name: "Lisinopril").contains("Lisinopril"))
    }

    @Test("the card's overdue pill: amber alert, red triangle when late in its window, due with the clock")
    @MainActor
    func cardPill() {
        #expect(MedicationDoseLook(phase: .due).title == MedicationDosePhase.due.title)
        let late = MedicationDoseLook(phase: .overdue, lateInWindow: true)
        #expect(late.tone == .critical)
        #expect(late.title == MedicationDosePhase.overdue.title, "'Stark überfällig' is gone")
    }

    @Test("the toast after a take or skip names the medication; without a name the old line")
    func markToast() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MedicationsStore.markToast(status: .taken, name: "Lisinopril", at: at).contains("Lisinopril"))
        #expect(MedicationsStore.markToast(status: .skipped, name: " Lisinopril ", at: at).contains("Lisinopril"))
        #expect(MedicationsStore.markToast(status: .taken, name: nil, at: at) == String(localized: "undo.medication.taken"))
    }

    @Test("one Undo for 'take all due' names how many were recorded")
    func batchMessage() {
        #expect(MedicationsStore.batchUndoMessage(count: 3).contains("3"))
    }
}

// MARK: - Snooze

@Suite("#191 — the snooze span on every surface")
struct MedicationSnoozeSurfaceTests {
    @Test("the Watch snapshot carries the span; an older phone's blob reads 30")
    func watchSnapshot() throws {
        let snapshot = WatchSnapshot(
            doses: [], scheduledCount: 0, takenCount: 0, recentMoodScore: nil,
            signedIn: true, snoozeMinutes: 45, generatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WatchSnapshot.self, from: data).snoozeMinutes == 45)
        let old = #"{"doses":[],"scheduledCount":0,"takenCount":0,"signedIn":true}"#
        #expect(try JSONDecoder().decode(WatchSnapshot.self, from: Data(old.utf8)).snoozeMinutes == 30)
        let odd = #"{"doses":[],"scheduledCount":0,"takenCount":0,"signedIn":true,"snoozeMinutes":999}"#
        #expect(try JSONDecoder().decode(WatchSnapshot.self, from: Data(odd.utf8)).snoozeMinutes == 30)
    }

    @Test("the settings offer the account's own span even when the web set another")
    @MainActor
    func choices() {
        #expect(NotificationsScreen.snoozeChoices(including: 30) == MedicationSnooze.choices)
        #expect(NotificationsScreen.snoozeChoices(including: 25).contains(25))
        #expect(NotificationsScreen.snoozeChoices(including: 25) == NotificationsScreen.snoozeChoices(including: 25).sorted())
    }

    @Test("PATCH { medication: { snoozeMinutes } } with baseUpdatedAt, clamped to 5...240")
    func patchBody() async throws {
        let api = CannedAPI(#"{"medication":{"snoozeMinutes":240},"updatedAt":"2026-11-21T08:00:00.000Z"}"#)
        let repo = NotificationsRepository(api: api)
        let echoed = try await repo.setMedicationSnoozeMinutes(999)
        #expect(echoed == 240)
        let call = try #require(api.calls.first)
        #expect(call.method == "PATCH")
        #expect(call.path == "/api/auth/me/notification-prefs")
        let body = try #require(call.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let medication = body["medication"] as? [String: Any]
        #expect(medication?["snoozeMinutes"] as? Int == 240)
        _ = try await repo.setMedicationSnoozeMinutes(30)
        let second = try #require(api.calls.last?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(second["baseUpdatedAt"] as? String == "2026-11-21T08:00:00.000Z", "the echo's token guards the next write")
    }

    @Test("a changed span is announced, so the notification category is renamed")
    func announcesChange() throws {
        let defaults = try suite()
        MedicationCapabilities.record([.snoozeSetting], defaults: defaults)
        let fired = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: MedicationSnooze.didChange, object: nil, queue: nil) { _ in
            fired.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        MedicationSnooze.record(serverMinutes: 45, defaults: defaults)
        MedicationSnooze.record(serverMinutes: 45, defaults: defaults)
        #expect(fired.withLock { $0 } == 1, "the same span twice is one change")
        #expect(MedicationSnooze.minutes(defaults: defaults) == 45)
    }

    @Test("the card shows the snooze that holds one of today's doses")
    func cardSnoozedUntil() {
        let until = Date(timeIntervalSince1970: 1_800_001_800)
        let rows = [
            MedicationIntake(
                id: "a",
                medicationId: "m",
                scheduledAt: until.addingTimeInterval(-3600),
                takenAt: nil,
                status: .snoozed,
                snoozedUntil: until
            ),
            MedicationIntake(
                id: "b",
                medicationId: "other",
                scheduledAt: until,
                takenAt: nil,
                status: .snoozed,
                snoozedUntil: until.addingTimeInterval(60)
            )
        ]
        #expect(ActiveMedicationsSection.snoozedUntil(medicationId: "m", todayIntakes: rows) == until)
        #expect(ActiveMedicationsSection.snoozedUntil(medicationId: "none", todayIntakes: rows) == nil)
    }
}

// MARK: - Final bulk and undo shapes

@Suite("#191 — the final bulk envelope and the undo's preconditions")
struct MedicationBulkUndoFinalTests {
    @Test("the bulk answer is read from entries; an alreadyTaken entry's intake carries syncVersion")
    func bulkSyncVersion() async throws {
        let json = """
        {"processed":1,"inserted":1,"updated":0,"duplicates":0,"skipped":[],\
        "entries":[{"index":0,"status":"inserted","id":"row-4","intake":{"id":"row-4","syncVersion":3}}]}
        """
        let repo = try MedicationsRepository(api: CannedAPI(json), outbox: OutboxQueue(inMemory: true))
        let receipt = try await repo.recordFromReminderReturningReceipt(medicationId: "m", scheduledFor: .now, status: .taken)
        #expect(receipt == ReminderIntakeReceipt(rowID: "row-4", syncVersion: 3))
    }

    @Test("update path: a 1.48 entry without intake has no version, the row id still comes back")
    func bulkWithoutVersion() async throws {
        let json = #"{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"row-5"}]}"#
        let repo = try MedicationsRepository(api: CannedAPI(json), outbox: OutboxQueue(inMemory: true))
        let receipt = try await repo.recordFromReminderReturningReceipt(medicationId: "m", scheduledFor: .now, status: .taken)
        #expect(receipt == ReminderIntakeReceipt(rowID: "row-5", syncVersion: nil))
    }

    @Test("both preconditions go out on the DELETE once the capability is open")
    func bothPreconditions() throws {
        let defaults = try suite()
        MedicationCapabilities.record([.undoPrecondition], defaults: defaults)
        let both = try #require(IntakeUndoPrecondition(syncVersion: 4, idempotencyKey: "k-9"))
        let items = Dictionary(both.queryItems(capabilities: defaults), uniquingKeysWith: { $1 })
        #expect(items == ["expectedSyncVersion": "4", "expectedIdempotencyKey": "k-9"])
    }
}

// MARK: - Open doses from the resolved state

@Suite("#191 point 10 — open doses come from the today rows' state")
struct MedicationOpenDosesTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: String, _ offset: TimeInterval, state: String?, dueOffset: TimeInterval? = nil) -> MedicationIntake {
        let slot = base.addingTimeInterval(offset)
        return MedicationIntake(
            id: id, medicationId: "m", scheduledAt: slot, takenAt: nil, status: .pending, snoozedUntil: nil,
            doseState: state.map {
                ServerDoseState(state: $0, dueAt: dueOffset.map { base.addingTimeInterval($0) } ?? slot, slotInstant: slot)
            }
        )
    }

    @Test("upcoming, due and overdue in dueAt order; taken, skipped and missed never")
    func openSlots() {
        let rows = [
            row("c", 7200, state: "upcoming"),
            row("a", -3600, state: "overdue"),
            row("t", -7200, state: "taken"),
            row("b", 0, state: "due"),
            row("m", -9000, state: "missed"),
            row("s", 3600, state: "skipped")
        ]
        let slots = ComplianceRingCard.openDoseSlots(rows, enabled: true)
        #expect(slots == [base.addingTimeInterval(-3600), base, base.addingTimeInterval(7200)])
    }

    @Test("without a state (an older server, or shut) the snapshot's slots stay in charge")
    func fallsBack() {
        #expect(ComplianceRingCard.openDoseSlots([row("a", 0, state: nil)], enabled: true) == nil)
        #expect(ComplianceRingCard.openDoseSlots([row("a", 0, state: "due")], enabled: false) == nil)
    }

    @Test("the detail page acts on the latest due dose, else the next; a snoozed dose is open")
    func detailOpenDose() {
        var snoozed = row("s", -600, state: nil)
        snoozed = MedicationIntake(
            id: "s", medicationId: "m", scheduledAt: snoozed.scheduledAt, takenAt: nil, status: .snoozed,
            snoozedUntil: base.addingTimeInterval(1200)
        )
        let rows = [row("early", -7200, state: nil), snoozed, row("later", 3600, state: nil)]
        #expect(MedicationDetailDoseActions.openDose(medicationId: "m", todayIntakes: rows, now: base)?.id == "s")
        #expect(MedicationDetailDoseActions.openDose(medicationId: "m", todayIntakes: [row("later", 3600, state: nil)], now: base)?
            .id == "later")
        let look = MedicationDetailDoseActions.look(for: snoozed, now: base, serverState: false)
        #expect(look.phase == .due)
        #expect(MedicationDetailDoseActions.note(for: snoozed, look: look, now: base)?.isEmpty == false)
    }

    @Test("the detail page shows the server's state when it resolved one")
    func detailServerState() {
        let overdue = row("o", -3600, state: "overdue")
        #expect(MedicationDetailDoseActions.look(for: overdue, now: base, serverState: true).phase == .overdue)
        #expect(MedicationDetailDoseActions.look(for: overdue, now: base, serverState: false).phase == .due)
    }
}

// MARK: - Dose history state

@Suite("#191 — dose-history rows carry state and takenLate")
struct MedicationDoseHistoryStateTests {
    @Test("state and takenLate decode; the ledger line follows them")
    @MainActor
    func decodes() throws {
        let json = #"{"kind":"slot","at":"2026-11-21T07:00:00Z","timeOfDay":"08:00","status":"taken_late","state":"taken","takenLate":true}"#
        let row = try JSONDecoder.hlDefault.decode(MedicationDoseHistoryRow.self, from: Data(json.utf8))
        #expect(row.stateRaw == "taken")
        #expect(row.takenLate == true)
        #expect(LedgerHistoryRow.statusLine(row: row)?.title == MedicationDosePhase.takenLate.title)
    }

    @Test("update path: a row from an older server without state reads its status")
    @MainActor
    func olderRow() throws {
        let json = #"{"kind":"slot","at":"2026-11-21T07:00:00Z","timeOfDay":"08:00","status":"missed"}"#
        let row = try JSONDecoder.hlDefault.decode(MedicationDoseHistoryRow.self, from: Data(json.utf8))
        #expect(row.stateRaw == nil)
        #expect(LedgerHistoryRow.statusLine(row: row)?.title == MedicationDosePhase.missed.title)
    }
}

// MARK: - Stored HH:mm in the hour cycle

@Suite("#191 point 7 — stored HH:mm in the same hour cycle as instants")
struct StoredClockTimeTests {
    @Test("a 12-hour locale shows 8:00 PM, a 24-hour one 20:00; garbage stays as it came")
    func hourCycle() {
        let us = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        #expect(ClockTimeText.wire("20:00", locale: us).contains("8"))
        #expect(ClockTimeText.wire("20:00", locale: us).uppercased().contains("PM"))
        #expect(ClockTimeText.wire("20:00", locale: de) == "20:00")
        #expect(ClockTimeText.wire("8:05", locale: de) == "08:05")
        #expect(ClockTimeText.wire("abends") == "abends")
        #expect(ClockTimeText.parse("24:00") == nil)
        #expect(ClockTimeText.parse("07:30:00").map { [$0.0, $0.1] } == [7, 30])
    }
}

// MARK: - Note (#174)

@Suite("#174 — the medication note is edited and sent only when changed")
struct MedicationNoteEditTests {
    @Test("unchanged is absent, changed is trimmed, emptied clears")
    func write() {
        #expect(MedicationNoteWrite.value(edited: "Mit Essen", baseline: "Mit Essen") == nil)
        #expect(MedicationNoteWrite.value(edited: " Mit Essen ", baseline: "Mit Essen") == nil)
        #expect(MedicationNoteWrite.value(edited: "Vor dem Frühstück ", baseline: "Mit Essen") == "Vor dem Frühstück")
        #expect(MedicationNoteWrite.value(edited: "  ", baseline: "Mit Essen")?.isEmpty == true)
        #expect(MedicationNoteWrite.capped(String(repeating: "a", count: 600)).count == 500)
    }

    @Test("the PUT body names note only when it changed")
    func patchBody() throws {
        var patch = MedicationsRepository.MedicationPatch(name: "X")
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(body["note"] == nil, "update path: an edit that does not touch the note leaves the web's note")
        patch.note = ""
        body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect((body["note"] as? String)?.isEmpty == true)
    }

    @Test("update path: an outbox patch written before the note field decodes")
    func legacyPayload() throws {
        let legacy = #"{"name":"Lisinopril"}"#
        let patch = try JSONDecoder().decode(MedicationsRepository.MedicationPatch.self, from: Data(legacy.utf8))
        #expect(patch.note == nil)
    }
}

// MARK: - Nachtrag 16:40 UTC

@Suite("#191 (final) — malformed preconditions are never sent; doses past at creation are not owed")
struct MedicationContractAddendumTests {
    @Test("a negative version, an empty key and a key over 128 characters are left out")
    func invalidPreconditionsAreDropped() {
        #expect(IntakeUndoPrecondition(syncVersion: -1, idempotencyKey: nil) == nil)
        #expect(IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: String(repeating: "k", count: 129)) == nil)
        let mixed = IntakeUndoPrecondition(syncVersion: -3, idempotencyKey: "k-1")
        #expect(mixed?.syncVersion == nil)
        #expect(mixed?.idempotencyKey == "k-1")
        #expect(IntakeUndoPrecondition(syncVersion: 0, idempotencyKey: nil)?.syncVersion == 0)
        #expect(IntakeUndoPrecondition(syncVersion: nil, idempotencyKey: String(repeating: "k", count: 128)) != nil)
    }

    @Test("422 invalidPrecondition is told apart and gets a sentence")
    func invalidPreconditionNotice() {
        let refusal = HLError.server(status: 422, code: "medications.intake.invalidPrecondition", message: "")
        #expect(IntakeUndoPrecondition.isInvalidPrecondition(refusal))
        #expect(!IntakeUndoPrecondition.isInvalidPrecondition(HLError.server(
            status: 409,
            code: "medications.intake.changedSinceSeen",
            message: ""
        )))
        #expect(IntakeUndoPrecondition.invalidPreconditionNotice.userFacingDescription.isEmpty == false)
    }

    @Test("the new capability keys are read from features")
    func newKeys() {
        let flags = MedicationCapabilities.flags(inFeatures: ["medication.intake-sync-version", "medication.current-dose-open-slot"])
        #expect(flags == [.intakeSyncVersion, .currentDoseOpenSlot])
    }

    @Test("a slot already past when the medication was created is not owed; later slots and rolling are")
    func notOwedAtCreation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12)))
        let created = try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        let morning = MedicationWindowStatus.DoseBand(timeOfDay: TimeOfDay(hour: 8, minute: 0), startMinutes: 420, endMinutes: 540)
        let evening = MedicationWindowStatus.DoseBand(timeOfDay: TimeOfDay(hour: 20, minute: 0), startMinutes: 1140, endMinutes: 1260)
        let daily = ScheduleEntry(cadence: .daily, timesOfDay: [TimeOfDay(hour: 8, minute: 0)], windowStart: TimeOfDay(hour: 8, minute: 0))
        let rolling = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
            windowStart: TimeOfDay(hour: 8, minute: 0)
        )
        #expect(!MedicationWindowStatus.isOwed(entry: daily, band: morning, createdAt: created, now: day, calendar: calendar))
        #expect(MedicationWindowStatus.isOwed(entry: daily, band: evening, createdAt: created, now: day, calendar: calendar))
        #expect(MedicationWindowStatus.isOwed(entry: rolling, band: morning, createdAt: created, now: day, calendar: calendar))
        #expect(
            MedicationWindowStatus.isOwed(entry: daily, band: morning, createdAt: nil, now: day, calendar: calendar),
            "update path: a cached medication without createdAt grades as before"
        )
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        #expect(MedicationWindowStatus.isOwed(entry: daily, band: morning, createdAt: created, now: nextDay, calendar: calendar))
    }
}

// MARK: - Nachtrag #190, 20:09 UTC

@Suite("#190 (final) — the server's three instants, flat bulk syncVersion, plain refusals")
struct MedicationContract190FinalTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(status: IntakeStatus = .pending, due: TimeInterval, overdue: TimeInterval, missed: TimeInterval) -> MedicationIntake {
        MedicationIntake(
            id: "r", medicationId: "m", scheduledAt: base, status: status,
            doseState: ServerDoseState(
                state: "upcoming",
                dueAt: base.addingTimeInterval(due),
                overdueSince: base.addingTimeInterval(overdue),
                slotInstant: base,
                missedAfter: base.addingTimeInterval(missed)
            )
        )
    }

    @Test("dueAt, overdueSince and missedAfter decide the phase on the clock")
    func timedPhase() throws {
        let state = try #require(row(due: -60, overdue: 3600, missed: 7200).doseState)
        #expect(state.phase(at: base.addingTimeInterval(-120)) == .pending)
        #expect(state.phase(at: base) == .due)
        #expect(state.phase(at: base.addingTimeInterval(3600)) == .overdue)
        #expect(state.phase(at: base.addingTimeInterval(7200)) == .missed)
        #expect(ServerDoseState(state: "due").phase(at: base) == nil, "update path: a row without instants")
    }

    @Test("the card's pill follows the instants of the open dose")
    func cardPill() {
        let rows = [row(due: -60, overdue: 3600, missed: 7200)]
        #expect(ActiveMedicationsSection
            .serverWindowStatus(medicationId: "m", todayIntakes: rows, now: base, enabled: true) == .some(.inWindow))
        #expect(ActiveMedicationsSection.serverWindowStatus(
            medicationId: "m",
            todayIntakes: rows,
            now: base.addingTimeInterval(4000),
            enabled: true
        ) == .some(.late))
        #expect(ActiveMedicationsSection.serverWindowStatus(
            medicationId: "m",
            todayIntakes: rows,
            now: base.addingTimeInterval(-600),
            enabled: true
        ) == .some(nil))
        #expect(ActiveMedicationsSection.serverWindowStatus(medicationId: "m", todayIntakes: rows, now: base, enabled: false) == nil)
    }

    @Test("a flat entries[].syncVersion is read")
    func flatSyncVersion() async throws {
        let json = #"{"processed":1,"inserted":1,"entries":[{"index":0,"status":"inserted","id":"row-7","syncVersion":2}]}"#
        let repo = try MedicationsRepository(api: CannedAPI(json), outbox: OutboxQueue(inMemory: true))
        let receipt = try await repo.recordFromReminderReturningReceipt(medicationId: "m", scheduledFor: .now, status: .taken)
        #expect(receipt?.syncVersion == 2)
    }

    @Test("force_slot.occupied becomes a sentence; other errors stay")
    func occupied() {
        let refusal = HLError.server(status: 422, code: IntakeWriteRefusal.forceSlotOccupiedCode, message: "raw")
        guard case let .server(_, _, message) = IntakeWriteRefusal.explained(refusal) else { Issue.record("shape")
            return
        }
        #expect(message != "raw")
        let other = HLError.server(status: 422, code: "x", message: "raw")
        #expect(IntakeWriteRefusal.explained(other) == other)
    }
}
