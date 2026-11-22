import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable file_length type_body_length

// #188 — a dose taken elsewhere must not stay open on the iPhone.
// One suite per point of the issue that this build changes.

// MARK: - (1) Foreground reload outlives the 250 ms budget

@MainActor
@Suite("#188 (1) — the foreground reload is owned by the store", .serialized)
struct ForegroundReloadOwnershipTests {
    /// Answers every list with `[]`, today's intakes with one taken dose after
    /// a delay, and fails anything else. A cancelled request fails, so a reload
    /// the caller's cancellation reached would deliver nothing.
    private final class SlowAPI: APIClientProtocol, @unchecked Sendable {
        let intakes: [MedicationIntake]
        let failIntakes: Bool

        init(intakes: [MedicationIntake], failIntakes: Bool = false) {
            self.intakes = intakes
            self.failIntakes = failIntakes
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            if T.self == [MedicationIntake].self, request.query.contains(where: { $0.1 == "today" }) {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { throw CancellationError() }
                if failIntakes { throw HLError.offline }
                if let value = intakes as? T { return value }
            }
            if let empty = [ComplianceDay]() as? T { return empty }
            if let empty = [MedicationWireDTO]() as? T { return empty }
            throw HLError.unknown("not stubbed")
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.unknown("not stubbed")
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not stubbed")
        }
    }

    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { continuation in
                continuation.yield(true)
                continuation.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    private func makeStore(_ api: SlowAPI) throws -> MedicationsStore {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach())
        let outbox = try OutboxQueue(inMemory: true)
        let store = MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox), swr: swr)
        store.externalTakeLog = ExternalTakeLog(url: nil)
        return store
    }

    private let taken = MedicationIntake(
        id: "intake-1",
        medicationId: "med-1",
        scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
        takenAt: Date(timeIntervalSince1970: 1_800_000_000),
        status: .taken
    )

    @Test("a caller cancelled at the deadline stops waiting; the reload still delivers")
    func reloadOutlivesCancelledCaller() async throws {
        let store = try makeStore(SlowAPI(intakes: [taken]))
        var changes = 0
        store.onIntakesDidChange = { changes += 1 }
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // The foreground pass: its deadline cancels the member after 30 ms.
        let member = Task { await store.loadOnForeground(now: start) }
        try await Task.sleep(for: .milliseconds(30))
        member.cancel()
        await member.value
        let owned = try #require(store.foregroundRevalidationTask, "the reload must still run")
        #expect(store.todayIntakes.isEmpty, "the server has not answered yet")

        await owned.value
        #expect(store.todayIntakes.first?.status == .taken)
        #expect(changes > 0, "onIntakesDidChange drives the Live Activity, widget and reminders")
        // Stamped after the .fresh delivery: a flap inside the window is dropped.
        #expect(store.shouldRunForegroundLoad(now: start.addingTimeInterval(1)) == false)
        #expect(store.foregroundRevalidationTask == nil)
    }

    @Test("a failed reload leaves the throttle open for the next foreground")
    func failedReloadDoesNotStamp() async throws {
        let store = try makeStore(SlowAPI(intakes: [], failIntakes: true))
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        await store.loadOnForeground(now: start)
        #expect(store.shouldRunForegroundLoad(now: start.addingTimeInterval(1)))
    }

    @Test("overlapping foregrounds join the reload in flight")
    func overlappingForegroundsJoin() throws {
        let store = try makeStore(SlowAPI(intakes: [taken]))
        let first = store.startForegroundRevalidation(now: Date(timeIntervalSinceReferenceDate: 3_000_000))
        let second = store.startForegroundRevalidation(now: Date(timeIntervalSinceReferenceDate: 3_000_001))
        #expect(first != nil)
        #expect(first == second)
        store.clearOnLogout()
        #expect(store.foregroundRevalidationTask == nil)
    }

    @Test("OwnedReloadWait returns on the caller's cancellation without cancelling the work")
    func waitReturnsOnCancel() async throws {
        let work = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(5)) }
        let waiter = Task { await OwnedReloadWait.untilDoneOrCancelled(work) }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        waiter.cancel()
        await waiter.value
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
        #expect(!work.isCancelled)
        work.cancel()
    }

    @Test("OwnedReloadWait returns when the work finishes")
    func waitReturnsOnCompletion() async {
        let work = Task {}
        await OwnedReloadWait.untilDoneOrCancelled(work)
        let cancelledFirst = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await OwnedReloadWait.untilDoneOrCancelled(Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(5)) })
        }
        await cancelledFirst.value
    }
}

