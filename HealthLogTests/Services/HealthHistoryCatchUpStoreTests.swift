import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// "Sync everything now" on the settings surface, and the
/// state rules the split runs on.
@Suite("History catch-up store and split state")
@MainActor
struct HealthHistoryCatchUpStoreTests {
    private static func status(
        _ type: String,
        reachedBack: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        complete: Bool = false,
        legacy: Bool = false
    ) -> HealthSampleHistoryStatus {
        HealthSampleHistoryStatus(
            typeIdentifier: type,
            reachedBack: reachedBack,
            isComplete: complete,
            legacyPending: legacy,
            liveCaughtUp: true
        )
    }

    @Test("a run keeps the screen awake, publishes every round, and lets go when it ends")
    func runPublishesAndReleases() async {
        let awake = Mutex<[Bool]>([])
        let rounds = [
            HealthHistoryOverview(types: [Self.status("a"), Self.status("b", complete: true)]),
            HealthHistoryOverview(types: [Self.status("a", complete: true), Self.status("b", complete: true)])
        ]
        let store = HealthHistoryCatchUpStore(
            overviewSource: { nil },
            catchUp: { progress in
                for round in rounds {
                    await progress(round)
                }
                return .finished
            },
            keepAwake: { value in awake.withLock { $0.append(value) } }
        )

        let task = store.start()
        #expect(store.isRunning)
        await task?.value

        #expect(store.phase == .finished)
        #expect(store.overview == rounds.last)
        #expect(awake.withLock { $0 } == [true, false])
    }

    @Test("a second start while running is the same run")
    func startIsSingleFlight() async {
        let calls = Mutex(0)
        let gate = AsyncStream<Void>.makeStream()
        let store = HealthHistoryCatchUpStore(
            overviewSource: { nil },
            catchUp: { _ in
                calls.withLock { $0 += 1 }
                for await _ in gate.stream {}
                return .cancelled
            },
            keepAwake: { _ in }
        )

        let first = store.start()
        let second = store.start()
        gate.continuation.finish()
        await first?.value
        await second?.value

        #expect(calls.withLock { $0 } == 1)
        #expect(store.phase == .cancelled)
    }

    @Test("stalled and signed-out runs end in their own phase")
    func endPhases() async {
        for (outcome, phase) in [
            (HealthHistoryCatchUpOutcome.stalled, HealthHistoryCatchUpStore.Phase.stalled),
            (.notAdmitted, .unavailable)
        ] {
            let store = HealthHistoryCatchUpStore(overviewSource: { nil }, catchUp: { _ in outcome }, keepAwake: { _ in })
            await store.start()?.value
            #expect(store.phase == phase)
        }
    }

    @Test("a refresh reads the overview, but not over a running catch-up")
    func refreshReadsOverview() async {
        let overview = HealthHistoryOverview(types: [Self.status("a", complete: true)])
        let store = HealthHistoryCatchUpStore(overviewSource: { overview }, catchUp: { _ in .finished }, keepAwake: { _ in })
        await store.refresh()
        #expect(store.overview == overview)
        #expect(overview.isFinished)
        #expect(!HealthHistoryOverview(types: []).isFinished)
    }

    @Test("a metric row is complete only when every HealthKit type behind it is")
    func kindRowsFold() {
        let systolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
        let diastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
        let early = Date(timeIntervalSince1970: 1_600_000_000)
        let late = Date(timeIntervalSince1970: 1_700_000_000)

        let partly = HistoryKindRow.rows(HealthHistoryOverview(types: [
            Self.status(systolic, reachedBack: early, complete: true),
            Self.status(diastolic, reachedBack: late)
        ]))
        #expect(partly.count == 1)
        #expect(partly.first?.state == .reachedBack(late))

        let finishing = HistoryKindRow(kind: .bloodPressure, statuses: [
            Self.status(systolic, complete: true, legacy: true),
            Self.status(diastolic, complete: true)
        ])
        #expect(finishing.state == .finishing)

        let fresh = HistoryKindRow(kind: .bloodPressure, statuses: [Self.status(systolic, reachedBack: nil)])
        #expect(fresh.state == .notStarted)

        let done = HistoryKindRow(kind: .bloodPressure, statuses: [Self.status(systolic, complete: true)])
        #expect(done.state == .complete)
    }

