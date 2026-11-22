import Foundation

// The operator-visible half of an orchestrated pass.
//
// Split out of `HKSyncDiagnostics.swift` for file/type length, and safe to
// split: no Wave-0 assertion reads that file as source text, which is the trap
// Plan 07-06 recorded when a `type_body_length` split moved the symbols three
// REDs were reading into a sibling file.
//
// Everything here is a fixed enum case name, a cardinality, or a timestamp. The
// two withheld-item counts close the operator gap Plans 07-04 and 07-05 both
// handed forward: `AppleHealthDoseLedger.pendingIdentities().count` and
// `HealthKitDailyStatsCache.quarantinedLegacyRowCount()` were numbers only a
// debugger could see.

public extension HKSyncDiagnostics {
    /// Operator-grade only: fixed enum case names, cardinalities, timestamps.
    /// No sample, value, identifier, or account can be represented here.
    struct HealthSyncSnapshot: Codable, Sendable, Equatable {
        /// The trigger of the last finished pass (`manual`, `processing`, …).
        public var lastPassTrigger: String?
        public var lastPassAt: Date?
        public var lastPassWasComplete = false
        public var lastPassHeldItems = 0
        /// Capabilities the last pass could not admit an account for.
        public var lastPassRefusedForMissingAdmission: [String] = []
        /// Cumulative refusals for a missing admission across the session.
        ///
        /// A non-zero value on a signed-in device says the app never told the
        /// authenticated-session registry who is signed in — see
        /// `HealthSyncCompositionPlan.installedActivatesSessionRegistry`.
        public var admissionRefusalsTotal = 0
        /// `HealthSyncDisposition` case name → cumulative count.
        public var dispositionTotals: [String: Int] = [:]
        /// `HealthSyncHoldReason` case name → cumulative count. Plan 07-06 added
        /// two hold-reason log lines that nothing counted; this is the counter.
        public var holdReasonTotals: [String: Int] = [:]
        /// Apple-Health doses the ledger is still waiting to account for
        /// (plan 07-05). Unbounded in principle, which is why it is visible.
        public var pendingAppleDoseCount = 0
        /// Ownerless legacy daily-stat rows held in quarantine.
        public var quarantinedLegacyRowCount = 0
        public var withheldCountsSampledAt: Date?
        /// HealthKit identifiers whose cursor partition stayed closed in the
        /// last pass that looked at them, with why. Optional so a snapshot
        /// persisted by an earlier build still decodes (its counters must survive).
        var lockedPartitions: [String: HealthSyncPartitionLockReason]?
        /// Background passes (processing, app refresh, silent push, observer)
        /// that found no signed-in session for at least one capability: the
        /// evidence for a cold background start that never activated the
        /// session. Optional for the same decoding reason.
        public var backgroundPassesWithoutSession: Int?

        public init() {}
    }

    // MARK: - Orchestrated pass diagnostics

    /// Record one finished orchestrated pass.
    ///
    /// Counts every capability's disposition and hold reason, and accumulates
    /// the admission refusals separately — a HealthKit pass in which nine
    /// capabilities report `notAdmitted` is a very different fact from one in
    /// which nine report `disabled`, and before this counter existed the two
    /// were both "the log was quiet".
    func recordHealthSyncPass(_ snapshot: HealthSyncPassSnapshot, at date: Date = Date()) {
        healthSync.lastPassTrigger = snapshot.trigger
        healthSync.lastPassAt = date
        healthSync.lastPassWasComplete = snapshot.isComplete
        healthSync.lastPassHeldItems = snapshot.heldItemCount
        let refused = snapshot.capabilitiesRefusedForMissingAdmission
        healthSync.lastPassRefusedForMissingAdmission = refused
        healthSync.admissionRefusalsTotal += refused.count
        if !refused.isEmpty, Self.backgroundTriggers.contains(snapshot.trigger) {
            healthSync.backgroundPassesWithoutSession = (healthSync.backgroundPassesWithoutSession ?? 0) + 1
        }
        for capability in snapshot.capabilities {
            healthSync.dispositionTotals[capability.disposition, default: 0] += 1
            if let reason = capability.holdReason {
                healthSync.holdReasonTotals[reason, default: 0] += 1
            }
        }
        noteActivity(at: date)
        persistHealthSync()
        // A pass that settled items reached the server. Most
        // capabilities report `ran` without counts and are stamped by their own
        // recorders instead; this catches the ones that do count.
        if snapshot.capabilities.contains(where: { $0.itemsSettled > 0 }) {
            noteServerAcceptance(at: date)
        }
    }

    /// The pass triggers iOS starts without anyone opening the app.
    static let backgroundTriggers: Set<String> = [
        HealthSyncTrigger.processing.rawValue,
        HealthSyncTrigger.appRefresh.rawValue,
        HealthSyncTrigger.silentPush.rawValue,
        HealthSyncTrigger.observer.rawValue
    ]

    /// The live leg's word on which of the `checked` types stayed locked.
    /// Types it did not check keep their last state; nothing is written when
    /// nothing changed, which is every pass on a healthy device.
    internal func recordLockedPartitions(_ locked: [String: HealthSyncPartitionLockReason], checked: [String]) {
        let before = healthSync.lockedPartitions ?? [:]
        var after = before.filter { !checked.contains($0.key) }
        after.merge(locked) { _, new in new }
        guard after != before else { return }
        healthSync.lockedPartitions = after.isEmpty ? nil : after
        persistHealthSync()
    }

    /// Record the two "this account is still owed N things" counts.
    ///
    /// Called by the paths that already hold the numbers — the Apple-medication
    /// sweep, which owns the dose ledger, and the daily-statistics sweep, which
    /// owns the cache. Both were previously readable only from a debugger.
    /// `nil` leaves the previous value alone, so a sweep that ran only one of
    /// the two does not zero the other.
    func recordWithheldCounts(
        pendingAppleDoses: Int? = nil,
        quarantinedLegacyRows: Int? = nil,
        at date: Date = Date()
    ) {
        if let pendingAppleDoses {
            healthSync.pendingAppleDoseCount = max(0, pendingAppleDoses)
        }
        if let quarantinedLegacyRows {
            healthSync.quarantinedLegacyRowCount = max(0, quarantinedLegacyRows)
        }
        healthSync.withheldCountsSampledAt = date
        persistHealthSync()
    }
}
