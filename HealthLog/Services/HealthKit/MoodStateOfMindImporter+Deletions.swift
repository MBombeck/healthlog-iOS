#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // State of Mind samples deleted in Apple Health leave the server too
    // (contract §3, `DELETE /api/mood-entries/by-external-ids`). Only entries
    // imported with their source pair can be matched; the route ignores the
    // rest. A deletion that cannot be sent holds the page, and HealthKit
    // reports it again with the next read.

    extension MoodStateOfMindImporter {
        /// `nil` when the deletions are sent, refused for good, or not due
        /// (no route yet, nothing deleted, or a page that holds anyway).
        func forwardDeletions(
            _ deletedIDs: [String],
            after page: HealthSyncPageOutcome,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            guard HealthSyncCursorPolicy.installed.decide(page) == .commit else { return nil }
            // While the route is closed the deletions wait in their own list,
            // so the anchor may move without losing them.
            let all = AppleHealthPendingDeletions.toSend(
                deletedIDs,
                .mood,
                ownerID: lease.ownerID,
                routeOpen: AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: defaults),
                defaults: defaults
            )
            guard !all.isEmpty else { return nil }
            do {
                for start in stride(from: 0, to: all.count, by: AppleHealthDeleteDomain.maxIDsPerRequest) {
                    let end = min(start + AppleHealthDeleteDomain.maxIDsPerRequest, all.count)
                    try await repo.deleteAppleHealthEntries(Array(all[start ..< end]))
                }
                AppleHealthPendingDeletions.clear(.mood, ownerID: lease.ownerID, defaults: defaults)
                return nil
            } catch where AppleHealthDeleteRefusal.isFinal(error) {
                AppleHealthPendingDeletions.clear(.mood, ownerID: lease.ownerID, defaults: defaults)
                return nil
            } catch {
                return .serverUnreachable
            }
        }
    }

    /// One anchored State of Mind read. Immutable after delivery.
    struct MoodAnchoredPage: @unchecked Sendable {
        let samples: [HKStateOfMind]
        let deletedIDs: [String]
        let newAnchor: HKQueryAnchor?
    }
#endif
