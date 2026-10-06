import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// E1 — a State of Mind write whose answer the app could not read.
///
/// `POST /api/mood-entries` answering with a body this build cannot decode
/// (`HLError.decoding`: a captive portal's HTML 200, a proxy page) says nothing
/// about the mood. Most often the write landed; behind a portal it did not.
/// Until C4 the importer called it a final refusal and moved the anchor past a
/// mood that may exist nowhere. Now it holds, like a heart-event page held on an
/// unexplained 4xx (INT-A): the same sample goes out again under its derived
/// idempotency key on the next sweep, which the server answers from its cache
/// if the first write landed. After ``maxHeldSweeps`` consecutive unreadable
/// answers for the same sample it goes into the skip register with ``reason``
/// and the page moves on, so one unreadable answer cannot stall the importer.
enum MoodStateOfMindUnreadable {
    /// The skip-register reason of such a sample.
    static let reason = "unreadable_response"

    /// Consecutive sweeps one sample may be held — the heart-event bound.
    static let maxHeldSweeps = HealthKitBatchRejection.maxHeldSweeps
}

#if canImport(HealthKit)
    extension MoodStateOfMindImporter {
        /// `true` for an answer the app could not read.
        static func isUnreadable(_ outcome: MoodWriteOutcome) -> Bool {
            if case .rejected(.decoding) = outcome { return true }
            return false
        }

        /// The counter of consecutive unreadable sweeps: `<identity>|<count>`,
        /// per account partition. One sample at a time — the page stops there.
        var unreadableRunKey: String {
            "hl.healthkit.somUnreadable." + partitionToken
        }

        /// Counts this sweep's unreadable answer for `identity`. Below the bound
        /// the outcome stays unreadable (the page holds). At the bound the
        /// sample is registered and reported `.rejected(.unknown)` — terminal,
        /// its copy is in the register. A register write that fails keeps it
        /// held. Any other answer for the counted sample ends its run.
        @available(iOS 18.0, *)
        func settleUnreadable(
            _ outcome: MoodWriteOutcome,
            sample: HKStateOfMind,
            identity: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> MoodWriteOutcome {
            let stored = defaults.string(forKey: unreadableRunKey)?.split(separator: "|", maxSplits: 1)
            let counted = stored?.first.map(String.init) == identity ? Int(stored?.last ?? "") ?? 0 : 0
            guard Self.isUnreadable(outcome) else {
                if counted > 0 { defaults.removeObject(forKey: unreadableRunKey) }
                return outcome
            }
            let held = counted + 1
            guard held >= MoodStateOfMindUnreadable.maxHeldSweeps else {
                defaults.set("\(identity)|\(held)", forKey: unreadableRunKey)
                return outcome
            }
            let skipped = StateOfMindSkippedSample(
                externalId: identity,
                recordedAt: sample.startDate,
                score: MoodStateOfMindMapping.score(forValence: sample.valence)
            )
            do {
                try await HealthKitSkippedRowRegister.current.record(
                    [HealthKitSkippedEntry(mood: skipped, reason: MoodStateOfMindUnreadable.reason)],
                    ownerID: lease.ownerID,
                    build: HealthKitSkipRegisterBuild.current
                )
            } catch {
                defaults.set("\(identity)|\(held)", forKey: unreadableRunKey)
                HLLog.healthKit.error("state-of-mind unreadable — skip register write failed, anchor holds")
                return outcome
            }
            defaults.removeObject(forKey: unreadableRunKey)
            HLLog.healthKit.info("state-of-mind unreadable — sample moved to the skip register")
            return .rejected(.unknown(MoodStateOfMindUnreadable.reason))
        }
    }
#endif
