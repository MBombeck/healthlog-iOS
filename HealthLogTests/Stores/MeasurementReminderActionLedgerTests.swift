import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// MARK: - ROUTE-07 (v1.37.20) — server-authoritative actions and ledger

/// **Plan 08-22 — the store half of the accepted skip / snooze / history surface.**
///
/// Written as an `extension` rather than as more members of the suite body for
/// the reason 08-19 recorded one file over: the original suite body is already
/// most of `type_body_length`'s budget, and these cases are their own subject.
/// They share the suite's `@MainActor` isolation and its private `row(id:…)`
/// helper, so nothing is duplicated.
///
/// The doctrine every case here exists to pin: **the store never builds a
/// reminder row.** Every row it holds arrived from the server, so no field can
/// be forgotten by a rebuild — the defect 08-19 left in
/// `optimisticallySatisfied`, where three appended-with-default parameters
/// silently reset `snoozedUntil` / `lastSkippedAt` / `skipCount` on the
/// optimistic placeholder.
extension MeasurementRemindersStoreTests {
    /// Every field the accepted `MeasurementReminderDTO` publishes, as the model
    /// spells it. The count is asserted against `Mirror` so a sixteenth-plus-one
    /// field cannot join the DTO without this enumeration noticing — which is
    /// the mechanical half of "enumerate what you carry".
    nonisolated static let serverOwnedFields = [
        "id", "label", "measurementType", "intervalDays", "rrule", "anchorDate",
        "endsOn", "origin", "notifyHour", "location", "nextDueAt",
        "lastSatisfiedAt", "snoozedUntil", "lastSkippedAt", "skipCount", "enabled"
    ]

