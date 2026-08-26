import Foundation

// Phase 07 / Plan 07-04 — the acceptance gate for `POST /api/measurements/batch`.
//
// Split out of `MeasurementBatchUploader.swift` because three production paths
// now run it and only one of them is the uploader: the online batch POST, the
// outbox replay (`OutboxReplayService+HealthKit`), and the daily-statistics
// sweep (`HealthKitStatisticsSyncCoordinator`). A rule three callers share
// should not live inside one of them.

/// Privacy-safe failure for an HTTP-successful measurement batch whose
/// per-entry response does not prove exact, complete acceptance.
public struct MeasurementBatchAcceptanceError: Error, Sendable, Equatable, CustomStringConvertible {
    public let postedCount: Int
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let missingCount: Int
    public let duplicateIndexCount: Int
    public let outOfRangeIndexCount: Int
    public let aggregateMismatch: Bool

    public var description: String {
        "measurement batch not fully accepted "
            + "(posted=\(postedCount), accepted=\(acceptedCount), rejected=\(rejectedCount), "
            + "missing=\(missingCount), duplicateIndices=\(duplicateIndexCount), "
            + "outOfRangeIndices=\(outOfRangeIndexCount), aggregateMismatch=\(aggregateMismatch))"
    }
}

/// Exact indexed, reason-aware acceptance gate for `POST /api/measurements/batch`.
///
/// **Phase 07 / Plan 07-04.** HTTP 200 proves that the envelope arrived, nothing
/// more. This gate is the only place that decides whether a posted index carried
/// terminal evidence, and it is deliberately fail-closed: a row this build cannot
/// classify holds the cursor rather than being assumed accepted.
///
/// Three rules are explicit rather than emergent:
///
///   * **The status vocabulary is exact.** `inserted`, `updated` and `duplicate`
///     are terminal; `failed` and `unknown` hold. A word the build cannot name
///     decodes to `.unknown` and therefore holds — tolerant decoding never
///     becomes tolerant acceptance.
///   * **`skipped` is terminal only for an allowlisted reason.** The allowlist is
///     the per-route ``Policy``. A reason this build has never heard of — and a
///     skip with no reason at all — holds, because "the server declined to write
///     it and would not say why" is not evidence that a retry is pointless.
///   * **`superseded_in_batch` is terminal only against a real successor.** An
///     earlier `duplicate` carrying that reason is accepted iff its stable
///     `stats:<type>:<day>` identity appears again at a *later* index of the same
///     submitted batch and that later index is itself terminal (`inserted` or
///     `updated`). Missing, reordered, mismatched, non-stat, repeated or
///     nonterminal successors all hold.
public enum MeasurementBatchAcceptance {
    /// The reason vocabulary this gate classifies against.
    ///
    /// Duplicated as literals rather than imported from
    /// `HealthKitServerSupportConfig` / `DeployedMeasurementContract`, because
    /// both of those live in the iOS-only HealthKit module while this gate is
    /// part of the platform-free core. `MeasurementBatchAcceptanceReasonPinTests`
    /// asserts the two spellings never drift.
    public enum Reason {
        /// The server's mapper does not know this HK identifier yet.
        public static let unmappableIdentifier = "unmappable_identifier"
        /// The value is outside the server's plausibility band.
        public static let valueOutOfRange = "value_out_of_range"
        /// Since v1.32.37 — the `externalId` is not stable enough to dedupe on.
        public static let unstableExternalId = "unstable_external_id"
        /// v1.37.12 — an earlier `stats:` row lost to a later row of the same
        /// stable identity in the same request.
        public static let supersededInBatch = "superseded_in_batch"
    }

    /// The prefix of a mutable daily-statistics upsert identity
    /// (`stats:<HKQuantityTypeIdentifier>:<YYYY-MM-DD>`).
    ///
    /// Supersession is a property of the *row*, not of the calling route: only a
    /// stable stats identity can legitimately be superseded inside one request,
    /// because only it is an upsert key. A per-sample UUID cannot.
    public static let stableStatIdentityPrefix = "stats:"

