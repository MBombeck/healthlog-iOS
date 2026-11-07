import Foundation
import Observation

/// **1.5 ROUTES — the route counters of Sync Diagnostics.**
///
/// Counts only, for this app session: routes attached to a workout batch,
/// how many of them were thinned to the server's point cap (never a silent
/// cut), and route reads that failed or ran out of time (the workout went
/// out without its route). No position, time or workout identifier is kept.
@MainActor
@Observable
final class WorkoutRouteDiagnostics {
    static let shared = WorkoutRouteDiagnostics()

    private(set) var attached = 0
    private(set) var thinned = 0
    private(set) var failed = 0

    var hasActivity: Bool {
        attached + failed > 0
    }

    func recordAttached(thinned wasThinned: Bool) {
        attached += 1
        if wasThinned { thinned += 1 }
    }

    func recordFailure() {
        failed += 1
    }

    func reset() {
        attached = 0
        thinned = 0
        failed = 0
    }
}
