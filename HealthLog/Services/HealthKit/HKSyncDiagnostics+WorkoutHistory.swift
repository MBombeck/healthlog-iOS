import Foundation

// #17 — the operator-visible half of the workout history catch-up.
//
// This is the one value the Sync Diagnostics surface binds to: whether an
// older workout history is still being imported and, when known, about how
// many workouts are left. Counts and a timestamp only — no workout, value or
// identifier can be represented here.

public extension HKSyncDiagnostics {
    struct WorkoutHistoryImportStatus: Codable, Sendable, Equatable {
        /// `true` while the anchored import has not yet passed the newest
        /// workout. Recent workouts may already be on the server meanwhile.
        public var isImporting: Bool
        /// Workouts still waiting behind the anchor, excluding the recent ones
        /// already delivered ahead of it. `nil` while importing but not yet
        /// counted; `0` once caught up.
        public var remainingEstimate: Int?
        public var updatedAt: Date

        public init(isImporting: Bool, remainingEstimate: Int?, updatedAt: Date = Date()) {
            self.isImporting = isImporting
            self.remainingEstimate = remainingEstimate
            self.updatedAt = updatedAt
        }
    }

    /// Records the importer's latest proven backlog state. `nil` clears it.
    func recordWorkoutHistoryImport(_ status: WorkoutHistoryImportStatus?) {
        workoutHistoryImport = status
        persistWorkoutHistoryImport()
    }
}