    /// The per-route terminal policy.
    ///
    /// Only the skip-reason allowlist is route-dependent: an importer knows
    /// which deterministic refusals it can never resolve by retrying. Everything
    /// else in this gate is derived from the response and the submitted rows.
    public struct Policy: Sendable, Equatable {
        /// Skip reasons that are terminal — a retry provably cannot change them.
        public let terminalSkipReasons: Set<String>

        public init(terminalSkipReasons: Set<String>) {
            self.terminalSkipReasons = terminalSkipReasons
        }

        /// The deployed `POST /api/measurements/batch` route.
        ///
        /// All three documented reasons are terminal *for the batch envelope*.
        /// `unmappable_identifier` is deliberately among them: the batch is
        /// complete, and the per-sample importers hold that single index
        /// separately (see `HealthSampleConsumption`), which keeps a page of 500
        /// from retrying because one row named a type the server cannot map yet.
        public static let deployedMeasurementRoute = Policy(terminalSkipReasons: [
            Reason.unmappableIdentifier,
            Reason.valueOutOfRange,
            Reason.unstableExternalId
        ])
    }

    /// Per-index classification of one response against one submitted batch.
    public struct Verdict: Sendable, Equatable {
        public let postedCount: Int
        /// Indexes that carried terminal evidence.
        public let terminalIndexes: Set<Int>
        /// Indexes the server answered for, but not terminally.
        public let nonterminalIndexes: Set<Int>
        /// Indexes the server did not answer for at all.
        public let missingIndexes: Set<Int>
        public let duplicateIndexCount: Int
        public let outOfRangeIndexCount: Int

        /// `true` only when every posted index appears exactly once and every
        /// one of them is terminal.
        public var isCompletelyAccepted: Bool {
            nonterminalIndexes.isEmpty
                && missingIndexes.isEmpty
                && duplicateIndexCount == 0
                && outOfRangeIndexCount == 0
        }

        var error: MeasurementBatchAcceptanceError {
            MeasurementBatchAcceptanceError(
                postedCount: postedCount,
                acceptedCount: terminalIndexes.count,
                rejectedCount: nonterminalIndexes.count,
                missingCount: missingIndexes.count,
                duplicateIndexCount: duplicateIndexCount,
                outOfRangeIndexCount: outOfRangeIndexCount,
                aggregateMismatch: false
            )
        }
    }

    /// One posted index reconciled with whatever the response said about it.
    private struct ResolvedRow {
        var status: HealthKitEntryStatus
        var reason: String?
    }

    /// Throws unless every posted index carried exact terminal evidence.
    ///
    /// - Parameters:
    ///   - postedCount: how many rows were submitted.
    ///   - postedExternalIds: the submitted rows' stable external ids, in
    ///     submission order. Production always supplies them; they are what makes
    ///     the `superseded_in_batch` rule verifiable rather than structural. When
    ///     `nil` (or the wrong length) the gate can still reject everything else,
    ///     but it can only check that a supersession has *some* later terminal
    ///     row — it cannot check that the identity actually matches.
    public static func validate(
        postedCount: Int,
        postedExternalIds: [String]? = nil,
        response: HealthKitBatchResponseDTO,
        policy: Policy = .deployedMeasurementRoute
    ) throws {
        let verdict = classify(
            postedCount: postedCount,
            postedExternalIds: postedExternalIds,
            response: response,
            policy: policy
        )
        guard verdict.isCompletelyAccepted else { throw verdict.error }
    }

