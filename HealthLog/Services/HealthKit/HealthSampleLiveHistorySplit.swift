import Foundation

// 1.3.0 (#127, #128, HealthLog#1204, public #25) — live and history, split per
// type.
//
// Up to 1.2.0 one anchored cursor per {owner, source, type} carried both the
// history walk and live delivery. A first walk read HealthKit in insertion
// order, which in practice is oldest first, 500 samples a page, one page per
// short wake. Last night's sleep therefore waited behind years of older nights,
// and an observer wake spent its single page on the next 500 old samples.
//
// Each partition now has three legs:
//
//   * **Live.** The partition's main cursor (`HealthSyncCursorKey.storageKey`).
//     Its first read is narrowed to `liveStart` (now minus two days, never
//     before the chosen window), and every trigger serves it first. Once a page
//     comes back short the stream has reached the present, the narrowing is
//     dropped, and from then on it carries everything HealthKit inserts, of
//     any date.
//   * **History.** A date cursor that walks backwards from `liveStart`, newest
//     first, and persists how far back it has reached. It runs only in the
//     budget left after every live stream, and only once this type's live
//     stream has reached the present, so nothing inserted meanwhile can fall
//     between the two.
//   * **Legacy (upgrades only).** A 1.2.0 installation's forward cursor, moved
//     aside on the first 1.3.0 pass. When the server says how far it already
//     holds a type (`metricFreshness[].lastSeenAt`), the history walk stops at
//     that point minus seven days (#128) and the legacy cursor finishes the
//     dates below it, narrowed to exactly those dates. It retires the first
//     time it comes back short.
//
// The server folds every re-sent sample on `(userId, type, source, externalId)`
// and answers `duplicate`, so overlap between the legs costs a request and is
// never a second row. A gap would be a lost row, so every rule here errs
// towards overlap.

/// The persisted live/history state of one partition, stored beside the
/// partition's cursor (`<storageKey>.split`). Dates and flags only: no anchor,
/// no value, no owner.
struct HealthSampleSplitState: Codable, Sendable, Equatable {
    static let formatVersion = 1

    enum Origin: String, Codable, Sendable {
        /// No cursor existed when the split was established.
        case fresh
        /// A 1.2.0 forward cursor existed and was moved to the legacy leg.
        case upgrade
    }

    let version: Int
    let origin: Origin
    /// Lower bound of the live stream's first read. Fixed at establishment.
    let liveStart: Date
    /// `true` once a live page came back short: the stream has reached the
    /// present and reads without a date narrowing from then on.
    var liveCaughtUp: Bool
    /// How far back the history walk has reached. Everything with a start date
    /// in `[historyEnd, liveStart)` (or `(historyEnd, liveStart)` while
    /// `historyEndInclusive`) has been handed to the server.
    var historyEnd: Date
    /// `true` when samples starting exactly at `historyEnd` still need reading
    /// (the last page ended in the middle of that instant).
    var historyEndInclusive: Bool
    /// #128 — `lastSeenAt` minus the safety margin for an upgraded partition,
    /// once resolved. `nil` = no shortcut, the walk goes to the chosen window.
    var replayFloor: Date?
    /// `false` while an upgraded partition still waits for the server's
    /// answer. History and legacy wait with it; live never does.
    var replayFloorResolved: Bool
    /// The legacy forward cursor still owes the dates below the replay floor.
    var legacyLegActive: Bool
    /// "Sync everything now" (public #25): walk to the chosen window, ignore
    /// the replay shortcut.
    var fullCatchUp: Bool
    var updatedAt: Date
    /// 1.4 (S1) — the lower bound of the chosen window, pinned once for this
    /// partition. 1.3.0 recomputed it from "now" on every pass, so it moved
    /// forward while the walk moved back, and the two met before the oldest
    /// part of the window was read. `nil` in a state 1.3.0 wrote and while no
    /// window is chosen; ``DurableHealthCursorStore/establishSplit`` pins it.
    var windowFloor: Date?

    /// The window's lower bound for this partition: the pinned one, never
    /// later than the bound the caller passes. "Alle" (and no choice yet)
    /// arrives as `.distantPast` and stays unbounded.
    func windowStart(cutoff: Date) -> Date {
        guard cutoff != .distantPast, let windowFloor else { return cutoff }
        return min(windowFloor, cutoff)
    }