// MARK: - (2) Content state and tokens

#if canImport(ActivityKit)
    @Suite("#188 (2) — the Live Activity content state always decodes")
    struct LiveActivityContentStateDecodingTests {
        private struct Fixture: Decodable {
            struct Case: Decodable {
                let name: String
                let contentState: [String: JSONValue]
                let expect: [String: JSONValue]
            }

            let cases: [Case]
        }

        /// A minimal JSON value, enough to re-encode a fixture case.
        private enum JSONValue: Codable, Equatable {
            case string(String), number(Double), bool(Bool)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let bool = try? container.decode(Bool.self) {
                    self = .bool(bool)
                } else if let number = try? container.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = try .string(container.decode(String.self))
                }
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .string(value): try container.encode(value)
                case let .number(value): try container.encode(value)
                case let .bool(value): try container.encode(value)
                }
            }
        }

        private static func fixture(file: String = #filePath) throws -> Fixture {
            let url = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/LiveActivity/medication-content-state.json")
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        }

        @Test("every golden case decodes to its expected state")
        func goldenCases() throws {
            let fixture = try Self.fixture()
            #expect(fixture.cases.count >= 5)
            for item in fixture.cases {
                let data = try JSONEncoder().encode(item.contentState)
                let state = try JSONDecoder().decode(MedicationActivityAttributes.ContentState.self, from: data)
                #expect(
                    state.status.rawValue == item.expect["status"].flatMap { if case let .string(s) = $0 { s } else { nil } },
                    "\(item.name)"
                )
                if case let .number(target)? = item.expect["countdownTarget"] {
                    #expect(state.countdownTarget.timeIntervalSinceReferenceDate == target, "\(item.name)")
                }
                #expect(.bool(state.confirmed) == item.expect["confirmed"], "\(item.name)")
                #expect(.bool(state.pendingConfirm) == item.expect["pendingConfirm"], "\(item.name)")
                #expect(.bool(state.isOverdue) == item.expect["isOverdue"], "\(item.name)")
                #expect(.string(state.timeFormatRaw) == item.expect["timeFormatRaw"], "\(item.name)")
                if case let .number(started)? = item.expect["pendingConfirmStartedAt"] {
                    #expect(state.pendingConfirmStartedAt?.timeIntervalSinceReferenceDate == started)
                } else {
                    #expect(state.pendingConfirmStartedAt == nil, "\(item.name)")
                }
            }
        }

        @Test("the encoder writes exactly the fixture's keys")
        func encodedKeysMatchFixture() throws {
            let state = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: Date(timeIntervalSinceReferenceDate: 805_000_000),
                pendingConfirmStartedAt: Date(timeIntervalSinceReferenceDate: 804_999_990)
            )
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
            let full = try #require(Self.fixture().cases.first { $0.name == "legacy-1.0-running-activity" })
            let fixtureKeys = Set(full.expect.keys)
            #expect(Set(object?.keys.map { $0 } ?? []) == fixtureKeys)
        }

        @Test("the empty end payload of server ≤ 1.48.5 no longer throws")
        func emptyEndDecodes() throws {
            let state = try JSONDecoder().decode(MedicationActivityAttributes.ContentState.self, from: Data("{}".utf8))
            #expect(state.status == .pending)
            #expect(state.countdownPresentation(now: state.countdownTarget.addingTimeInterval(-1)) != .hidden)
        }
    }

    @Suite("#188 (6) — the countdown after the due time")
    struct LiveActivityCountdownPresentationTests {
        private let due = Date(timeIntervalSince1970: 1_800_000_000)

        private func state(_ status: MedicationActivityAttributes.ContentState.Status) -> MedicationActivityAttributes.ContentState {
            MedicationActivityAttributes.ContentState(status: status, countdownTarget: due)
        }

        @Test("before the due time: a forward timer to it")
        func countsDown() {
            let now = due.addingTimeInterval(-600)
            #expect(state(.pending).countdownPresentation(now: now) == .countdown(now ... due))
        }

        @Test("from the due time on: overdue since the due time, counting up")
        func countsUpAfterDue() {
            #expect(state(.pending).countdownPresentation(now: due) == .overdueSince(due))
            #expect(state(.pending).countdownPresentation(now: due.addingTimeInterval(3600)) == .overdueSince(due))
        }

        @Test("snoozed, taken or confirmed: no countdown anywhere")
        func hiddenWhenNotPending() {
            #expect(state(.snoozed).countdownPresentation(now: due.addingTimeInterval(-60)) == .hidden)
            #expect(state(.taken).countdownPresentation(now: due) == .hidden)
            var confirmed = state(.pending)
            confirmed.confirmed = true
            #expect(confirmed.countdownPresentation(now: due) == .hidden)
        }

        @Test("stale at the due time so the system renders the hand-over")
        func staleDateIsDueTime() {
            #expect(MedicationLiveActivityPlan.staleDate(countdownTarget: due, now: due.addingTimeInterval(-1)) == due)
            #expect(MedicationLiveActivityPlan.staleDate(countdownTarget: due, now: due) == nil)
        }
    }