    /// A row with every one of the sixteen fields at a distinctive, non-default
    /// value, so any rebuild that forgets one is visible as a changed field
    /// rather than as a coincidence.
    nonisolated static func fullyPopulatedRow(id: String = "r1") -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: id,
            label: "Belastungs-EKG",
            measurementType: "PULSE",
            intervalDays: 90,
            rrule: nil,
            endsOn: Date(timeIntervalSince1970: 1_900_000_000),
            origin: .coach,
            notifyHour: 7,
            location: "Praxis Nord",
            nextDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSatisfiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            enabled: false,
            anchorDate: Date(timeIntervalSince1970: 1_600_000_000),
            snoozedUntil: Date(timeIntervalSince1970: 1_850_000_000),
            lastSkippedAt: Date(timeIntervalSince1970: 1_750_000_000),
            skipCount: 4
        )
    }

    /// **EXPECTED_RED (08-22): the store has no server-authoritative action or
    /// ledger surface, and it still rebuilds a reminder row field-by-field.**
    ///
    /// Compile-clean on purpose: it reads the store as *text* and probes the
    /// live instance through `Mirror`, so it states the absent surface without
    /// naming a symbol that does not exist yet. The typed behavioural cases that
    /// prove each path arrive with the implementation.
    @Test("08-22 marker: skip, snooze and the ledger have no store consumer")
    func storeHasNoServerAuthoritativeActionSurface() throws {
        let source = try Phase8SourceScan.stripped("HealthLog/Stores/MeasurementRemindersStore.swift")
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: StubAPIClient()))
        let properties = Set(Mirror(reflecting: store).children.compactMap(\.label))

        var violations: [String] = []
        if source.contains("MeasurementReminderRow(") {
            violations.append(
                "MeasurementRemindersStore rebuilds a MeasurementReminderRow field-by-field; "
                    + "a rebuild silently drops every field appended after it was written"
            )
        }
        for call in ["repo.skip(", "repo.snooze(", "repo.history("] where !source.contains(call) {
            violations.append("MeasurementRemindersStore never calls \(call)")
        }
        for property in ["ledgers", "pendingAction", "unsupportedActions"]
            where !properties.contains(where: { $0.contains(property) })
        {
            violations.append("MeasurementRemindersStore exposes no `\(property)` state")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: accepted reminder actions and history have no store consumer. PHASE8-VIOLATIONS 08-22-store: \(violations)"
        )
    }

    // MARK: - Nothing moves until the server says so

    /// The claim the whole non-optimistic design rests on, measured **while the
    /// request is still in flight** rather than inferred from the end state: the
    /// pre-call row is byte-identical across all sixteen server-owned fields, and
    /// the surface learns that something is happening from `pendingAction`
    /// instead of from a value nobody sent.
    @Test("in flight: the pre-call row keeps all sixteen fields and pendingAction carries the progress")
    func nothingMovesUntilTheServerAnswers() async {
        let api = StubAPIClient()
        let gate = ActionGate()
        let before = Self.fullyPopulatedRow()
        let canonical = Self.skippedRow()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [before] }
            await gate.markEntered()
            await gate.waitForRelease()
            return MeasurementReminderSkip(skipped: true, reminder: canonical)
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        let call = Task { await store.skip(id: "r1") }
        await gate.waitUntilEntered()

        let expected = Self.fieldsByName(of: before)
        let inFlight = Self.fieldsByName(of: store.reminders[0])
        #expect(
            Set(expected.keys) == Set(Self.serverOwnedFields),
            "the DTO grew a field this enumeration does not carry: \(Set(expected.keys).symmetricDifference(Self.serverOwnedFields))"
        )
        for field in Self.serverOwnedFields {
            #expect(inFlight[field] == expected[field], "an in-flight action moved \(field)")
        }
        #expect(store.pendingAction["r1"] == .skip)
        await gate.release()

        let outcome = await call.value
        #expect(outcome == .applied)
        #expect(store.reminders[0] == canonical)
        #expect(store.pendingAction.isEmpty)
        #expect(store.error == nil)
    }

    // MARK: - Skip

    @Test("skip reconciles from the canonical row and from nothing else")
    func skipTakesTheCanonicalRow() async {
        let store = await Self.loadedStore(answering: MeasurementReminderSkip(skipped: true, reminder: Self.skippedRow()))

        #expect(await store.skip(id: "r1") == .applied)

        #expect(store.reminders[0].skipCount == 5)
        #expect(store.reminders[0].lastSkippedAt == Date(timeIntervalSince1970: 1_860_000_000))
        #expect(store.reminders[0].snoozedUntil == nil, "the server clears the snooze on a skip")
        #expect(
            store.reminders[0].lastSatisfiedAt == Self.fullyPopulatedRow().lastSatisfiedAt,
            "a skip is not a completion"
        )
        #expect(store.error == nil)
    }

    /// `skipped == false` is the accepted route's forward-only no-op. It still
    /// carries the canonical row, so it is shown rather than apologised for.
    @Test("a forward-only no-op is an outcome, not a failure")
    func skipNoOpIsNotAFailure() async {
        let store = await Self.loadedStore(answering: MeasurementReminderSkip(skipped: false, reminder: Self.skippedRow()))

        #expect(await store.skip(id: "r1") == .noOp)

        #expect(store.reminders[0] == Self.skippedRow(), "the canonical row lands on a no-op too")
        #expect(store.error == nil)
    }

    @Test("a failed skip preserves every server-owned field and states the reason")
    func skipFailurePreservesTheRow() async {
        let before = Self.fullyPopulatedRow()
        let store = await Self.loadedStore(throwing: .server(status: 500, code: nil, message: "boom"))

        #expect(await store.skip(id: "r1") == .failed(.server(status: 500, code: nil, message: "boom")))

        let after = Self.fieldsByName(of: store.reminders[0])
        for field in Self.serverOwnedFields {
            #expect(after[field] == Self.fieldsByName(of: before)[field], "a failed skip moved \(field)")
        }
        #expect(store.error != nil)
        #expect(store.pendingAction.isEmpty)
    }

    /// The accepted descriptions put one refusal on all three routes: an
    /// appointment (encounter) reminder `404`s. The DTO publishes nothing that
    /// identifies one, so the capability is learned from the refusal — and then
    /// the affordance is withdrawn instead of raising an error the person cannot
    /// act on.
    @Test("a 404 withdraws the capability instead of raising an error")
    func refusedCapabilityIsWithdrawn() async {
        let before = Self.fullyPopulatedRow()
        let store = await Self.loadedStore(throwing: .server(status: 404, code: nil, message: "not found"))

        #expect(store.supports(.skip, id: "r1"))
        #expect(await store.skip(id: "r1") == .unsupported)

        #expect(!store.supports(.skip, id: "r1"))
        #expect(store.supports(.snooze, id: "r1"), "one refused route says nothing about the others")
        #expect(store.reminders[0] == before)
        #expect(store.error == nil, "a capability the deployment does not offer is not an error")
    }

    // MARK: - Snooze

    @Test("snooze sends the picked day verbatim and takes the canonical row")
    func snoozeSendsTheDayVerbatim() async {
        let api = StubAPIClient()
        let wire = WireLog()
        let snoozed = Self.snoozedRow()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [Self.fullyPopulatedRow()] }
            if let typed = request as? APIRequest<MeasurementReminderSnoozeResult> {
                await wire.record(path: typed.path, query: typed.query, body: typed.body)
            }
            return MeasurementReminderSnoozeResult(reminder: snoozed)
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        #expect(await store.snooze(id: "r1", until: "2026-08-25") == .applied)

        let bodies = await wire.bodies
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains(#""until":"2026-08-25""#) == true, "the picked day reaches the wire unreformatted")
        #expect(await wire.paths == ["/api/measurement-reminders/r1/snooze"])
        #expect(store.reminders[0].snoozedUntil == snoozed.snoozedUntil)
        #expect(store.reminders[0].nextDueAt == snoozed.snoozedUntil, "the server sets both to the same instant")
        #expect(store.reminders[0].lastSatisfiedAt == Self.fullyPopulatedRow().lastSatisfiedAt)
        #expect(store.reminders[0].skipCount == Self.fullyPopulatedRow().skipCount)
    }

    /// The published bounds (at least tomorrow, at most five years out) are the
    /// server's `422`. The store forwards the day and surfaces the refusal
    /// rather than pre-empting it with a rule of its own.
    @Test("a refused snooze day keeps the row and surfaces the server's reason")
    func snoozeRefusalKeepsTheRow() async {
        let before = Self.fullyPopulatedRow()
        let store = await Self.loadedStore(throwing: .server(status: 422, code: nil, message: "until must be at least tomorrow"))

        #expect(await store.snooze(id: "r1", until: "2020-01-01") == .failed(
            .server(status: 422, code: nil, message: "until must be at least tomorrow")
        ))

        #expect(store.reminders[0] == before)
        #expect(store.error?.userFacingDescription == "until must be at least tomorrow")
    }

    // MARK: - History

    @Test("history preserves the server's order and paginates on the server's own meta")
    func historyPreservesOrderAndPagination() async {
        let api = StubAPIClient()
        let wire = WireLog()
        let first = [Self.event(id: "e3", kind: .satisfied), Self.event(id: "e2", kind: .skipped)]
        let second = [Self.event(id: "e1", kind: .satisfied)]
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [Self.fullyPopulatedRow()] }
            guard let typed = request as? APIRequest<MeasurementReminderHistoryPage> else {
                throw HLError.unknown("unexpected request")
            }
            await wire.record(path: typed.path, query: typed.query, body: typed.body)
            let page = await wire.paths.count
            return MeasurementReminderHistoryPage(
                events: page == 1 ? first : second,
                meta: .init(total: 3, limit: 2, offset: page == 1 ? 0 : 2)
            )
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        await store.loadHistory(id: "r1")
        #expect(store.ledger(for: "r1").events.map(\.id) == ["e3", "e2"])
        #expect(store.ledger(for: "r1").meta == .init(total: 3, limit: 2, offset: 0))
        #expect(store.ledger(for: "r1").hasMore)
        #expect(await wire.queries == [""], "the first page sends neither limit nor offset — the route owns both defaults")

        await store.loadHistory(id: "r1")
        #expect(store.ledger(for: "r1").events.map(\.id) == ["e3", "e2", "e1"], "pages append in arrival order")
        #expect(!store.ledger(for: "r1").hasMore)
        #expect(await wire.queries == ["", "offset=2"], "the next page starts where the held rows end")
    }

    /// The ledger begins at the release that introduced it. A reminder that has
    /// been satisfied and skipped for years therefore answers `events: []` —
    /// and the store must say exactly that instead of reconstructing rows from
    /// `lastSatisfiedAt` / `lastSkippedAt` / `skipCount`, which it holds.
    @Test("an empty ledger is an answer and is never backfilled from the row")
    func emptyLedgerIsNeverBackfilled() async {
        let store = await Self.loadedStore(
            answering: MeasurementReminderHistoryPage(events: [], meta: .init(total: 0, limit: 50, offset: 0))
        )

        await store.loadHistory(id: "r1")

        let ledger = store.ledger(for: "r1")
        #expect(ledger.events.isEmpty)
        #expect(ledger.meta?.total == 0)
        #expect(ledger.isLoaded, "loaded-and-empty is not the same as never-asked")
        #expect(!ledger.isUnsupported)
        #expect(store.reminders[0].skipCount == 4, "the row still says four skips — the ledger simply predates them")
    }

    @Test("a refused ledger is unsupported, not empty")
    func historyRefusalIsUnsupported() async {
        let store = await Self.loadedStore(throwing: .server(status: 404, code: nil, message: "not found"))

        await store.loadHistory(id: "r1")

        let ledger = store.ledger(for: "r1")
        #expect(ledger.isUnsupported)
        #expect(!ledger.isLoaded)
        #expect(ledger.events.isEmpty)
        #expect(ledger.error == nil)
        #expect(!store.supports(.history, id: "r1"))
        #expect(store.error == nil)
    }

    @Test("a failed page keeps the pages already held and offers a retry")
    func failedPageKeepsWhatIsHeld() async {
        let api = StubAPIClient()
        let calls = CallCounter()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [Self.fullyPopulatedRow()] }
            if calls.bump() == 1 {
                return MeasurementReminderHistoryPage(
                    events: [Self.event(id: "e2", kind: .satisfied)],
                    meta: .init(total: 2, limit: 1, offset: 0)
                )
            }
            throw HLError.server(status: 500, code: nil, message: "boom")
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        await store.loadHistory(id: "r1")
        await store.loadHistory(id: "r1")

        let ledger = store.ledger(for: "r1")
        #expect(ledger.events.map(\.id) == ["e2"], "a short ledger with a retry is honest; an emptied one is not")
        #expect(ledger.error != nil)
        #expect(!ledger.isUnsupported)
        #expect(ledger.hasMore)
    }

    /// `limit` reaches the wire exactly as the caller wrote it. Clamping a 500
    /// into 100 would hide a refusal the contract puts on the server.
    @Test("the page window is forwarded verbatim and never clamped")
    func pageWindowIsNeverClamped() async {
        let api = StubAPIClient()
        let wire = WireLog()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [Self.fullyPopulatedRow()] }
            guard let typed = request as? APIRequest<MeasurementReminderHistoryPage> else {
                throw HLError.unknown("unexpected request")
            }
            await wire.record(path: typed.path, query: typed.query, body: typed.body)
            throw HLError.server(status: 422, code: nil, message: "limit must be between 1 and 100")
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        await store.loadHistory(id: "r1", limit: 500)

        #expect(await wire.queries == ["limit=500"], "a caller's window reaches the server unclamped")
        #expect(store.ledger(for: "r1").error != nil)
        #expect(!store.ledger(for: "r1").isUnsupported, "a 422 is a refused window, not a missing capability")
    }

    /// A skip writes a `SKIPPED` row server-side. An open ledger is therefore
    /// stale — so it is re-read authoritatively, never appended to locally.
    @Test("a successful action re-reads an open ledger authoritatively")
    func successfulActionReReadsAnOpenLedger() async {
        let api = StubAPIClient()
        let calls = CallCounter()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [Self.fullyPopulatedRow()] }
            if request is APIRequest<MeasurementReminderSkip> {
                return MeasurementReminderSkip(skipped: true, reminder: Self.skippedRow())
            }
            let page = calls.bump()
            return MeasurementReminderHistoryPage(
                events: page == 1
                    ? [Self.event(id: "e1", kind: .satisfied)]
                    : [Self.event(id: "e2", kind: .skipped), Self.event(id: "e1", kind: .satisfied)],
                meta: .init(total: page == 1 ? 1 : 2, limit: 50, offset: 0)
            )
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        await store.loadHistory(id: "r1")
        #expect(store.ledger(for: "r1").events.map(\.id) == ["e1"])

        #expect(await store.skip(id: "r1") == .applied)

        #expect(store.ledger(for: "r1").events.map(\.id) == ["e2", "e1"], "the new row came from the server, not from the skip call")
        #expect(store.ledger(for: "r1").meta?.total == 2)
    }

    /// Every ledger row is a dated fulfilment of a preventive-care reminder, so
    /// the ledger is PHI and drops with the rest of it.
    @Test("logout drops the ledger, the learned capabilities and any in-flight marker")
    func logoutDropsTheLedger() async {
        let store = await Self.loadedStore(
            answering: MeasurementReminderHistoryPage(
                events: [Self.event(id: "e1", kind: .satisfied)],
                meta: .init(total: 1, limit: 50, offset: 0)
            )
        )
        await store.loadHistory(id: "r1")
        #expect(!store.ledger(for: "r1").events.isEmpty)

        await store.clearOnLogout()

        #expect(store.reminders.isEmpty)
        #expect(store.ledgers.isEmpty)
        #expect(store.unsupportedActions.isEmpty)
        #expect(store.pendingAction.isEmpty)
    }

    // MARK: - Fixtures

    /// The canonical post-skip row: `skipCount` up by one, `lastSkippedAt`
    /// stamped, the snooze cleared, `lastSatisfiedAt` untouched.
    nonisolated static func skippedRow() -> MeasurementReminderRow {
        let base = fullyPopulatedRow()
        return MeasurementReminderRow(
            id: base.id,
            label: base.label,
            measurementType: base.measurementType,
            intervalDays: base.intervalDays,
            rrule: base.rrule,
            endsOn: base.endsOn,
            origin: base.origin,
            notifyHour: base.notifyHour,
            location: base.location,
            nextDueAt: Date(timeIntervalSince1970: 1_867_776_000),
            lastSatisfiedAt: base.lastSatisfiedAt,
            enabled: base.enabled,
            anchorDate: base.anchorDate,
            snoozedUntil: nil,
            lastSkippedAt: Date(timeIntervalSince1970: 1_860_000_000),
            skipCount: 5
        )
    }

    /// The canonical post-snooze row: `snoozedUntil` and `nextDueAt` are the
    /// same resolved instant and nothing else moved.
    nonisolated static func snoozedRow() -> MeasurementReminderRow {
        let base = fullyPopulatedRow()
        let resolved = Date(timeIntervalSince1970: 1_882_000_000)
        return MeasurementReminderRow(
            id: base.id,
            label: base.label,
            measurementType: base.measurementType,
            intervalDays: base.intervalDays,
            rrule: base.rrule,
            endsOn: base.endsOn,
            origin: base.origin,
            notifyHour: base.notifyHour,
            location: base.location,
            nextDueAt: resolved,
            lastSatisfiedAt: base.lastSatisfiedAt,
            enabled: base.enabled,
            anchorDate: base.anchorDate,
            snoozedUntil: resolved,
            lastSkippedAt: base.lastSkippedAt,
            skipCount: base.skipCount
        )
    }

    nonisolated static func event(id: String, kind: MeasurementReminderEventKind) -> MeasurementReminderEvent {
        MeasurementReminderEvent(
            id: id,
            kind: kind,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            onTime: kind == .satisfied,
            source: kind == .skipped ? .skip : .manual,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    /// Every stored property of a row, by name, rendered for comparison. The
    /// point is the enumeration: a field this dictionary does not carry is a
    /// field the preservation clauses never checked.
    nonisolated static func fieldsByName(of row: MeasurementReminderRow) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: row).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            }
        )
    }

    /// A store loaded with `fullyPopulatedRow()` whose every non-list request
    /// answers `payload`.
    static func loadedStore(answering payload: some Sendable) async -> MeasurementRemindersStore {
        let api = StubAPIClient()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [fullyPopulatedRow()] }
            return payload
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        return store
    }

    /// A store loaded with `fullyPopulatedRow()` whose every non-list request
    /// throws `failure`.
    static func loadedStore(throwing failure: HLError) async -> MeasurementRemindersStore {
        let api = StubAPIClient()
        await api.setHandler { request in
            if request is APIRequest<[MeasurementReminderRow]> { return [fullyPopulatedRow()] }
            throw failure
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        return store
    }
}

