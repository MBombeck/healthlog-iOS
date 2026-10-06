import Foundation

// S2 (#115) — the ECG sweep's upload loop: newest first, confirmed recordings
// skipped, 429 waits sat out inside the sweep's pause budget. Split out of
// `EcgSyncCoordinator.swift` under the `PROJECT_GUIDE.md` file budget; the
// pieces it uses live in `EcgSyncProgress.swift`.

extension EcgSyncCoordinator {
    /// Send one fetch, newest first, skipping what the server already confirmed.
    ///
    /// Returns the tally and whether the shared anchor must be retained. A
    /// recording counts toward advancing the anchor once it is confirmed, now
    /// or in an earlier wake; anything else retains it.
    func uploadRecordings(
        _ recordings: [EcgSourceRecording],
        requiring authLease: EcgUploadAuthenticationLease,
        within partition: EcgAnchorPartition
    ) async -> (EcgSyncSummary, Bool) {
        var summary = EcgSyncSummary.zero
        var retainAnchor = false
        let ledger = EcgConfirmedLedger(defaults: defaults, key: partition.confirmedKey)
        let confirmed = ledger.load()
        var paused: TimeInterval = 0
        var rateLimitHits = 0
        for recording in Self.newestFirst(recordings) {
            if confirmed.contains(recording.id) {
                summary.alreadyConfirmed += 1
                continue
            }
            var outcome = RecordingOutcome.halted(.rateLimited)
            while outcome == .halted(.rateLimited) {
                if !authLease.isCurrent || !partition.isCurrent {
                    summary.stoppedBecause = .transport
                    return (summary, true)
                }
                if let stop = await waitOutRateLimit(paused: &paused) {
                    summary.stoppedBecause = stop
                    return (summary, true)
                }
                outcome = await upload(recording, requiring: authLease)
                if outcome == .halted(.rateLimited) {
                    rateLimitHits += 1
                    // Bounded even when the named wait has already run out by
                    // the time we look (a slow request): never a tight loop.
                    guard rateLimitHits <= EcgRateLimitPacer.maxRetriesPerSweep else {
                        summary.stoppedBecause = .rateLimited
                        return (summary, true)
                    }
                }
            }
            switch outcome {
            case let .accepted(status):
                summary.record(status)
                pacer.recordDelivery()
                if authLease.isCurrent, partition.isCurrent {
                    ledger.insert(recording.id)
                }
            case let .skipped(reason):
                summary.skip(reason)
                retainAnchor = true
            case let .halted(reason):
                summary.stoppedBecause = reason
                return (summary, true)
            }
        }
        return (summary, retainAnchor)
    }

    /// Newest recording first, so a fresh strip never waits behind a long
    /// history. Ties keep HealthKit's order. The anchor rule makes the order
    /// irrelevant to completeness: it advances only past a fully confirmed fetch.
    nonisolated static func newestFirst(_ recordings: [EcgSourceRecording]) -> [EcgSourceRecording] {
        recordings.enumerated()
            .sorted { lhs, rhs in
                lhs.element.recordedAt != rhs.element.recordedAt
                    ? lhs.element.recordedAt > rhs.element.recordedAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Sit out a 429 the server named, within this sweep's pause budget.
    /// Returns `.rateLimited` when the wait does not fit (or the wake ends
    /// while waiting): the sweep stops and the ledger keeps its progress.
    func waitOutRateLimit(paused: inout TimeInterval) async -> EcgSyncStopReason? {
        guard let wait = pacer.remainingHold(now: clock()) else { return nil }
        guard paused + wait <= EcgRateLimitPacer.pauseBudget else { return .rateLimited }
        paused += wait
        // A whole-second wait only — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info("ECG upload rate-limited — pausing \(Int(wait.rounded(.up)), privacy: .public)s")
        do {
            try await EcgSyncPause.sleep(wait)
        } catch {
            return .rateLimited
        }
        return Task.isCancelled ? .rateLimited : nil
    }
}

extension EcgSyncCoordinator: EcgSyncing {
    public func triggerEcgSync() async {
        let summary = await runOwnedSweep()
        guard summary.accepted > 0 || summary.skippedCount > 0 || summary.stoppedBecause != nil
            || summary.alreadyConfirmed > 0 else { return }
        let inserted = summary.inserted
        let updated = summary.updated
        let duplicate = summary.duplicate
        let skipped = summary.skippedCount
        let earlier = summary.alreadyConfirmed
        let stopped = summary.stoppedBecause?.rawValue ?? "-"
        HLLog.healthKit
            .info(
                """
                ECG sync done — inserted=\(inserted, privacy: .public) \
                updated=\(updated, privacy: .public) \
                duplicate=\(duplicate, privacy: .public) \
                skipped=\(skipped, privacy: .public) \
                confirmedEarlier=\(earlier, privacy: .public) \
                stopped=\(stopped, privacy: .public)
                """
            )
    }
}