#endif

@Suite("#188 (2) — one update token per running Activity")
struct LiveActivityTokenRegistryTests {
    private func owner(_ med: String, _ activity: String, slot: TimeInterval) -> LiveActivityTokenOwner {
        LiveActivityTokenOwner(activityID: activity, medicationId: med, slot: Date(timeIntervalSince1970: slot))
    }

    @Test("the earliest slot's token is reported, independent of insertion order")
    func primaryIsEarliestSlot() {
        var forward = LiveActivityTokenRegistry()
        forward.upsert("b", owner: owner("med-b", "act-b", slot: 2000))
        forward.upsert("a", owner: owner("med-a", "act-a", slot: 1000))
        var backward = LiveActivityTokenRegistry()
        backward.upsert("a", owner: owner("med-a", "act-a", slot: 1000))
        backward.upsert("b", owner: owner("med-b", "act-b", slot: 2000))
        #expect(forward.primaryToken == "a")
        #expect(backward.primaryToken == "a")
        #expect(forward.orderedEntries.map(\.token) == ["a", "b"])
    }

    @Test("a second Activity of the same medication keeps its own token")
    func perActivityNotPerMedication() {
        var registry = LiveActivityTokenRegistry()
        registry.upsert("morning", owner: owner("med", "act-1", slot: 1000))
        registry.upsert("evening", owner: owner("med", "act-2", slot: 5000))
        #expect(registry.entries.count == 2)
        let changed1 = registry.remove(activityID: "act-1")
        #expect(changed1)
        #expect(registry.primaryToken == "evening")
    }

    @Test("upsert reports changes only; retain drops gone Activities")
    func changeReporting() {
        var registry = LiveActivityTokenRegistry()
        let changed2 = registry.upsert("t", owner: owner("m", "a", slot: 1))
        #expect(changed2)
        let changed3 = registry.upsert("t", owner: owner("m", "a", slot: 1))
        #expect(!changed3)
        let changed4 = registry.upsert("t2", owner: owner("m", "a", slot: 1))
        #expect(changed4)
        let changed5 = registry.retain(activityIDs: ["a"])
        #expect(!changed5)
        let changed6 = registry.retain(activityIDs: [])
        #expect(changed6)
        #expect(registry.primaryToken == nil)
        let changed7 = registry.remove(activityID: "a")
        #expect(!changed7)
    }