/// Lets a test observe the store **while a request is still in flight**, which
/// is the only place "nothing was optimistically mutated" is actually visible.
/// The handler parks inside the gate; the test reads the store, then releases it.
private actor ActionGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        for waiter in enteredWaiters {
            waiter.resume()
        }
        enteredWaiters = []
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters = []
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// Endpoint-scoped request log — the shape 08-19 introduced beside the older
/// unguarded one, because `MockURLProtocol`-style process-global bookkeeping
/// picks up a parallel suite's traffic. Here the caller records only the
/// requests it typed for, so nothing else can land in an assertion.
private actor WireLog {
    private(set) var paths: [String] = []
    /// The query as it reaches the wire, joined — tuples are not `Equatable`, and
    /// `"limit=500"` is the thing the assertion is actually about.
    private(set) var queries: [String] = []
    private(set) var bodies: [String] = []

    func record(path: String, query: [(String, String)], body: Data?) {
        paths.append(path)
        queries.append(query.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))
        bodies.append(body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}

/// Counts handler invocations so a scripted multi-page / multi-call scenario can
/// answer differently each time. The closure runs on the API actor and this is
/// only touched inside it.
private final class CallCounter: @unchecked Sendable {
    private var count = 0

    func bump() -> Int {
        count += 1
        return count
    }
}