    /// The lowest start date the history walk has to reach.
    func historyFloor(cutoff: Date) -> Date {
        let window = windowStart(cutoff: cutoff)
        var floor = window
        if !fullCatchUp, let replayFloor, replayFloor > window {
            floor = replayFloor
        }
        return min(floor, liveStart)
    }

    /// Whether everything from the floor up to `liveStart` has been read.
    func isHistoryComplete(cutoff: Date) -> Bool {
        isHistoryComplete(cutoff: cutoff, readable: .unlimited)
    }

    /// **B5 (1.4, R4 2.1)** — the lowest start date the walk can reach when
    /// Apple Health shares only a recent window: never below the boundary of
    /// that window. Everything older is unknown, not absent, so the walk stops
    /// there and keeps `historyEnd` at the boundary; widened access later
    /// resumes it from exactly that point.
    func readableHistoryFloor(cutoff: Date, readable: HealthReadWindow) -> Date {
        let floor = historyFloor(cutoff: cutoff)
        guard case let .limited(from) = readable, from > floor else { return floor }
        return min(from, liveStart)
    }

    /// Whether everything readable from the floor up to `liveStart` has been
    /// read. With full access that is ``isHistoryComplete(cutoff:)``.
    func isHistoryComplete(cutoff: Date, readable: HealthReadWindow) -> Bool {
        let floor = readableHistoryFloor(cutoff: cutoff, readable: readable)
        return historyEnd < floor || (historyEnd == floor && !historyEndInclusive)
    }

    /// The dates the legacy leg still owes, or `nil` when it owes none.
    func legacyWindow(cutoff: Date) -> HealthSampleDateWindow? {
        guard legacyLegActive else { return nil }
        let window = windowStart(cutoff: cutoff)
        let floor = historyFloor(cutoff: cutoff)
        guard floor > window else { return nil }
        return HealthSampleDateWindow(start: window == .distantPast ? nil : window, end: floor, endInclusive: false)
    }

    /// History may run: the live stream reached the present and, for an
    /// upgrade, the replay floor is known (or no longer matters).
    var historyMayRun: Bool {
        liveCaughtUp && (replayFloorResolved || fullCatchUp)
    }
}

/// A start-date window for a HealthKit read. `start` is inclusive; `end` is
/// exclusive unless `endInclusive`. `nil` on either side means unbounded.
struct HealthSampleDateWindow: Sendable, Equatable {
    var start: Date?
    var end: Date?
    var endInclusive = false

    func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let end {
            return endInclusive ? date <= end : date < end
        }
        return true
    }
}

/// The numbers the split runs on.
enum HealthSampleSplitPolicy {
    /// How far before "now" a new live stream starts. Two days: last night's
    /// sleep, yesterday's readings, and a watch that synced late.
    static let liveLookback: TimeInterval = 2 * 86400
    /// #128 — how far below the server's newest stored reading an upgraded
    /// partition's history walk reaches. Generous on purpose: the server folds
    /// anything re-sent.
    static let replayMargin: TimeInterval = 7 * 86400
    /// A history run older than this is presumed dead (a HealthKit callback
    /// that never returned) and no longer blocks the next one.
    static let staleHistoryRun: TimeInterval = 300

    static func liveStart(now: Date, cutoff: Date) -> Date {
        max(cutoff, now.addingTimeInterval(-liveLookback))
    }

    static func replayFloor(lastSeenAt: Date?) -> Date? {
        lastSeenAt.map { $0.addingTimeInterval(-replayMargin) }
    }

    /// 1.4 (S1) — a leap day and a daylight-saving hour: how far a window
    /// bound reconstructed by ``pinnedWindowFloor(cutoff:liveStart:now:)``
    /// can be off. Applied towards overlap.
    static let windowPinMargin: TimeInterval = 25 * 3600

    /// The window bound a partition without a pin was established under. A
    /// chosen window is a fixed span of calendar days, so its bound stood as
    /// much earlier as the partition is old, and the partition was
    /// established `liveLookback` after its `liveStart`.
    static func pinnedWindowFloor(cutoff: Date, liveStart: Date, now: Date) -> Date {
        let age = max(0, now.timeIntervalSince(liveStart.addingTimeInterval(liveLookback)))
        return cutoff.addingTimeInterval(-(age + windowPinMargin))
    }