    @Test("the per-Activity body and the server's resolved slot open on capabilities, never on a version")
    func gatesFollowCapabilities() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-191-gates-\(UUID().uuidString)"))
        #expect(!LiveActivityPerActivityTokens.isAvailable(defaults: defaults))
        #expect(!MedicationServerResolvedSlots.isAvailable(defaults: defaults))
        MedicationCapabilities.record([.liveActivityTokensPerActivity, .doseState], defaults: defaults)
        #expect(LiveActivityPerActivityTokens.isAvailable(defaults: defaults))
        #expect(MedicationServerResolvedSlots.isAvailable(defaults: defaults))
        #expect(LiveActivityPerActivityTokens.fieldName == "liveActivityTokens")
    }
}

// MARK: - (5) Critical alarms

@Suite("#188 (5) — today's critical alarm of a resolved dose stays silent")
struct CriticalAlarmIntakeSuspensionTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar
    }

    /// Monday 2026-11-23 at `hour:minute`, Berlin.
    private func monday(_ hour: Int, _ minute: Int) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 11, day: 23, hour: hour, minute: minute)) ?? .distantPast
    }

    private func med(_ cadence: Cadence) -> Medication {
        let time = TimeOfDay(hour: 8, minute: 0)
        return Medication(
            id: "m1",
            name: "Med",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(cadence: cadence, timesOfDay: [time], windowStart: time)]),
            notificationsEnabled: true,
            active: true
        )
    }

    private func taken08() -> [MedicationReminderCompletion.ResolvedSlot] {
        [.init(medicationId: "m1", scheduledAt: monday(8, 0))]
    }

    private func plan(
        _ cadence: Cadence,
        now: Date,
        slots: [MedicationReminderCompletion.ResolvedSlot]
    ) -> [CriticalMedAlarmRouting.PlannedAlarm] {
        CriticalMedAlarmRouting.plannedAlarms(
            for: med(cadence), now: now, timeZone: berlin, resolvedSlots: slots, deviceTimeZone: berlin
        )
    }

    @Test("a daily dose taken early leaves today out of the recurrence and arms next week's (D3 #8)")
    func dailyTakenEarly() {
        let planned = plan(.daily, now: monday(7, 50), slots: taken08())
        #expect(planned == [
            .weekly(.init(hour: 8, minute: 0, weekdays: [.sun, .tue, .wed, .thu, .fri, .sat])),
            .fixed(at: monday(8, 0).addingTimeInterval(7 * 24 * 3600))
        ])
    }

    @Test("a once-a-week dose taken today moves to next week's occurrence")
    func weeklyOnlyToday() {
        let planned = plan(.weekdays([.mon]), now: monday(7, 50), slots: taken08())
        #expect(planned == [.fixed(at: monday(8, 0).addingTimeInterval(7 * 24 * 3600))])
    }

    @Test("no resolved slot, or the occurrence has passed: the alarm is unchanged")
    func unchangedOtherwise() {
        let full = [CriticalMedAlarmRouting.PlannedAlarm.weekly(.init(hour: 8, minute: 0, weekdays: []))]
        #expect(plan(.daily, now: monday(7, 50), slots: []) == full)
        #expect(plan(.daily, now: monday(8, 30), slots: taken08()) == full)
        let other = [MedicationReminderCompletion.ResolvedSlot(medicationId: "m2", scheduledAt: monday(8, 0))]
        #expect(plan(.daily, now: monday(7, 50), slots: other) == full)
    }

    @Test("matching follows the reminder completion: wall clock across zones or ±5 min")
    func matchingRule() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = tokyo
        let tokyoEight = try #require(tokyoCalendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 8)))
        #expect(MedicationReminderCompletion.occurrenceIsResolved(
            medicationId: "m1", start: tokyoEight, slots: taken08(), deviceTimeZone: tokyo, accountTimeZone: berlin
        ))
        #expect(MedicationReminderCompletion.occurrenceIsResolved(
            medicationId: "m1", start: monday(8, 4), slots: taken08(), deviceTimeZone: berlin, accountTimeZone: berlin
        ))
        #expect(!MedicationReminderCompletion.occurrenceIsResolved(
            medicationId: "m1", start: monday(8, 10), slots: taken08(), deviceTimeZone: berlin, accountTimeZone: berlin
        ))
    }
}

