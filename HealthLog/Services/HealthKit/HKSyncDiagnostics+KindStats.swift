import Foundation

// Split out of `HKSyncDiagnostics.swift` (type_body_length) when #113 added the
// skipped / parked / handed-off counters. Pure move plus those three fields.

public extension HKSyncDiagnostics {
    /// Per-kind counters. All ints monotonically increase across the session;
    /// timestamps are last-event semantics.
    struct KindStats: Sendable, Equatable {
        public var identifier: String
        /// Total foreign samples HK has handed us this session via the
        /// observer/anchor pipeline.
        public var samplesReadTotal: Int = 0
        /// Subset of `samplesReadTotal` the server stored (`inserted`,
        /// `updated`, `duplicate`). Nothing else counts (#113).
        public var samplesUploadedTotal: Int = 0
        /// Rows the server refused for a deterministic reason
        /// (`value_out_of_range`, …). They sit in the skip register.
        public var samplesSkippedTotal: Int = 0
        /// Rows the server could not take yet; they wait in the outbox.
        public var samplesParkedTotal: Int = 0
        /// Rows the daily-statistics or HR-bucket path owns instead.
        public var samplesHandedOffTotal: Int = 0
        /// HK-STATS aggregator counters — only populated for the 5 cumulative
        /// kinds that flow over `HealthKitStatisticsSyncCoordinator`.
        public var statsPostedTotal: Int = 0
        /// Later upserts of an already-posted `stats:<type>:<day>` row.
        public var statsRepostedTotal: Int = 0
        /// Last time the observer/anchor query fired for this identifier
        /// with samples >= 0 (zero-sample wakeups still count — they are
        /// proof of life for the observation pipeline).
        public var lastObservationAt: Date?
        /// Last time an anchor advance actually persisted — that is the
        /// concrete proof that an upload round-trip succeeded.
        public var lastAnchorAdvancedAt: Date?
        /// Last time the HK-STATS path posted or upserted for this identifier.
        public var lastStatsActionAt: Date?

        public init(identifier: String) {
            self.identifier = identifier
        }

        /// Merge two entries (used by `snapshotByKind` to combine BP-sys +
        /// BP-dia into a single `.bloodPressure` row). Counters add; dates
        /// pick the most recent.
        func merging(_ other: KindStats) -> KindStats {
            var merged = self
            merged.samplesReadTotal += other.samplesReadTotal
            merged.samplesUploadedTotal += other.samplesUploadedTotal
            merged.samplesSkippedTotal += other.samplesSkippedTotal
            merged.samplesParkedTotal += other.samplesParkedTotal
            merged.samplesHandedOffTotal += other.samplesHandedOffTotal
            merged.statsPostedTotal += other.statsPostedTotal
            merged.statsRepostedTotal += other.statsRepostedTotal
            merged.lastObservationAt = Self.latest(lastObservationAt, other.lastObservationAt)
            merged.lastAnchorAdvancedAt = Self.latest(lastAnchorAdvancedAt, other.lastAnchorAdvancedAt)
            merged.lastStatsActionAt = Self.latest(lastStatsActionAt, other.lastStatsActionAt)
            return merged
        }

        private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
            switch (lhs, rhs) {
            case let (.some(a), .some(b)): max(a, b)
            case let (.some(a), nil): a
            case let (nil, .some(b)): b
            case (nil, nil): nil
            }
        }
    }
}
