import Foundation

enum WorkoutHRBackfillRearmTrigger: Sendable {
    case acceptedSeriesOmission
    case authorizationRefresh
}

/// **GH #86** — per-user persistence for ``WorkoutHRBackfillState``.
///
/// One JSON blob under `hl.workout.hrBackfill.<userId-token>`. UserDefaults
/// for the same reason the HK anchors live there (PROJECT_GUIDE.md battery
/// rationale): a backfill cursor is not a secret, and it is read/written on
/// every sweep chunk. The partition token is shared with
/// ``HealthKitBackfillWindowStore`` so a logout / re-login with a different
/// account never inherits the previous user's progress.
///
/// A blob that fails to decode reads as a FRESH state (not as "done") — the
/// worst case is that the sweep re-walks history it has already enriched,
/// which the server answers as a no-op. Losing progress is cheap; falsely
/// concluding "finished" would silently drop the whole backfill.
enum WorkoutHRBackfillStore {
    static let defaultsKeyPrefix = "hl.workout.hrBackfill."

    static func key(for userID: String?) -> String {
        defaultsKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userID)
    }

    static func load(for userID: String?, defaults: UserDefaults = .standard) -> WorkoutHRBackfillState {
        guard let data = defaults.data(forKey: key(for: userID)),
              let state = try? JSONDecoder().decode(WorkoutHRBackfillState.self, from: data) else
        {
            return WorkoutHRBackfillState()
        }
        return state
    }

    static func save(
        _ state: WorkoutHRBackfillState,
        for userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(state) else {
            HLLog.healthKit.error("workout HR backfill state encode failed — progress not persisted")
            return
        }
        defaults.set(data, forKey: key(for: userID))
    }

    /// One synchronous, partitioned read-modify-write entry point for every
    /// event that makes a prior empty history read stale.
    @discardableResult
    static func rearm(
        for userID: String?,
        trigger: WorkoutHRBackfillRearmTrigger,
        defaults: UserDefaults = .standard,
        leaseIsCurrent: @Sendable () -> Bool = { true }
    ) -> Bool {
        guard leaseIsCurrent() else { return false }
        var state = load(for: userID, defaults: defaults)
        switch trigger {
        case .acceptedSeriesOmission:
            if state.isDone || state.nextExhaustionProbeAt != nil {
                state.cursor = nil
                state.restartFromNewestAfterCurrentWalk = false
            } else if state.cursor != nil {
                state.restartFromNewestAfterCurrentWalk = true
            }
        case .authorizationRefresh:
            break
        }
        state.isDone = false
        state.nextExhaustionProbeAt = nil
        guard leaseIsCurrent() else { return false }
        save(state, for: userID, defaults: defaults)
        return true
    }

    /// Logout cleanup — the next user starts their own walk.
    static func clear(for userID: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: userID))
    }
}
