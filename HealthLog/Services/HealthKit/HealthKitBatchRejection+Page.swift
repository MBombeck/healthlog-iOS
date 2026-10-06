import Foundation

extension HealthKitBatchRejection {
    /// INT-A — how many consecutive sweeps an unexplained whole-batch 4xx may
    /// hold one type's anchor before its rows are recorded and released (the
    /// same bound the nutrient sweep applies to a transient skip).
    static let maxHeldSweeps = 5

    /// INT-A — the skip-register reason of rows released after
    /// ``maxHeldSweeps``: the HTTP status the server kept answering without a
    /// code (`unclassified_4xx:422`).
    static func unclassifiedReason(status: Int) -> String {
        "unclassified_4xx:\(status)"
    }

    /// #115 / 0.3 — the page a rejected whole batch leaves for the cursor.
    ///
    /// Queued like a transport failure, a whole-batch 4xx committed the anchor
    /// and the replay deleted the rows on the same 4xx. Instead:
    ///
    /// * ``refused(reason:)`` records every row in the account's skip register
    ///   (``HealthKitSkippedRowRegister``) first, and only then reports the rows
    ///   as terminal, so the window may move past rows a person can still see
    ///   and the register offers again.
    /// * ``notStored(status:)`` reports every row non-terminal with nothing
    ///   queued: the shared rule holds the anchor (`nonterminalEntry`) and the
    ///   next sweep offers the page again, for at most ``maxHeldSweeps``
    ///   consecutive sweeps (`heldSweeps` counts this one; the caller keeps the
    ///   count). Then the rows go into the
    ///   register as ``unclassifiedReason(status:)`` and the window moves: a
    ///   permanently invalid page must not pin every later event of its type.
    ///
    /// A register write that fails holds the page in every case.
    func page(
        for entries: [HealthKitBatchEntryDTO],
        requiring lease: HealthSyncAuthenticatedLease,
        heldSweeps: Int
    ) async -> HealthSyncPageOutcome {
        var registerReason: String?
        switch self {
        case let .refused(reason):
            registerReason = reason
        case let .notStored(status):
            if heldSweeps >= Self.maxHeldSweeps {
                registerReason = Self.unclassifiedReason(status: status)
            }
        case .retry:
            break
        }
        var registered = false
        if let registerReason {
            do {
                try await HealthKitSkippedRowRegister.current.record(
                    entries.map { HealthKitSkippedEntry(entry: $0, reason: registerReason) },
                    ownerID: lease.ownerID,
                    build: HealthKitSkipRegisterBuild.current
                )
                registered = true
            } catch {
                HLLog.healthKit.error("HK batch rejected — skip register write failed, anchor holds")
            }
        }
        // A count and a flag only — no identifier, no value.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.error("HK batch rejected — \(entries.count, privacy: .public) row(s), registered=\(registered, privacy: .public)")
        return HealthSyncPageOutcome(
            postedCount: entries.count,
            entries: entries.indices.map { index in
                HealthSyncEntryOutcome(
                    index: index,
                    stableIdentity: entries[index].externalId,
                    classification: registered ? .terminalAccepted : .nonterminal
                )
            },
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: lease.isCurrent,
            wasCancelled: Task.isCancelled
        )
    }
}
