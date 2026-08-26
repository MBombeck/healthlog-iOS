import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **Plan 08-22 — the honesty contract for the Vorsorge completion ledger.**
///
/// The reminder surfaces gained a history in v1.37.20, and the failure mode this
/// suite exists to prevent is not a crash: it is a plausible-looking ledger that
/// nobody sent. The reminder row already carries `lastSatisfiedAt`,
/// `lastSkippedAt` and `skipCount`, so a surface that wants to look complete can
/// reconstruct a "history" out of them without ever calling the route — and it
/// would be wrong in the one way a user could never check.
///
/// So every clause here is about provenance rather than appearance: entries come
/// from server events and from nothing else, the order is the server's, the page
/// window is the server's, an unrecognised value is rendered rather than dropped,
/// and the three ways a ledger can be *absent* stay three different sentences.
@Suite("Vorsorge reminder history")
struct VorsorgeReminderHistoryTests {
    // MARK: - The marker this plan closes

    /// **EXPECTED_RED (08-22): the accepted ledger and actions have no user-
    /// visible consumer.** Reads the four reminder surfaces as comment-stripped
    /// text, so it states what is missing without naming a symbol that does not
    /// exist yet.
    @Test("08-22 marker: no reminder surface offers the accepted actions or ledger")
    func reminderSurfacesHaveNoServerLedger() throws {
        let sheet = try Phase8SourceScan.stripped(Self.detailSheet)
        let model = try Phase8SourceScan.stripped(Self.cardModel)
        let screen = try Phase8SourceScan.stripped(Self.screen)
        // 17-02 — the accepted cycle actions moved out of the sheet into their
        // own type so the TILE can mount the same implementation (G2). The
        // clauses below follow them; „the sheet offers skip" is still asserted,
        // it is just asserted where the code now lives.
        let actions = try Phase8SourceScan.stripped(Self.ledgerActions)

        var violations: [String] = []
        if !sheet.contains("VorsorgeReminderLedgerActions") {
            violations.append("VorsorgeReminderDetailSheet no longer mounts the accepted cycle actions")
        }
        if !actions.contains("vorsorge.action.skip") {
            violations.append("the ledger actions offer no skip affordance")
        }
        if !actions.contains("vorsorge.action.snooze") {
            violations.append("the ledger actions offer no snooze affordance")
        }
        if !sheet.contains("ledgerState") {
            violations.append("VorsorgeReminderDetailSheet renders no completion ledger")
        }
        if !model.contains("LedgerEntry") {
            violations.append("VorsorgeCard has no ledger presentation seam")
        }
        if !model.contains("isSnoozed") {
            violations.append("VorsorgeCard never reads the server snooze cursor")
        }
        if !screen.contains("snooz") {
            violations.append("the reminder card shows neither the snooze cursor nor the skip count")
        }
        // Deliberately NOT a clause about the card's doc comment, which still
        // claims the server has no completion ledger: `stripped(_:)` removes
        // every comment, so such a clause could never fire. The comment is
        // corrected anyway; what is *asserted* is code.
        //
        // 17-02 (G1) — the clause that used to stand here read
        // „VorsorgeAdherenceSummaryCard reports no snoozed count". Its subject
        // was deleted on the operator's statement, so the clause is REPLACED
        // rather than dropped: what 08-22 was really pinning is that the
        // accepted actions have a user-visible consumer, and the strongest
        // statement of that is now the tile, where the operator expects to reach
        // them (G2). Deleting the clause outright would have quietly lowered the
        // bar this marker sets.
        if !screen.contains("VorsorgeReminderLedgerActions") {
            violations.append("the reminder TILE offers neither skip nor snooze — sheet-only was never the ask")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: accepted reminder actions and history have no user-visible consumer. PHASE8-VIOLATIONS 08-22-ui: \(violations)"
        )
    }

    // MARK: - Provenance: entries come from events, and only from events

