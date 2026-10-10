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
        /// #12 — heart-rate rows the HR-bucket gate took off this page. The
        /// caller requests a bucket sweep whenever this is non-zero, so the
        /// hand-off and the sweep that completes it travel together.
        var heartRateHandedOff = 0
        /// V1 (1.2) — cumulative rows (steps, energy, flights, distance,
        /// daylight) the daily-statistics gate took off this page. The caller
        /// requests a recent statistics sweep whenever this is non-zero.
        var cumulativeHandedOff = 0
    }

    /// What the server did with one page's rows, for Sync Diagnostics (#113).
    ///
    /// Only `inserted`, `updated` and `duplicate` count as uploaded. A row the
    /// server refused is `skipped` (and remembered in the skip register); a row
    /// it could not take yet and that waits in the outbox is `parked`.
    struct HealthSampleServerTally: Sendable, Equatable {
        var accepted = 0
        var skipped = 0
        var parked = 0
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

            let heartRateBefore = afterStatsGate.count(where: { $0.hkIdentifier == HealthKitHRBucketRow.hkIdentifier })
            let heartRateAfter = entries.count(where: { $0.hkIdentifier == HealthKitHRBucketRow.hkIdentifier })
            return HealthSampleMappingResult(
                readCount: foreign.count,
                entries: entries,
                handedToAggregatePath: entries.isEmpty && !rawEntries.isEmpty,
                heartRateHandedOff: heartRateBefore - heartRateAfter,
                cumulativeHandedOff: rawEntries.count - afterStatsGate.count
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

        /// Build 273 (A15) — whether a live (non-dead-lettered) row already waits
        /// under this idempotency key. A deterministically failing stats chunk is
        /// re-planned on every foreground; without this check it was enqueued
        /// again each time under the same key.
        func hasPendingHealthKitRetry(idempotencyKey: String) async -> Bool
    }

    extension HealthSyncBatchRetryEnqueuing {
        func hasPendingHealthKitRetry(idempotencyKey _: String) async -> Bool {
            false
        }
    }

    extension OutboxQueue: HealthSyncBatchRetryEnqueuing {
        /// A15 — a live row under this key already waits in the outbox.
        func hasPendingHealthKitRetry(idempotencyKey: String) async -> Bool {
            await hasLiveOperation(idempotencyKey: idempotencyKey)
        }

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
        /// #113 — where a row the server refused for a deterministic reason
        /// (`value_out_of_range`, …) is remembered before the cursor may pass it.
        /// `nil` means there is nowhere to remember it, and a page carrying such a
        /// refusal then holds instead of dropping the row.
        var skipRegister: HealthKitSkippedRowRegister?
        /// The build a registered row is stamped with (the re-offer rule).
        var build: String = HealthKitSkipRegisterBuild.current

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
            await transmitReporting(mapping, admitted: lease).outcome
        }

        /// ``transmit(_:admitted:)`` plus the honest per-row tally the Sync
        /// Diagnostics surface counts (#113): only `inserted`, `updated` and
        /// `duplicate` are "uploaded".
        func transmitReporting(
            _ mapping: HealthSampleMappingResult,
            admitted lease: HealthSyncAuthenticatedLease?
        ) async -> (outcome: HealthSyncPageOutcome, tally: HealthSampleServerTally) {
            guard !mapping.entries.isEmpty else {
                // Nothing to post. An empty page is terminally accounted for by
                // construction, so the cursor may move.
                return (Self.emptyOutcome, HealthSampleServerTally())
            }
            let posted = mapping.entries
            if let refusal = lease?.refusal {
                return (Self.refusedOutcome(refusal, postedCount: posted.count), HealthSampleServerTally())
            }

            // The uploader's own owner/bearer lease is unchanged from the
            // pre-Phase-07 path: it is what pins the exact credential onto the
            // request so a 401 recovery cannot rebuild the envelope under a
            // replacement account.
            let authenticationLease: MeasurementUploadAuthenticationLease?
            do {
                authenticationLease = try await uploader.captureAuthenticationLeaseIfConfigured()
            } catch {
                return (Self.refusedOutcome(.unavailableAuthentication, postedCount: posted.count), HealthSampleServerTally())
            }

            var verdicts = PageVerdicts()
            do {
                let outcomes = try await admitting(lease) {
                    try await uploader.upload(posted, requiring: authenticationLease)
                }
                verdicts = PageVerdicts(outcomes)
            } catch let refusal as HealthSyncLeaseRefusal {
                return (Self.refusedOutcome(refusal, postedCount: posted.count), HealthSampleServerTally())
            } catch is CancellationError {
                return (Self.refusedOutcome(.cancelled, postedCount: posted.count), HealthSampleServerTally())
            } catch {
                // A raised transport says nothing about individual rows: the batch
                // may never have been seen at all. Every index is non-terminal.
                verdicts.transportThrew = true
                verdicts.nonterminalIndexes = Set(posted.indices)
            }
            return await settle(posted, verdicts, admitted: lease)
        }

        /// What one page's responses proved, index by index.
        ///
        /// The uploader already ran `MeasurementBatchAcceptance.validate`, so a
        /// returned outcome means every posted index carried terminal evidence.
        /// One reason survives that gate and still is not progress: the server
        /// cannot map the identifier yet. Every other terminal skip is a refusal
        /// the person must be able to see, so it is collected for the skip
        /// register (#113).
        private struct PageVerdicts {
            var accepted = 0
            var nonterminalIndexes: Set<Int> = []
            var refused: [HealthKitSkippedEntry] = []
            var transportThrew = false

            init() {}

            init(_ outcomes: [BatchUploadOutcome]) {
                var offset = 0
                for outcome in outcomes {
                    for verdict in outcome.rowVerdicts {
                        if verdict.isStored {
                            accepted += 1
                        } else if verdict.status == .skipped {
                            if verdict.reason == HealthKitServerSupportConfig.reasonUnmappableIdentifier {
                                nonterminalIndexes.insert(offset + verdict.index)
                            } else {
                                refused.append(
                                    HealthKitSkippedEntry(entry: outcome.chunk[verdict.index], reason: verdict.reason ?? "unknown")
                                )
                            }
                        }
                    }
                    offset += outcome.chunk.count
                }
            }
        }

        /// Turns the verdicts into the page outcome: registers the refused rows,
        /// writes the durable retry for the rest, and tallies what happened.
        private func settle(
            _ posted: [HealthKitBatchEntryDTO],
            _ verdicts: PageVerdicts,
            admitted lease: HealthSyncAuthenticatedLease?
        ) async -> (outcome: HealthSyncPageOutcome, tally: HealthSampleServerTally) {
            let entries = posted.indices.map { index in
                HealthSyncEntryOutcome(
                    index: index,
                    stableIdentity: posted[index].externalId,
                    classification: verdicts.nonterminalIndexes.contains(index) ? .nonterminal : .terminalAccepted
                )
            }

            // #113 — a refused row may be passed only once it is remembered. If it
            // cannot be (no register, no owner, a write that did not verify), the
            // page holds: the next wake re-reads it, the server folds everything it
            // already stored on `externalId`, and the refusal is tried again.
            let registered = await registerRefused(verdicts.refused, requiring: lease)
            var tally = HealthSampleServerTally(accepted: verdicts.accepted, skipped: registered ? verdicts.refused.count : 0)

            // Without an admission there is no owner to attribute a retry row to,
            // and stamping the ambient account onto one person's samples is the
            // exact harm Wave 1 closed on the queue. The page then stays
            // unaccounted for and the caller holds.
            let pending = verdicts.nonterminalIndexes.sorted().map { posted[$0] }
            let attempted = !pending.isEmpty && lease != nil && retry != nil
            let persisted = attempted ? await persistRetry(pending, requiring: lease) : false
            if persisted {
                tally.parked = pending.count
            }
            let outcome = HealthSyncPageOutcome(
                postedCount: posted.count,
                entries: entries,
                transportThrew: verdicts.transportThrew,
                durableRetryPersisted: persisted,
                durableRetryFailed: (attempted && !persisted) || !registered,
                leaseIsCurrent: lease?.isCurrent ?? true,
                wasCancelled: pending.isEmpty ? false : Task.isCancelled
            )
            return (outcome, tally)
        }

        /// Writes the page's refused rows into the skip register under the
        /// admitted owner. `true` when there was nothing to write or the write
        /// verified.
        private func registerRefused(
            _ refused: [HealthKitSkippedEntry],
            requiring lease: HealthSyncAuthenticatedLease?
        ) async -> Bool {
            guard !refused.isEmpty else { return true }
            guard let skipRegister, let lease else { return false }
            do {
                try await lease.admitting {
                    try await skipRegister.record(refused, ownerID: lease.ownerID, build: build)
                }
                return true
            } catch {
                // Count only — no value, no identifier, no owner.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    "skip register write failed for \(refused.count, privacy: .public) row(s) — cursor holds"
                )
                return false
            }
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
