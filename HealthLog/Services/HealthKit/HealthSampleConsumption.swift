#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // Phase 07 Wave 2 — one page of samples, mapped once and classified honestly.
    //
    // `HealthLogStandard.handleNewSamples` used to be four responsibilities in one
    // method: the anti-echo filter and wire mapping, the two upload gates, the POST,
    // and a cursor decision expressed as an anchor rewind. The first three are worth
    // keeping exactly as they are — they are the behaviour every forwarding and
    // HR-bucket test pins. The fourth was never durable: SpeziHealthKit persists the
    // query anchor after the handler returns, so a rewind performed inside the
    // handler is overwritten before it can mean anything.
    //
    // This file extracts the first three into a `Sendable` operation the app-owned
    // collector and the Spezi standard both call, and replaces the fourth with a
    // `HealthSyncPageOutcome` — a description of what the server actually proved,
    // which the caller hands to the commit rule instead of guessing.
    //
    // Two classification rules matter and are deliberately explicit:
    //
    //   * A transport failure says nothing about individual rows. Every posted index
    //     is reported non-terminal, so the page may only commit if a durable retry
    //     was written for it.
    //   * `skipped(unmappable_identifier)` is a 200 that is nonetheless not progress
    //     — the server does not yet map that type. It stays non-terminal, exactly as
    //     the pre-Phase-07 `uploadAndDecide` rule treated it, but the recovery is now
    //     a durable outbox row rather than a stalled anchor.

    /// What the anti-echo filter and the two upload gates left of one page.
    struct HealthSampleMappingResult: Sendable, Equatable {
        /// Samples that survived the anti-echo filter — what the diagnostics
        /// surface calls "read".
        let readCount: Int
        /// Rows that will actually be posted.
        let entries: [HealthKitBatchEntryDTO]
        /// `true` when rows existed before the gates and none survived them, i.e.
        /// the daily-statistics or HR-bucket path owns this read instead.
        let handedToAggregatePath: Bool
    }

    /// The mapping and gate configuration for one page.
    ///
    /// A value rather than actor state so the collector and the Spezi standard run
    /// exactly the same rules, and so a test can pin a deterministic HR cutover
    /// boundary without touching `UserDefaults.standard`.
    struct HealthSampleWireGate: Sendable {
        /// HK-STATS gate. When on, the five cumulative identifiers are owned by
        /// `HealthKitStatisticsSyncCoordinator` under `stats:<id>:<day>` external
        /// ids and must not also be posted per sample.
        let dailyStatsEnabled: Bool
        /// HR-bucket gate (`nil` when unwired ⇒ no HR row is ever dropped).
        /// Maps a sample's end date onto "this UTC day uploads as 10-minute
        /// buckets", in which case the bucket sweep owns the row.
        let hrBucketGate: (@Sendable (Date) -> Bool)?

        func map(_ samples: [HKSample]) -> HealthSampleMappingResult {
            // Anti-echo: drop only rows this app itself wrote (our external UUID
            // *and* our own HK source). A third-party sample that happens to carry
            // `HKMetadataKeyExternalUUID` flows in. See `HealthKitSampleOwnership`.
            let foreign = samples.filter { !HealthKitSampleOwnership.isOwnEcho($0) }
            let rawEntries = foreign.flatMap { HealthKitWireConverter.entries(from: $0) }

            let afterStatsGate: [HealthKitBatchEntryDTO] = dailyStatsEnabled
                ? rawEntries.filter { !HealthKitCumulativeTypeConfig.cumulativeIdentifiers.contains($0.hkIdentifier) }
                : rawEntries

            let entries: [HealthKitBatchEntryDTO] = if let hrBucketGate {
                afterStatsGate.filter { entry in
                    guard entry.hkIdentifier == HealthKitHRBucketRow.hkIdentifier else { return true }
                    // Pre-cutover HR stays on the per-sample path; on-or-after
                    // cutover belongs to the bucket sweep.
                    return !hrBucketGate(entry.endDate)
                }
            } else {
                afterStatsGate
            }

            return HealthSampleMappingResult(
                readCount: foreign.count,
                entries: entries,
                handedToAggregatePath: entries.isEmpty && !rawEntries.isEmpty
            )
        }
    }

    /// The durable-retry seam. A page that the server did not terminally accept may
    /// only advance a cursor once its rows exist somewhere that survives a restart.
    protocol HealthSyncBatchRetryEnqueuing: Sendable {
        func enqueueHealthKitRetry(
            _ entries: [HealthKitBatchEntryDTO],
            idempotencyKey: String,
            requiringCurrentOwner ownerUserID: String
        ) async throws
    }

    extension OutboxQueue: HealthSyncBatchRetryEnqueuing {
        /// Routes to the Wave-1 importer overload, which refuses the enqueue
        /// outright when `ownerUserID` no longer owns the live session.
        func enqueueHealthKitRetry(
            _ entries: [HealthKitBatchEntryDTO],
            idempotencyKey: String,
            requiringCurrentOwner ownerUserID: String
        ) async throws {
            try await enqueueHealthKitBatch(
                entries,
                encoder: .hlBatch,
                idempotencyKey: idempotencyKey,
                requiringCurrentOwner: ownerUserID
            )
        }
    }

    /// Maps, posts, and classifies one page — and writes a durable retry for
    /// whatever the server did not terminally accept.
    struct HealthSampleConsumption: Sendable {
        let uploader: MeasurementBatchUploader
        let gate: HealthSampleWireGate
        /// `nil` in contexts with no queue (tests, pre-composition). A page that
        /// needs a retry and has nowhere to write it reports `durableRetryFailed`,
        /// so the cursor holds rather than claiming ground it does not have.
        let retry: (any HealthSyncBatchRetryEnqueuing)?

        /// Runs the whole transmission half of a page and reports what was proved.
        ///
        /// Never rewinds and never persists a cursor: the returned outcome is the
        /// only thing this type produces, and the caller decides with it.
        /// - Parameter lease: the admission this page belongs to, or `nil` on the
        ///   Spezi-standard path, which owns no cursor partition and therefore has
        ///   no admission to make. Without an admission there is also no owner to
        ///   attribute a durable retry to, so a non-terminal page simply reports
        ///   itself non-terminal and the caller holds.
        func consume(
            _ samples: [HKSample],
            admitted lease: HealthSyncAuthenticatedLease?
        ) async -> (mapping: HealthSampleMappingResult, outcome: HealthSyncPageOutcome) {
            let mapping = gate.map(samples)
            return await (mapping, transmit(mapping, admitted: lease))
        }

        /// Posts an already-mapped page. Split out so a caller that has to answer
        /// "is there anything to post at all?" before resolving an uploader does not
        /// have to run the gates twice.
        func transmit(
            _ mapping: HealthSampleMappingResult,
            admitted lease: HealthSyncAuthenticatedLease?
        ) async -> HealthSyncPageOutcome {
            guard !mapping.entries.isEmpty else {
                // Nothing to post. An empty page is terminally accounted for by
                // construction, so the cursor may move.
                return Self.emptyOutcome
            }
            if let refusal = lease?.refusal {
                return Self.refusedOutcome(refusal, postedCount: mapping.entries.count)
            }

            let posted = mapping.entries
            var transportThrew = false
            var nonterminalIndexes: Set<Int> = []

            // The uploader's own owner/bearer lease is unchanged from the
            // pre-Phase-07 path: it is what pins the exact credential onto the
            // request so a 401 recovery cannot rebuild the envelope under a
            // replacement account.
            let authenticationLease: MeasurementUploadAuthenticationLease?
            do {
                authenticationLease = try await uploader.captureAuthenticationLeaseIfConfigured()
            } catch {
                return Self.refusedOutcome(.unavailableAuthentication, postedCount: posted.count)
            }

            do {
                let outcomes = try await admitting(lease) {
                    try await uploader.upload(posted, requiring: authenticationLease)
                }
                // The uploader already ran `MeasurementBatchAcceptance.validate`,
                // so a returned outcome means every posted index carried terminal
                // evidence. One reason survives that gate and still is not
                // progress: the server cannot map the identifier yet.
                for outcome in outcomes {
                    for skipped in outcome.skipped
                        where skipped.reason == HealthKitServerSupportConfig.reasonUnmappableIdentifier
                    {
                        nonterminalIndexes.insert(skipped.index)
                    }
                }
            } catch let refusal as HealthSyncLeaseRefusal {
                return Self.refusedOutcome(refusal, postedCount: posted.count)
            } catch is CancellationError {
                return Self.refusedOutcome(.cancelled, postedCount: posted.count)
            } catch {
                // A raised transport says nothing about individual rows: the batch
                // may never have been seen at all. Every index is non-terminal.
                transportThrew = true
                nonterminalIndexes = Set(posted.indices)
            }

            let entries = posted.indices.map { index in
                HealthSyncEntryOutcome(
                    index: index,
                    stableIdentity: posted[index].externalId,
                    classification: nonterminalIndexes.contains(index) ? .nonterminal : .terminalAccepted
                )
            }
            guard !nonterminalIndexes.isEmpty else {
                return HealthSyncPageOutcome(
                    postedCount: posted.count,
                    entries: entries,
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: lease?.isCurrent ?? true,
                    wasCancelled: false
                )
            }

            // Without an admission there is no owner to attribute a retry row to,
            // and stamping the ambient account onto one person's samples is the
            // exact harm Wave 1 closed on the queue. The page then stays
            // unaccounted for and the caller holds.
            let attempted = lease != nil && retry != nil
            let pending = nonterminalIndexes.sorted().map { posted[$0] }
            let persisted = attempted ? await persistRetry(pending, requiring: lease) : false
            return HealthSyncPageOutcome(
                postedCount: posted.count,
                entries: entries,
                transportThrew: transportThrew,
                durableRetryPersisted: persisted,
                durableRetryFailed: attempted && !persisted,
                leaseIsCurrent: lease?.isCurrent ?? true,
                wasCancelled: Task.isCancelled
            )
        }

        /// `HealthSyncAuthenticatedLease.admitting(_:)` when there is an admission,
        /// a plain call when there is not. One place, so the two paths cannot drift.
        private func admitting<T: Sendable>(
            _ lease: HealthSyncAuthenticatedLease?,
            _ body: () async throws -> T
        ) async throws -> T {
            guard let lease else { return try await body() }
            return try await lease.admitting(body)
        }

        /// Writes the rows the server did not accept under a *derived* idempotency
        /// key, so a process that dies before the cursor write rebuilds the same
        /// key on relaunch instead of minting a second server row.
        private func persistRetry(
            _ entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease?
        ) async -> Bool {
            guard let retry, let lease else { return false }
            guard let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: Self.stableIdentity(of: entries)
            ) else {
                return false
            }
            do {
                try await lease.admitting {
                    try await retry.enqueueHealthKitRetry(
                        entries,
                        idempotencyKey: envelope.idempotencyKey,
                        requiringCurrentOwner: lease.ownerID
                    )
                }
                return true
            } catch {
                // No value, no identifier, no owner — only the fact that the
                // durable write did not happen, which is what holds the cursor.
                HLLog.healthKit.error("durable health retry write failed — cursor holds")
                return false
            }
        }

        /// The page's own externally stable identity: the sorted external ids of
        /// the rows being retried. Re-reading the same window from the same anchor
        /// yields the same set, which is what makes the derived key restart stable.
        static func stableIdentity(of entries: [HealthKitBatchEntryDTO]) -> String {
            entries.map(\.externalId).sorted().joined(separator: "|")
        }

        private static var emptyOutcome: HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 0,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }

        private static func refusedOutcome(
            _ refusal: HealthSyncLeaseRefusal,
            postedCount: Int
        ) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: postedCount,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: refusal == .cancelled,
                wasCancelled: refusal == .cancelled
            )
        }
    }
#endif