    // MARK: - Split state rules

    private static func state(
        liveStart: Date,
        historyEnd: Date,
        inclusive: Bool = false,
        replayFloor: Date? = nil,
        resolved: Bool = true,
        legacy: Bool = false,
        fullCatchUp: Bool = false
    ) -> HealthSampleSplitState {
        HealthSampleSplitState(
            version: HealthSampleSplitState.formatVersion,
            origin: legacy ? .upgrade : .fresh,
            liveStart: liveStart,
            liveCaughtUp: true,
            historyEnd: historyEnd,
            historyEndInclusive: inclusive,
            replayFloor: replayFloor,
            replayFloorResolved: resolved,
            legacyLegActive: legacy,
            fullCatchUp: fullCatchUp,
            updatedAt: liveStart
        )
    }

    @Test("the floor is the window, raised by the replay shortcut, never above the live start")
    func floorRules() {
        let live = Date(timeIntervalSince1970: 2_000_000)
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let replay = Date(timeIntervalSince1970: 1_500_000)

        #expect(Self.state(liveStart: live, historyEnd: live).historyFloor(cutoff: cutoff) == cutoff)
        #expect(Self.state(liveStart: live, historyEnd: live, replayFloor: replay).historyFloor(cutoff: cutoff) == replay)
        #expect(Self.state(liveStart: live, historyEnd: live, replayFloor: replay, fullCatchUp: true)
            .historyFloor(cutoff: cutoff) == cutoff)
        #expect(Self.state(liveStart: live, historyEnd: live, replayFloor: live.addingTimeInterval(99))
            .historyFloor(cutoff: cutoff) == live)
    }

    @Test("complete means everything from the floor up, including the floor instant")
    func completionRules() {
        let live = Date(timeIntervalSince1970: 2_000_000)
        let floor = Date(timeIntervalSince1970: 1_000_000)
        #expect(Self.state(liveStart: live, historyEnd: floor).isHistoryComplete(cutoff: floor))
        #expect(!Self.state(liveStart: live, historyEnd: floor, inclusive: true).isHistoryComplete(cutoff: floor))
        #expect(!Self.state(liveStart: live, historyEnd: live).isHistoryComplete(cutoff: floor))
        #expect(Self.state(liveStart: live, historyEnd: .distantPast).isHistoryComplete(cutoff: .distantPast))
    }

    @Test("the legacy leg owes exactly the dates below the floor, and nothing once the walk reaches the window")
    func legacyWindowRules() {
        let live = Date(timeIntervalSince1970: 2_000_000)
        let replay = Date(timeIntervalSince1970: 1_500_000)
        let upgrade = Self.state(liveStart: live, historyEnd: replay, replayFloor: replay, legacy: true)

        #expect(upgrade.legacyWindow(cutoff: .distantPast) == HealthSampleDateWindow(start: nil, end: replay))
        #expect(Self.state(liveStart: live, historyEnd: live, replayFloor: replay, legacy: true, fullCatchUp: true)
            .legacyWindow(cutoff: .distantPast) == nil)
        #expect(Self.state(liveStart: live, historyEnd: live, legacy: true).legacyWindow(cutoff: .distantPast) == nil)
        #expect(!Self.state(liveStart: live, historyEnd: live, resolved: false, legacy: true).historyMayRun)
        #expect(Self.state(liveStart: live, historyEnd: live, resolved: false, legacy: true, fullCatchUp: true).historyMayRun)
    }

    @Test("a date window includes its start and excludes its end unless told otherwise")
    func windowBounds() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let open = HealthSampleDateWindow(start: start, end: end)
        #expect(open.contains(start))
        #expect(!open.contains(end))
        #expect(HealthSampleDateWindow(start: start, end: end, endInclusive: true).contains(end))
        #expect(HealthSampleDateWindow().contains(.distantPast))
    }
}