// MARK: - (7) Undo after a take outside the app, and after a delete

@Suite("#188 (7) — undo for takes outside the app and for deletes")
struct ExternalTakeUndoTests {
    private func tempLog() -> ExternalTakeLog {
        ExternalTakeLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString).json"))
    }

    private let slot = Date(timeIntervalSince1970: 1_800_000_000)
    private let own = ExternalTakeLog.Binding(rowID: "row-own", idempotencyKey: "key-own")

    @Test("the newest take inside the window is offered once")
    func offeredOnce() {
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .notification, binding: own, now: slot)
        log.record(medicationId: "b", scheduledFor: slot, source: .widget, binding: own, now: slot.addingTimeInterval(60))
        let offer = log.takeOffer(now: slot.addingTimeInterval(120))
        #expect(offer?.medicationId == "b")
        #expect(offer?.source == .widget)
        #expect(log.takeOffer(now: slot.addingTimeInterval(121)) == nil)
    }

    @Test("an old take is not offered as \"just logged\"")
    func oldTakeNotOffered() {
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .liveActivity, binding: own, now: slot)
        #expect(log.takeOffer(now: slot.addingTimeInterval(ExternalTakeLog.offerWindow + 1)) == nil)
        #expect(log.read().isEmpty)
    }

    @Test("the same dose recorded twice is one entry")
    func dedupes() {
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .watch, binding: own, now: slot)
        log.record(medicationId: "a", scheduledFor: slot, source: .alarm, binding: own, now: slot.addingTimeInterval(5))
        #expect(log.read().map(\.source) == [.alarm])
    }

    @Test("only the real taken row this device wrote can be undone")
    func intakeToUndo() {
        let entry = ExternalTakeLog.Entry(
            medicationId: "a", scheduledFor: slot, source: .notification, at: slot, rowID: "i1", idempotencyKey: "k1"
        )
        let real = MedicationIntake(id: "i1", medicationId: "a", scheduledAt: slot.addingTimeInterval(30), takenAt: slot, status: .taken)
        let synth = MedicationIntake(id: "synth:a|x", medicationId: "a", scheduledAt: slot, takenAt: slot, status: .taken)
        let pending = MedicationIntake(id: "i2", medicationId: "a", scheduledAt: slot, takenAt: nil, status: .pending)
        #expect(MedicationsStore.intakeToUndo(for: entry, in: [synth, pending, real])?.id == "i1")
        #expect(MedicationsStore.intakeToUndo(for: entry, in: [synth, pending]) == nil)
    }

    // MARK: R1 (1) — never someone else's take

    @Test("R1 (1): the pill box's take on the same slot is never the row to undo")
    func foreignTakeIsNeverUndone() {
        // The widget answered `alreadyTaken`: before the fix it noted the
        // take anyway, and the slot match found the pill box's row.
        let pillBox = MedicationIntake(
            id: "box-row", medicationId: "a", scheduledAt: slot, takenAt: slot, status: .taken,
            takenVia: "INTEGRATION", idempotencyKey: "box-key"
        )
        let legacy = ExternalTakeLog.Entry(medicationId: "a", scheduledFor: slot, source: .widget, at: slot)
        #expect(MedicationsStore.intakeToUndo(for: legacy, in: [pillBox]) == nil)
        let ownByRow = ExternalTakeLog.Entry(medicationId: "a", scheduledFor: slot, source: .widget, at: slot, rowID: "own-row")
        #expect(MedicationsStore.intakeToUndo(for: ownByRow, in: [pillBox]) == nil)
        let ownByKey = ExternalTakeLog.Entry(medicationId: "a", scheduledFor: slot, source: .widget, at: slot, idempotencyKey: "own-key")
        #expect(MedicationsStore.intakeToUndo(for: ownByKey, in: [pillBox]) == nil)
    }

    @Test("R1 (1): a queued take is found by its idempotency key once it lands")
    func queuedTakeFoundByKey() {
        let landed = MedicationIntake(
            id: "row-9", medicationId: "a", scheduledAt: slot, takenAt: slot, status: .taken, idempotencyKey: "own-key"
        )
        let entry = ExternalTakeLog.Entry(medicationId: "a", scheduledFor: slot, source: .widget, at: slot, idempotencyKey: "own-key")
        #expect(MedicationsStore.intakeToUndo(for: entry, in: [landed])?.id == "row-9")
    }

    @Test("R1 (1): alreadyTaken, a dropped write and signed out note nothing; a write or queue binds itself")
    func bindingForCommit() {
        let receipt = ReminderIntakeReceipt(rowID: "row-1", syncVersion: 2)
        let already = MedicationAlreadyTaken(takenAt: slot, source: "INTEGRATION")
        #expect(ExternalTakeLog.Binding.forCommit(error: already, receipt: nil, idempotencyKey: "k") == nil)
        #expect(ExternalTakeLog.Binding.forCommit(
            error: HLError.server(status: 422, code: nil, message: "x"),
            receipt: nil,
            idempotencyKey: "k"
        ) == nil)
        #expect(ExternalTakeLog.Binding.forCommit(error: nil, receipt: receipt, idempotencyKey: "k")
            == ExternalTakeLog.Binding(rowID: "row-1", idempotencyKey: "k"))
        #expect(ExternalTakeLog.Binding.forCommit(error: HLError.offline, receipt: nil, idempotencyKey: "k")
            == ExternalTakeLog.Binding(rowID: nil, idempotencyKey: "k"))
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .widget, binding: nil, now: slot)
        #expect(log.read().isEmpty)
    }

    @Test("R1 (1), update path: an entry an older build wrote decodes and is never offered")
    func legacyEntryDecodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"[{"medicationId":"a","scheduledFor":"2027-01-15T08:00:00Z","source":"widget","at":"2027-01-15T08:00:05Z"}]"#
        try Data(json.utf8).write(to: url)
        let log = ExternalTakeLog(url: url)
        let entry = try #require(log.read().first)
        #expect(entry.binding.isEmpty)
        let pillBox = MedicationIntake(
            id: "box",
            medicationId: "a",
            scheduledAt: entry.scheduledFor,
            takenAt: entry.scheduledFor,
            status: .taken
        )
        #expect(MedicationsStore.intakeToUndo(for: entry, in: [pillBox]) == nil)
    }

    // MARK: R1 (9) — the offer is not lost

    @Test("R1 (9): a take whose row is not on the list yet stays for the next open")
    func unmatchedTakeStays() {
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .widget, binding: own, now: slot)
        // The row is not loaded yet: nothing offered, and the entry stays.
        #expect(log.takeOffer(now: slot.addingTimeInterval(60), isUndoable: { _ in false }) == nil)
        #expect(log.read().count == 1)
        // The next open has the row.
        #expect(log.takeOffer(now: slot.addingTimeInterval(120), isUndoable: { _ in true })?.medicationId == "a")
        #expect(log.read().isEmpty)
    }

    @Test("R1 (9): only the offered entry and older ones leave; a newer unmatched one stays")
    func onlySettledEntriesLeave() {
        let log = tempLog()
        log.record(medicationId: "a", scheduledFor: slot, source: .widget, binding: own, now: slot)
        log.record(medicationId: "b", scheduledFor: slot, source: .watch, binding: own, now: slot.addingTimeInterval(30))
        let offer = log.takeOffer(now: slot.addingTimeInterval(60), isUndoable: { $0.medicationId == "a" })
        #expect(offer?.medicationId == "a")
        #expect(log.read().map(\.medicationId) == ["b"])
    }

    @Test("a deleted entry is restored as it was; an open row has nothing to restore")
    func restoration() {
        let takenLate = PaginatedIntakeEvent(id: "e", takenAt: slot.addingTimeInterval(900), skipped: false, scheduledFor: slot)
        let skipped = PaginatedIntakeEvent(id: "e", takenAt: nil, skipped: true, scheduledFor: slot)
        let open = PaginatedIntakeEvent(id: "e", takenAt: nil, skipped: false, scheduledFor: slot)
        #expect(MedicationsStore.restoration(of: takenLate)?.takenAt == slot.addingTimeInterval(900))
        #expect(MedicationsStore.restoration(of: takenLate)?.skipped == false)
        #expect(MedicationsStore.restoration(of: skipped)?.skipped == true)
        #expect(MedicationsStore.restoration(of: open) == nil)
    }
}