    /// A2 (1.4, R3 3.2) — history pages in a row that came back as nothing
    /// but `folded_window` duplicates before a type's walk stops. One page can
    /// straddle the fold boundary; three in a row (1 500 samples) cannot.
    static let foldedPagesBeforeStop = 3

    /// A2 (1.4, R-A8) — whether the statistics path owns a type's history:
    /// the summed types travel as day and hour totals (`stats:` rows) while
    /// the daily-statistics switch is on, and the per-sample gate drops every
    /// raw row of them, so walking their raw history sends nothing.
    static func historyOwnedByStatistics(_ typeIdentifier: String, dailyStatsEnabled: Bool) -> Bool {
        dailyStatsEnabled && HealthKitCumulativeTypeConfig.cumulativeIdentifiers.contains(typeIdentifier)
    }
}

/// Wall clock for the live start and a monotonic clock for the history budget.
struct HealthSampleSplitClock: Sendable {
    let now: @Sendable () -> Date
    let uptime: @Sendable () -> TimeInterval

    static let live = Self(
        now: { Date() },
        uptime: { ProcessInfo.processInfo.systemUptime }
    )
}

/// How much history one pass may walk, in the budget the live streams left.
struct HealthSampleHistoryBudget: Sendable, Equatable {
    let pagesPerType: Int
    let timeBudget: TimeInterval

    static let none = Self(pagesPerType: 0, timeBudget: 0)

    /// One round of "Sync everything now": more pages per type, still a
    /// bounded round so progress is published between rounds.
    static let fullCatchUpRound = Self(pagesPerType: 40, timeBudget: 25)

    static func required(for budget: HealthSyncBudget) -> Self {
        Self(pagesPerType: budget.historyPagesPerType, timeBudget: budget.historyTimeBudget)
    }
}

/// Per-type history state for Sync Diagnostics and the catch-up progress.
struct HealthSampleHistoryStatus: Sendable, Equatable {
    let typeIdentifier: String
    /// `nil` before the type's first 1.3 pass.
    let reachedBack: Date?
    let isComplete: Bool
    /// An upgraded partition's legacy leg still owes older dates.
    let legacyPending: Bool
    let liveCaughtUp: Bool

    /// Done means nothing is owed by any leg.
    var isFinished: Bool {
        isComplete && !legacyPending
    }
}

/// 1.3 (#127, public #25) — what the history walk has reached, for the
/// account that is signed in. Dates and counts only.
struct HealthHistoryOverview: Sendable, Equatable {
    let types: [HealthSampleHistoryStatus]
    /// B5 (1.4, R4 2.1) — the earliest date Apple Health shares when it shares
    /// only a recent window with HealthLog, `nil` with full access. The walk
    /// counts as done at that date; Sync Diagnostics says so in one line.
    var limitedFrom: Date?

    init(types: [HealthSampleHistoryStatus], limitedFrom: Date? = nil) {
        self.types = types
        self.limitedFrom = limitedFrom
    }

    /// The overview with the readable windows the walk ran under: the
    /// earliest limited boundary among them, if any type is limited.
    init(types: [HealthSampleHistoryStatus], readable: [String: HealthReadWindow]) {
        let boundaries = readable.values.compactMap { window -> Date? in
            guard case let .limited(from) = window else { return nil }
            return from
        }
        self.init(types: types, limitedFrom: boundaries.min())
    }

    var totalCount: Int {
        types.count
    }

    var finishedCount: Int {
        types.count(where: \.isFinished)
    }

    var isFinished: Bool {
        !types.isEmpty && finishedCount == totalCount
    }
}

/// How "Sync everything now" ended.
enum HealthHistoryCatchUpOutcome: String, Sendable, Equatable {
    /// Every type has walked its whole window.
    case finished
    /// The person stopped it, the app left the foreground, or iOS ended it.
    /// Every page already accepted stays accepted; the next run resumes.
    case cancelled
    /// Several rounds in a row moved nothing (server refusing, offline).
    case stalled
    /// Signed out, or the account changed.
    case notAdmitted
}

// MARK: - Persistence

extension DurableHealthCursorStore {
    static let splitSuffix = ".split"
    static let legacySuffix = ".legacy"

    // MARK: - Sibling records (1.3, #127)

