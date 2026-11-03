#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // 1.3 (#127, #128) — the history and legacy legs of the collector.
    //
    // Both run only in the budget the live streams left, only for a type
    // whose live stream has reached the present, and only one run at a time.
    // Every page goes through the same consumption and the same commit rule as
    // a live page: a page the server did not terminally accept (and that has
    // no durable retry row) leaves the date cursor exactly where it was.

    /// 1.3 (#127) — the history seam: samples of one type whose start date
    /// lies in `window`, newest start first, at most `limit` (`nil` = all).
    protocol HealthSampleHistoryQuerying: Sendable {
        func historyPage(
            typeIdentifier: String,
            within window: HealthSampleDateWindow,
            limit: Int?
        ) async throws -> [HKSample]

        /// **B5 (1.4, R4 2.1)** — how far back Apple Health lets HealthLog
        /// read each type (iOS 27 limited history), asked in one go. A type
        /// without an entry reads as full access.
        func readWindows(typeIdentifiers: [String]) async -> [String: HealthReadWindow]
    }

    extension HealthSampleHistoryQuerying {
        /// Doubles without a window read everything, like every system
        /// before iOS 27.
        func readWindows(typeIdentifiers _: [String]) async -> [String: HealthReadWindow] {
            [:]
        }
    }

    extension HealthSamplePageConsuming {
        /// A consumer without a history form (test doubles) consumes a
        /// history page like a live one.
        func consumeHistory(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            await consume(samples, ofType: typeIdentifier, requiring: lease)
        }
    }

    extension AnchoredHealthSampleCollector {
        /// What the history (and, for an upgrade, the legacy) leg did for one
        /// type in one pass.
        struct HistoryResult: Sendable, Equatable {
            let pagesCollected: Int
            let samplesRead: Int
            let disposition: HealthSyncDisposition
            let holdReason: HealthSyncHoldReason?
            /// Nothing is owed any more by either leg.
            let isFinished: Bool
            /// A2 (1.4, R3 S6) — pages whose rows the server (or the
            /// statistics path) took: committed, not empty, nothing parked.
            /// Only these are progress for "Sync everything now".
            var acceptedPages = 0
        }

        /// One history run over `order`. Types the time budget did not reach
        /// are named `expired`, so the caller can start the next run there.
        func collectHistory(
            order: [String],
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease,
            allowance: HealthSampleHistoryBudget
        ) async -> [String: HistoryResult] {
            let startedAt = clock.uptime()
            if let running = historyRun, startedAt - running.startedAt < HealthSampleSplitPolicy.staleHistoryRun {
                // Another pass walks the same date cursors right now.
                return Dictionary(uniqueKeysWithValues: order.map { ($0, Self.historyResult(0, 0, .deferred, nil, false)) })
            }
            let token = UUID()
            historyRun = (token, startedAt)
            defer {
                if historyRun?.token == token { historyRun = nil }
            }

            let deadline = startedAt + allowance.timeBudget
            var out: [String: HistoryResult] = [:]
            var unreachable = false
            // B5 (1.4, R4 2.1) — one question for every type's readable window.
            let readable = await readWindows(for: order)
            for typeIdentifier in order {
                // A2 (1.4, R3 S6) — once a page found the server out of reach,
                // the other types are not read: their pages could not go out
                // either, and until 1.3.0 each of them parked one in the outbox.
                if unreachable {
                    out[typeIdentifier] = Self.unreachableHistory
                    continue
                }
                if Task.isCancelled || clock.uptime() >= deadline {
                    out[typeIdentifier] = Self.historyResult(0, 0, .expired, nil, false)
                    continue
                }
                let result = await collectHistoryOne(
                    typeIdentifier,
                    cutoff: cutoff,
                    readable: readable[typeIdentifier] ?? .unlimited,
                    lease: lease,
                    maxPages: allowance.pagesPerType,
                    deadline: deadline
                )
                out[typeIdentifier] = result
                unreachable = result.holdReason == .serverUnreachable
            }
            return out
        }

        /// B5 (1.4, R4 2.1) — every type's readable window, for the walk and
        /// for Sync Diagnostics. Empty without a history seam.
        func readWindows(for typeIdentifiers: [String]) async -> [String: HealthReadWindow] {
            guard let history, !typeIdentifiers.isEmpty else { return [:] }
            return await history.readWindows(typeIdentifiers: typeIdentifiers)
        }

        /// A2 — the history of a type a pass did not read because the server
        /// was out of reach.
        static var unreachableHistory: HistoryResult {
            historyResult(0, 0, .deferred, .serverUnreachable, false)
        }

        static func withUnreachableHistory(_ result: TypeResult) -> TypeResult {
            var held = result
            held.history = unreachableHistory
            return held
        }

        /// Pages, rows and the retry flag one type has used so far in a run.
        struct HistoryTally {
            var pages = 0
            var samplesRead = 0
            var retryPersisted = false
            /// A2 (1.4, R3 S6) — committed pages with rows, none of them parked.
            var acceptedPages = 0
            /// A2 (1.4, R3 3.2) — pages in a row the server answered with
            /// nothing but folded windows.
            var foldedRun = 0

            func result(
                _ disposition: HealthSyncDisposition,
                _ reason: HealthSyncHoldReason?,
                finished: Bool = false
            ) -> HistoryResult {
                var result = AnchoredHealthSampleCollector.historyResult(pages, samplesRead, disposition, reason, finished)
                result.acceptedPages = acceptedPages
                return result
            }

            /// Books a page whose cursor moved. A page that posted nothing
            /// (empty, or handed to the statistics or bucket path) neither
            /// lengthens nor breaks the folded run.
            mutating func noteCommitted(read samples: Int, _ outcome: HealthSyncPageOutcome) {
                if samples > 0, !outcome.durableRetryPersisted { acceptedPages += 1 }
                if outcome.isEntirelyFolded {
                    foldedRun += 1
                } else if outcome.postedCount > 0 {
                    foldedRun = 0
                }
            }

            /// A held page: `retryPersisted` when its rows wait durably,
            /// `expired` when the run was cancelled under it (BG expiry, the
            /// person stopping "Sync everything now").
            func held(_ reason: HealthSyncHoldReason) -> HistoryResult {
                if reason == .cancelled { return result(.expired, reason) }
                return result(retryPersisted ? .retryPersisted : .failed, reason)
            }
        }

        private func collectHistoryOne(
            _ typeIdentifier: String,
            cutoff: Date,
            readable: HealthReadWindow,
            lease: HealthSyncAuthenticatedLease,
            maxPages: Int,
            deadline: TimeInterval
        ) async -> HistoryResult {
            guard let history, let key = lease.cursorKey(typeIdentifier: typeIdentifier) else {
                return Self.historyResult(0, 0, .failed, .leaseLost, false)
            }
            guard await cursors.permitsCollection(for: key),
                  var state = await cursors.splitState(for: key),
                  state.historyMayRun else
            {
                return Self.historyResult(0, 0, .deferred, nil, false)
            }
            if historyOwnedElsewhere(typeIdentifier) {
                return await retireHistory(key, cutoff: cutoff, lease: lease)
            }
            // B5 (1.4, R4 2.1) — HealthKit could not name the readable window,
            // so an empty page would prove nothing: walk nothing, record nothing.
            if readable == .unknown {
                return Self.historyResult(0, 0, .deferred, nil, false)
            }

            var tally = HistoryTally()
            let limits = (maxPages: maxPages, deadline: deadline)
            let walk = (history: history, readable: readable)
            if let stopped = await walkBackwards(walk, key, &state, &tally, cutoff: cutoff, lease: lease, limits: limits) {
                return stopped
            }
            if let stopped = await walkLegacy(key, &state, &tally, cutoff: cutoff, lease: lease, limits: limits) {
                return stopped
            }
            let finished = state.isHistoryComplete(cutoff: cutoff, readable: readable)
                && state.legacyWindow(cutoff: cutoff) == nil
            return tally.result(tally.retryPersisted ? .retryPersisted : .succeeded, nil, finished: finished)
        }

        /// Backwards from `liveStart`, newest first, down to the floor. Returns
        /// a result only when the run has to stop for this type.
        private func walkBackwards(
            _ walk: (history: any HealthSampleHistoryQuerying, readable: HealthReadWindow),
            _ key: HealthSyncCursorKey,
            _ state: inout HealthSampleSplitState,
            _ tally: inout HistoryTally,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease,
            limits: (maxPages: Int, deadline: TimeInterval)
        ) async -> HistoryResult? {
            while tally.pages < limits.maxPages, !state.isHistoryComplete(cutoff: cutoff, readable: walk.readable) {
                if let stop = interruption(lease: lease, deadline: limits.deadline) {
                    return tally.result(stop.disposition, stop.reason)
                }
                let floor = state.readableHistoryFloor(cutoff: cutoff, readable: walk.readable)
                let window = HealthSampleDateWindow(
                    start: floor == .distantPast ? nil : floor,
                    end: state.historyEnd,
                    endInclusive: state.historyEndInclusive
                )
                let step: HistoryStep
                do {
                    step = try await readHistoryStep(walk.history, key.typeIdentifier, window: window, floor: floor)
                } catch is CancellationError {
                    return tally.result(.expired, .cancelled)
                } catch {
                    logHold(key, reason: .nonterminalEntry)
                    return tally.result(.failed, .nonterminalEntry)
                }

                tally.samplesRead += step.samples.count
                let outcome = await consumer.consumeHistory(step.samples, ofType: key.typeIdentifier, requiring: lease)
                tally.retryPersisted = tally.retryPersisted || outcome.durableRetryPersisted
                let decision = await cursors.commitHistory(
                    page: outcome,
                    reachedBack: step.nextEnd,
                    inclusive: step.nextInclusive,
                    for: key,
                    requiring: lease
                )
                tally.pages += 1
                if case let .hold(reason) = decision {
                    logHold(key, reason: reason)
                    return tally.held(reason)
                }
                tally.noteCommitted(read: step.samples.count, outcome)
                guard let reread = await cursors.splitState(for: key) else {
                    return tally.result(.failed, .retryPersistenceFailed)
                }
                state = reread
                if tally.foldedRun >= HealthSampleSplitPolicy.foldedPagesBeforeStop {
                    await stopAtFoldedWindows(key, &state, cutoff: cutoff, lease: lease)
                }
            }
            return nil
        }

        /// A2 (1.4, R3 3.2) — the last pages came back as nothing but folded
        /// windows: the server holds this type's history from here back (its
        /// fold runs over everything older than its threshold). The walk
        /// records its floor as reached instead of sending years of rows the
        /// server would only answer `duplicate`. A failed write changes
        /// nothing; the walk simply goes on.
        private func stopAtFoldedWindows(
            _ key: HealthSyncCursorKey,
            _ state: inout HealthSampleSplitState,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease
        ) async {
            let floor = state.historyFloor(cutoff: cutoff)
            let stopped = await cursors.updateSplit(for: key, requiring: lease) { split in
                split.historyEnd = floor
                split.historyEndInclusive = false
            }
            guard stopped, let reread = await cursors.splitState(for: key) else { return }
            state = reread
            // A fixed source and a fixed phrase: no type, value, date or owner.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("health history [\(key.source.rawValue, privacy: .public)] — server holds the rest folded")
        }

        /// A2 (1.4, R-A8) — a type whose history another path owns (the summed
        /// types, sent as day and hour totals by the statistics path). Its raw
        /// history is recorded as read without reading it: the per-sample gate
        /// would drop every row anyway. The legacy leg retires with it.
        private func retireHistory(
            _ key: HealthSyncCursorKey,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease
        ) async -> HistoryResult {
            let retired = await cursors.updateSplit(for: key, requiring: lease) { split in
                if !split.isHistoryComplete(cutoff: cutoff) {
                    split.historyEnd = split.historyFloor(cutoff: cutoff)
                    split.historyEndInclusive = false
                }
                split.legacyLegActive = false
            }
            guard retired else {
                logHold(key, reason: .retryPersistenceFailed)
                return Self.historyResult(0, 0, .failed, .retryPersistenceFailed, false)
            }
            return Self.historyResult(0, 0, .succeeded, nil, true)
        }

        /// The legacy leg of an upgrade: the dates below the replay floor,
        /// read forward from the 1.2.0 cursor, until it comes back short.
        private func walkLegacy(
            _ key: HealthSyncCursorKey,
            _ state: inout HealthSampleSplitState,
            _ tally: inout HistoryTally,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease,
            limits: (maxPages: Int, deadline: TimeInterval)
        ) async -> HistoryResult? {
            while state.isHistoryComplete(cutoff: cutoff), state.legacyLegActive {
                guard let window = state.legacyWindow(cutoff: cutoff) else {
                    // The walk itself reaches the window now ("Sync everything
                    // now", or no shortcut): nothing is owed below it.
                    await cursors.updateSplit(for: key, requiring: lease) { $0.legacyLegActive = false }
                    state.legacyLegActive = false
                    return nil
                }
                guard tally.pages < limits.maxPages else { return nil }
                if let stop = interruption(lease: lease, deadline: limits.deadline) {
                    return tally.result(stop.disposition, stop.reason)
                }
                let anchor = await HealthKitAnchorArchive.decodeAnchor(
                    cursors.legacyAnchor(for: key),
                    label: key.source.rawValue
                )
                let page: AnchoredHealthSamplePage
                do {
                    page = try await query.page(
                        typeIdentifier: key.typeIdentifier,
                        resumingFrom: anchor,
                        within: window,
                        limit: pageLimit
                    )
                } catch is CancellationError {
                    return tally.result(.expired, .cancelled)
                } catch {
                    logHold(key, reason: .nonterminalEntry)
                    return tally.result(.failed, .nonterminalEntry)
                }
                tally.samplesRead += page.samples.count
                let outcome = await consumer.consumeHistory(page.samples, ofType: key.typeIdentifier, requiring: lease)
                tally.retryPersisted = tally.retryPersisted || outcome.durableRetryPersisted
                guard let newAnchor = page.newAnchor,
                      let blob = HealthKitAnchorArchive.encodeAnchor(newAnchor, label: key.source.rawValue) else
                {
                    logHold(key, reason: .retryPersistenceFailed)
                    return tally.result(.failed, .retryPersistenceFailed)
                }
                let decision = await cursors.commitLegacy(page: outcome, anchor: blob, for: key, requiring: lease)
                tally.pages += 1
                if case let .hold(reason) = decision {
                    logHold(key, reason: reason)
                    return tally.held(reason)
                }
                tally.noteCommitted(read: page.samples.count, outcome)
                if !page.mayHaveMore {
                    let retired = await cursors.updateSplit(for: key, requiring: lease) { $0.legacyLegActive = false }
                    if retired { state.legacyLegActive = false }
                    return nil
                }
            }
            return nil
        }

        /// One step of the backwards walk and where the cursor goes after it.
        struct HistoryStep {
            let samples: [HKSample]
            let nextEnd: Date
            let nextInclusive: Bool
        }

        /// Reads one page and decides the next cursor. A short page ends the
        /// walk at the floor. A full page moves the end to its oldest start,
        /// inclusive, because more samples may share that instant; when a full
        /// page is entirely that one instant, the whole instant is read at once
        /// so the walk can step past it without losing any of it.
        private func readHistoryStep(
            _ history: any HealthSampleHistoryQuerying,
            _ typeIdentifier: String,
            window: HealthSampleDateWindow,
            floor: Date
        ) async throws -> HistoryStep {
            let samples = try await history.historyPage(typeIdentifier: typeIdentifier, within: window, limit: pageLimit)
            guard samples.count >= pageLimit, let oldest = samples.map(\.startDate).min() else {
                return HistoryStep(samples: samples, nextEnd: floor, nextInclusive: false)
            }
            if let end = window.end, oldest >= end {
                let instant = HealthSampleDateWindow(start: end, end: end, endInclusive: true)
                let whole = try await history.historyPage(typeIdentifier: typeIdentifier, within: instant, limit: nil)
                return HistoryStep(samples: whole, nextEnd: end, nextInclusive: false)
            }
            return HistoryStep(samples: samples, nextEnd: oldest, nextInclusive: true)
        }

        private func interruption(
            lease: HealthSyncAuthenticatedLease,
            deadline: TimeInterval
        ) -> (disposition: HealthSyncDisposition, reason: HealthSyncHoldReason?)? {
            if Task.isCancelled { return (.expired, .cancelled) }
            if let refusal = lease.refusal { return (.failed, refusal.holdReason) }
            if clock.uptime() >= deadline { return (.expired, nil) }
            return nil
        }

        /// A2 (1.4, R3 S6) — whether a pass moved anything for a type: its
        /// live leg took rows without holding or parking any, or its history
        /// took at least one page. What "Sync everything now" counts.
        static func madeProgress(_ result: TypeResult) -> Bool {
            (result.samplesRead > 0 && result.disposition == .succeeded) || (result.history?.acceptedPages ?? 0) > 0
        }

        static func historyResult(
            _ pages: Int,
            _ samplesRead: Int,
            _ disposition: HealthSyncDisposition,
            _ holdReason: HealthSyncHoldReason?,
            _ isFinished: Bool
        ) -> HistoryResult {
            HistoryResult(
                pagesCollected: pages,
                samplesRead: samplesRead,
                disposition: disposition,
                holdReason: holdReason,
                isFinished: isFinished
            )
        }
    }

    extension HealthSyncPageOutcome {
        /// A2 (1.4, R3 3.2) — every posted row came back a `folded_window`
        /// duplicate: the server had all of it already, folded.
        var isEntirelyFolded: Bool {
            postedCount > 0 && foldedWindowDuplicates >= postedCount
        }
    }
#endif