// MARK: - (8) One snooze, web wording

@Suite("#188 (8) — snooze and wording")
struct MedicationSnoozeAndWordingTests {
    @Test("notification, alarm and the Watch's PATCH snooze for the same span")
    func oneSnoozeInterval() throws {
        #if canImport(AlarmKit)
            #expect(CriticalMedAlarmService.snoozeIntervalSeconds == MedicationSnooze.interval)
        #endif
        let body = MedicationsRepository.IntakeUpdate(
            intakeId: "i", status: "snoozed", takenAt: .now, snoozedUntil: Date(timeIntervalSince1970: 1)
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(object?["snoozedUntil"] != nil)
        let taken = MedicationsRepository.IntakeUpdate(intakeId: "i", status: "taken", takenAt: .now)
        let takenObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(taken)) as? [String: Any]
        #expect(takenObject?["snoozedUntil"] == nil)
    }

    @Test("update path: an outbox payload from an older build still decodes")
    func oldOutboxPayloadDecodes() throws {
        let old = Data(#"{"intakeId":"i","status":"taken","takenAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(MedicationsRepository.IntakeUpdate.self, from: old)
        #expect(decoded.snoozedUntil == nil)
    }

    /// The final term list of #191 (actions as verbs, states as participles),
    /// which replaced the #188 interim wording ("Jetzt einnehmen") and its
    /// per-surface keys (`med.card.status.*`, `med.ledger.status.*`) with the
    /// one vocabulary under `med.dose.*`.
    @Test("German dose terms match the web", arguments: [
        ("med.dose.action.take", "Einnehmen"),
        ("med.dose.action.skip", "Überspringen"),
        ("med.dose.action.undo", "Rückgängig"),
        ("med.dose.state.pending", "Ausstehend"),
        ("med.dose.state.due", "Fällig"),
        ("med.dose.state.overdue", "Überfällig"),
        ("med.dose.state.taken", "Genommen"),
        ("med.dose.state.taken_late", "Verspätet genommen"),
        ("med.dose.state.skipped", "Übersprungen"),
        ("med.dose.state.missed", "Verpasst"),
        ("med.dose.form.title", "Einnahme erfassen"),
        ("Mark as skipped", "Als übersprungen markieren"),
        ("alarm.action.snooze", "Später"),
        ("undo.medication.intake.deleted", "Einnahme gelöscht")
    ])
    func germanTerms(key: String, value: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        let entry = strings?[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let german = (localizations?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == value)
    }
}