    /// A versioned record stored beside the partition's cursor under
    /// `storageKey + suffix`. An empty or undecodable blob reads as absent.
    func readSibling<T: Decodable>(_: T.Type, suffix: String, for key: HealthSyncCursorKey) -> T? {
        guard let data = storage.read(key.storageKey + suffix), !data.isEmpty else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Writes a sibling record and proves it on read-back.
    func writeSiblingVerified<T: Codable & Equatable>(
        _ value: T,
        suffix: String,
        for key: HealthSyncCursorKey
    ) -> Bool {
        guard let encoded = try? encoder.encode(value) else { return false }
        storage.write(key.storageKey + suffix, encoded)
        return readSibling(T.self, suffix: suffix, for: key) == value
    }

    /// Drops the partition's committed cursor (a tombstone, like
    /// `resetCursorOnce`) and proves it reads as absent. The migration record
    /// is untouched.
    func clearCursor(for key: HealthSyncCursorKey) -> Bool {
        storage.write(key.storageKey, Data())
        return anchor(for: key) == nil
    }

    func currentTime() -> Date {
        clock()
    }

    /// The split state of a partition, or `nil` before its first 1.3 pass.
    func splitState(for key: HealthSyncCursorKey) -> HealthSampleSplitState? {
        guard let state = readSibling(HealthSampleSplitState.self, suffix: Self.splitSuffix, for: key),
              state.version == HealthSampleSplitState.formatVersion else { return nil }
        return state
    }

    /// The legacy forward anchor an upgraded partition still finishes.
    func legacyAnchor(for key: HealthSyncCursorKey) -> Data? {
        readSibling(CursorRecord.self, suffix: Self.legacySuffix, for: key)
            .flatMap { $0.version == Self.formatVersion ? $0.anchor : nil }
    }

    /// Establishes the split for a partition exactly once and returns it.
    ///
    /// A partition that already carries a committed cursor is an upgrade: the
    /// cursor is copied to the legacy slot (verified), the main slot is
    /// cleared so the live stream starts at `liveStart`, and only then is the
    /// state written. The order makes a crash at any point safe to repeat: a
    /// legacy copy without a state still counts as an upgrade on the next try.
    func establishSplit(
        for key: HealthSyncCursorKey,
        cutoff: Date,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws -> HealthSampleSplitState {
        if let existing = splitState(for: key) {
            return pinWindowFloor(existing, cutoff: cutoff, for: key, requiring: lease)
        }
        try lease.requireCurrent()
        guard lease.ownerID == key.ownerID else {
            throw HealthSyncCursorStoreError.partitionOwnerMismatch
        }

        let currentAnchor = anchor(for: key)
        let isUpgrade = currentAnchor != nil || legacyAnchor(for: key) != nil
        if let currentAnchor {
            let copy = CursorRecord(version: Self.formatVersion, anchor: currentAnchor, updatedAt: currentTime())
            guard writeSiblingVerified(copy, suffix: Self.legacySuffix, for: key) else {
                throw HealthSyncCursorStoreError.writeNotVerified
            }
            guard clearCursor(for: key) else {
                throw HealthSyncCursorStoreError.writeNotVerified
            }
        }

        let liveStart = HealthSampleSplitPolicy.liveStart(now: currentTime(), cutoff: cutoff)
        let state = HealthSampleSplitState(
            version: HealthSampleSplitState.formatVersion,
            origin: isUpgrade ? .upgrade : .fresh,
            liveStart: liveStart,
            liveCaughtUp: false,
            historyEnd: liveStart,
            historyEndInclusive: false,
            replayFloor: nil,
            replayFloorResolved: !isUpgrade,
            legacyLegActive: isUpgrade,
            fullCatchUp: false,
            updatedAt: currentTime(),
            windowFloor: cutoff == .distantPast ? nil : cutoff
        )
        try lease.requireCurrent()
        guard writeSiblingVerified(state, suffix: Self.splitSuffix, for: key) else {
            throw HealthSyncCursorStoreError.writeNotVerified
        }
        return state
    }

    /// 1.4 (S1) — pins the window bound of a partition that has none: one
    /// 1.3.0 established, or one established before a window was chosen. It
    /// gets the bound as it stood when the partition was established, so the
    /// days a moving bound skipped are walked now. An upgraded partition whose
    /// legacy leg the moving bound retired early resumes from its saved
    /// cursor for the dates it still owes. A write that does not verify
    /// leaves the state as it was, and the next pass tries again.
    private func pinWindowFloor(
        _ state: HealthSampleSplitState,
        cutoff: Date,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) -> HealthSampleSplitState {
        guard state.windowFloor == nil, cutoff != .distantPast else { return state }
        let floor = HealthSampleSplitPolicy.pinnedWindowFloor(cutoff: cutoff, liveStart: state.liveStart, now: currentTime())
        let resumesLegacy = state.origin == .upgrade && !state.legacyLegActive && legacyAnchor(for: key) != nil
        let written = updateSplit(for: key, requiring: lease) { pinned in
            pinned.windowFloor = floor
            if resumesLegacy {
                pinned.legacyLegActive = true
                pinned.legacyLegActive = pinned.legacyWindow(cutoff: cutoff) != nil
            }
        }
        guard written, let pinned = splitState(for: key) else { return state }
        return pinned
    }

    /// Applies `change` to an existing split state under the lease and
    /// persists it with a read-back. `false` when there was nothing to change
    /// or the write did not verify; the caller then holds.
    @discardableResult
    func updateSplit(
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease,
        _ change: (inout HealthSampleSplitState) -> Void
    ) -> Bool {
        guard lease.isCurrent, lease.ownerID == key.ownerID, var state = splitState(for: key) else {
            return false
        }
        let before = state
        change(&state)
        guard state != before else { return true }
        state.updatedAt = currentTime()
        guard writeSiblingVerified(state, suffix: Self.splitSuffix, for: key) else { return false }
        return lease.isCurrent
    }

    /// Commits one history page: the commit rule decides, exactly as for an
    /// anchored page, and only a commit moves the date cursor.
    func commitHistory(
        page outcome: HealthSyncPageOutcome,
        reachedBack end: Date,
        inclusive: Bool,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) -> HealthSyncCommitDecision {
        if let refusal = lease.refusal {
            return .hold(reason: refusal.holdReason)
        }
        guard permitsCollection(for: key) else {
            return .hold(reason: .leaseLost)
        }
        let decision = HealthSyncCursorPolicy.required.decide(outcome)
        guard decision == .commit else { return decision }
        let written = updateSplit(for: key, requiring: lease) { state in
            state.historyEnd = end
            state.historyEndInclusive = inclusive
        }
        return written ? .commit : .hold(reason: .retryPersistenceFailed)
    }

    /// Commits one legacy page through the same rule, onto the legacy slot.
    func commitLegacy(
        page outcome: HealthSyncPageOutcome,
        anchor: Data,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) -> HealthSyncCommitDecision {
        if let refusal = lease.refusal {
            return .hold(reason: refusal.holdReason)
        }
        guard permitsCollection(for: key) else {
            return .hold(reason: .leaseLost)
        }
        let decision = HealthSyncCursorPolicy.required.decide(outcome)
        guard decision == .commit else { return decision }
        guard !anchor.isEmpty, lease.ownerID == key.ownerID else {
            return .hold(reason: .retryPersistenceFailed)
        }
        let record = CursorRecord(version: Self.formatVersion, anchor: anchor, updatedAt: currentTime())
        guard writeSiblingVerified(record, suffix: Self.legacySuffix, for: key), lease.isCurrent else {
            return .hold(reason: .retryPersistenceFailed)
        }
        return .commit
    }

    /// History state of every partition in `keys`, for diagnostics. B5 (1.4):
    /// `readable` holds each type's readable window (iOS 27 limited history);
    /// a type without an entry reads as full access.
    func historyStatus(
        for keys: [HealthSyncCursorKey],
        cutoff: Date,
        readable: [String: HealthReadWindow] = [:]
    ) -> [HealthSampleHistoryStatus] {
        keys.map { key in
            guard let state = splitState(for: key) else {
                return HealthSampleHistoryStatus(
                    typeIdentifier: key.typeIdentifier,
                    reachedBack: nil,
                    isComplete: false,
                    legacyPending: false,
                    liveCaughtUp: false
                )
            }
            return HealthSampleHistoryStatus(
                typeIdentifier: key.typeIdentifier,
                reachedBack: state.historyEnd,
                isComplete: state.isHistoryComplete(cutoff: cutoff, readable: readable[key.typeIdentifier] ?? .unlimited),
                legacyPending: state.legacyWindow(cutoff: cutoff) != nil,
                liveCaughtUp: state.liveCaughtUp
            )
        }
    }
}