    /// The full per-index classification. Callers that need to hold *some* rows
    /// while committing others read this instead of catching the throw.
    public static func classify(
        postedCount: Int,
        postedExternalIds: [String]? = nil,
        response: HealthKitBatchResponseDTO,
        policy: Policy = .deployedMeasurementRoute
    ) -> Verdict {
        let expectedCount = max(0, postedCount)
        let identities: [String]? = postedExternalIds?.count == expectedCount ? postedExternalIds : nil

        var rows: [Int: ResolvedRow] = [:]
        var duplicateIndexCount = 0
        var outOfRangeIndexCount = 0

        for entry in response.entries {
            guard (0 ..< expectedCount).contains(entry.index) else {
                outOfRangeIndexCount += 1
                continue
            }
            guard rows[entry.index] == nil else {
                duplicateIndexCount += 1
                continue
            }
            rows[entry.index] = ResolvedRow(status: entry.status, reason: entry.reason)
        }

        // Some released server versions report a terminal refusal only in
        // `skipped[]`, while newer versions mirror it in `entries[]` as well.
        // Treat either shape as indexed evidence, without counting the normal
        // mirrored form as a repeat — but a `skipped[]` index that repeats
        // *within that array* is a repeat, and holds.
        var seenSkipped = Set<Int>()
        for skipped in response.skipped {
            guard (0 ..< expectedCount).contains(skipped.index) else {
                outOfRangeIndexCount += 1
                continue
            }
            guard seenSkipped.insert(skipped.index).inserted else {
                duplicateIndexCount += 1
                continue
            }
            if var existing = rows[skipped.index] {
                // The mirrored form. Adopt the reason when `entries[]` omitted
                // it, so a reason carried in only one of the two arrays still
                // reaches the allowlist.
                if existing.status == .skipped, existing.reason == nil {
                    existing.reason = skipped.reason
                    rows[skipped.index] = existing
                }
            } else {
                rows[skipped.index] = ResolvedRow(status: .skipped, reason: skipped.reason)
            }
        }

        var terminalIndexes = Set<Int>()
        var nonterminalIndexes = Set<Int>()
        var missingIndexes = Set<Int>()

        for index in 0 ..< expectedCount {
            guard let row = rows[index] else {
                missingIndexes.insert(index)
                continue
            }
            if isTerminal(row, at: index, rows: rows, identities: identities, policy: policy) {
                terminalIndexes.insert(index)
            } else {
                nonterminalIndexes.insert(index)
            }
        }

        return Verdict(
            postedCount: expectedCount,
            terminalIndexes: terminalIndexes,
            nonterminalIndexes: nonterminalIndexes,
            missingIndexes: missingIndexes,
            duplicateIndexCount: duplicateIndexCount,
            outOfRangeIndexCount: outOfRangeIndexCount
        )
    }

    private static func isTerminal(
        _ row: ResolvedRow,
        at index: Int,
        rows: [Int: ResolvedRow],
        identities: [String]?,
        policy: Policy
    ) -> Bool {
        switch row.status {
        case .inserted, .updated:
            return true
        case .duplicate:
            guard row.reason == Reason.supersededInBatch else { return true }
            return hasTerminalSuccessor(of: index, rows: rows, identities: identities)
        case .skipped:
            guard let reason = row.reason else { return false }
            return policy.terminalSkipReasons.contains(reason)
        case .failed, .unknown:
            return false
        }
    }

    /// The `superseded_in_batch` rule.
    ///
    /// A later row of the same request won, so the earlier row's *value* is
    /// genuinely in the server state — but only if that later row exists, is a
    /// later index, carries the same stable stats identity, and was itself
    /// written. Anything else and this index has no evidence at all.
    private static func hasTerminalSuccessor(
        of index: Int,
        rows: [Int: ResolvedRow],
        identities: [String]?
    ) -> Bool {
        guard let identities else {
            // Identity-unverifiable shape (contract inspection). Structure only.
            return rows.contains { later, row in
                later > index && (row.status == .inserted || row.status == .updated)
            }
        }
        guard identities.indices.contains(index) else { return false }
        let identity = identities[index]
        guard identity.hasPrefix(stableStatIdentityPrefix) else { return false }
        return identities.indices.contains { later in
            later > index
                && identities[later] == identity
                && (rows[later]?.status == .inserted || rows[later]?.status == .updated)
        }
    }
}