    /// The mapping is one entry per server event, in the order the events came,
    /// with the server's own punctuality flag. Nothing is sorted here.
    @Test("entries are the server's events, in the server's order")
    func entriesAreTheServersEvents() {
        let ledger = Self.ledger(
            events: [
                Self.event(id: "e3", kind: .skipped, source: .skip, onTime: false),
                Self.event(id: "e2", kind: .satisfied, source: .autoMeasurement, onTime: true),
                Self.event(id: "e1", kind: .satisfied, source: .manual, onTime: false)
            ],
            total: 3
        )

        guard case let .loaded(entries, hasMore) = VorsorgeCard.ledgerState(ledger) else {
            Issue.record("expected a loaded ledger")
            return
        }

        #expect(entries.map(\.id) == ["e3", "e2", "e1"], "the order is the server's, newest first")
        #expect(entries.map(\.kindKey) == [
            "vorsorge.history.kind.skipped",
            "vorsorge.history.kind.satisfied",
            "vorsorge.history.kind.satisfied"
        ])
        #expect(entries.map(\.sourceKey) == [
            "vorsorge.history.source.skip",
            "vorsorge.history.source.autoMeasurement",
            "vorsorge.history.source.manual"
        ])
        #expect(entries.map(\.punctualityKey) == [
            "vorsorge.history.late",
            "vorsorge.history.onTime",
            "vorsorge.history.late"
        ], "onTime is the server's flag, derived at write time and never re-derived")
        #expect(!hasMore)
    }

    /// The accepted contract says the `source` set will widen. A row whose kind
    /// or source the client has never seen is rendered with a neutral label
    /// **and** the raw token, because dropping it is a hole in a history the
    /// person has no other way to see.
    @Test("an unknown kind or source is rendered with its raw token, never dropped")
    func unknownValuesAreRendered() {
        let ledger = Self.ledger(
            events: [
                Self.event(id: "e2", kind: .satisfied, source: .unknown("insurance_portal"), onTime: true),
                Self.event(id: "e1", kind: .unknown("EXPIRED"), source: .manual, onTime: true)
            ],
            total: 2
        )

        guard case let .loaded(entries, _) = VorsorgeCard.ledgerState(ledger) else {
            Issue.record("expected a loaded ledger")
            return
        }

        #expect(entries.count == 2, "no row was filtered out over a value the client does not know")
        #expect(entries[0].sourceKey == "vorsorge.history.source.unknown")
        #expect(entries[0].unknownWireValue == "insurance_portal")
        #expect(entries[1].kindKey == "vorsorge.history.kind.unknown")
        #expect(entries[1].unknownWireValue == "EXPIRED", "kind wins when both are unknown")
    }

    // MARK: - The three ways a ledger can be absent

    /// Not asked, not offered, and honestly empty are three different sentences.
    /// Collapsing them is how "no history yet" ends up under a reminder whose
    /// history was never requested — or never available at all.
    @Test("never-asked, not-offered and honestly-empty stay three different answers")
    func absenceHasThreeDistinctAnswers() {
        #expect(VorsorgeCard.ledgerState(MeasurementReminderLedger()) == .loading)

        var loading = MeasurementReminderLedger()
        loading.isLoading = true
        #expect(VorsorgeCard.ledgerState(loading) == .loading)

        var unsupported = MeasurementReminderLedger()
        unsupported.isUnsupported = true
        #expect(VorsorgeCard.ledgerState(unsupported) == .unsupported)

        #expect(VorsorgeCard.ledgerState(Self.ledger(events: [], total: 0)) == .empty)
    }

    /// The reminder row carries `lastSatisfiedAt`, `lastSkippedAt` and a
    /// `skipCount` of four. An empty ledger next to it is still empty: the
    /// ledger begins at the release that introduced it and cannot be backfilled.
    @Test("an empty ledger is never backfilled from the reminder's own timestamps")
    func emptyLedgerIsNotBackfilled() {
        let state = VorsorgeCard.ledgerState(Self.ledger(events: [], total: 0))

        #expect(state == .empty)
        // The seam takes the ledger and NOT the row, which is what makes the
        // clause above structural rather than a promise: there is no row here to
        // borrow a timestamp from.
        #expect(VorsorgeCard.hasSkippedCurrentCycle(Self.skippedRow()), "the row itself does say a cycle was skipped")
    }

    @Test("a failed page keeps what was accepted and still offers the rest")
    func failedPageKeepsWhatWasAccepted() {
        var ledger = Self.ledger(events: [Self.event(id: "e1", kind: .satisfied, source: .manual, onTime: true)], total: 5)
        ledger.error = .server(status: 500, code: nil, message: "boom")

        guard case let .failed(entries, hasMore) = VorsorgeCard.ledgerState(ledger) else {
            Issue.record("expected a failed ledger")
            return
        }

        #expect(entries.map(\.id) == ["e1"])
        #expect(hasMore, "hasMore is the server's total against what is held, not a guess")
    }

    @Test("pagination is the server's total, not a page-size heuristic")
    func paginationComesFromServerTotals() {
        let one = Self.ledger(events: [Self.event(id: "e1", kind: .satisfied, source: .manual, onTime: true)], total: 9)
        #expect(one.hasMore)
        #expect(one.nextOffset == 1)

        let all = Self.ledger(events: [Self.event(id: "e1", kind: .satisfied, source: .manual, onTime: true)], total: 1)
        #expect(!all.hasMore)
    }

    // MARK: - The two derived states are clock comparisons

    @Test("snoozed is snoozedUntil > now, and nothing else")
    func snoozedIsAClockComparison() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(VorsorgeCard.isSnoozed(Self.row(snoozedUntil: now.addingTimeInterval(60)), now: now))
        #expect(!VorsorgeCard.isSnoozed(Self.row(snoozedUntil: now.addingTimeInterval(-60)), now: now))
        #expect(!VorsorgeCard.isSnoozed(Self.row(snoozedUntil: nil), now: now))
    }

    @Test("a skipped cycle is lastSkippedAt > lastSatisfiedAt")
    func skippedCycleIsAClockComparison() {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(VorsorgeCard.hasSkippedCurrentCycle(Self.row(lastSatisfiedAt: early, lastSkippedAt: late)))
        #expect(!VorsorgeCard.hasSkippedCurrentCycle(Self.row(lastSatisfiedAt: late, lastSkippedAt: early)))
        #expect(
            VorsorgeCard.hasSkippedCurrentCycle(Self.row(lastSatisfiedAt: nil, lastSkippedAt: early)),
            "a skip with nothing to be older than still skipped the cycle"
        )
        #expect(!VorsorgeCard.hasSkippedCurrentCycle(Self.row(lastSatisfiedAt: late, lastSkippedAt: nil)))
    }

    // MARK: - No fabrication, asserted against the production source

    /// The structural half of the honesty claim: the surfaces that render the
    /// ledger never construct a ledger row, and the seam that maps one takes the
    /// ledger rather than the reminder — so there is nothing to borrow from.
    @Test("no reminder surface constructs a ledger row or reads the reminder's own timestamps")
    func noSurfaceSynthesizesALedgerRow() throws {
        let sheet = try Phase8SourceScan.stripped(Self.detailSheet)
        let model = try Phase8SourceScan.stripped(Self.cardModel)

        var violations: [String] = []
        for (name, source) in [("VorsorgeReminderDetailSheet", sheet), ("VorsorgeCardModel", model)] {
            for constructor in ["MeasurementReminderEvent(", "MeasurementReminderHistoryPage("]
                where source.contains(constructor)
            {
                violations.append("\(name) constructs \(constructor) — a ledger row nobody sent")
            }
        }

        let seam = Phase8SourceScan.member(named: "static func ledgerState(", in: model)
        if let seam {
            for borrowed in ["lastSatisfiedAt", "lastSkippedAt", "skipCount", "MeasurementReminderRow"]
                where seam.contains(borrowed)
            {
                violations.append("ledgerState reads the reminder's own \(borrowed)")
            }
        } else {
            violations.append("ledgerState is absent — restate this contract rather than treating it as satisfied")
        }

        let section = Phase8SourceScan.member(named: "private struct VorsorgeReminderLedgerSection", in: sheet)
        if let section {
            for borrowed in ["lastSatisfiedAt", "lastSkippedAt", "skipCount"] where section.contains(borrowed) {
                violations.append("the ledger section reads the reminder's own \(borrowed)")
            }
        } else {
            violations.append("VorsorgeReminderLedgerSection is absent")
        }

        #expect(violations.isEmpty, "PHASE8-VIOLATIONS 08-22-fabrication: \(violations)")
    }

    /// The published `limit` bounds and the `422` they carry stay the server's.
    /// A clamp anywhere in the reminder path would hide a refusal the contract
    /// deliberately placed on the far side.
    @Test("the published page window is exported, and nothing clamps against it")
    func pageWindowStaysTheServers() throws {
        #expect(MeasurementReminderHistoryPage.defaultLimit == 50)
        #expect(MeasurementReminderHistoryPage.limitRange == 1 ... 100)

        let repository = try Phase8SourceScan.stripped("HealthLog/Repositories/MeasurementReminderRepository.swift")
        let store = try Phase8SourceScan.stripped("HealthLog/Stores/MeasurementRemindersStore.swift")
        for source in [repository, store] {
            #expect(!source.contains("limitRange.clamped"))
            #expect(!source.contains("min(limit"))
            #expect(!source.contains("max(limit"))
        }
    }

    // MARK: - Fixtures

    static func ledger(events: [MeasurementReminderEvent], total: Int) -> MeasurementReminderLedger {
        var ledger = MeasurementReminderLedger()
        ledger.events = events
        ledger.meta = .init(total: total, limit: 50, offset: 0)
        return ledger
    }

    static func event(
        id: String,
        kind: MeasurementReminderEventKind,
        source: MeasurementReminderEventSource,
        onTime: Bool
    ) -> MeasurementReminderEvent {
        MeasurementReminderEvent(
            id: id,
            kind: kind,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            onTime: onTime,
            source: source,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    static func row(
        lastSatisfiedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        lastSkippedAt: Date? = nil,
        skipCount: Int = 0
    ) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "r1",
            label: "Zahnkontrolle",
            measurementType: nil,
            intervalDays: 180,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSatisfiedAt: lastSatisfiedAt,
            enabled: true,
            snoozedUntil: snoozedUntil,
            lastSkippedAt: lastSkippedAt,
            skipCount: skipCount
        )
    }

    static func skippedRow() -> MeasurementReminderRow {
        row(
            lastSatisfiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSkippedAt: Date(timeIntervalSince1970: 1_750_000_000),
            skipCount: 4
        )
    }

    // MARK: - Sources under contract

    static let detailSheet = "HealthLog/Screens/Notifications/VorsorgeReminderDetailSheet.swift"
    static let cardModel = "HealthLog/Screens/Notifications/VorsorgeCardModel.swift"
    static let screen = "HealthLog/Screens/Notifications/MeasurementRemindersScreen.swift"
    static let ledgerActions = "HealthLog/Screens/Notifications/VorsorgeReminderLedgerActions.swift"
}
