import Foundation

// U1 (#16) — the one write path for `lastServerAcceptance`.
//
// Every recorder that hears the server accept Apple Health data calls this:
// `recordObservation` (rows the server stored), `recordStatsAction` (a posted
// or upserted day total), `recordWorkoutResponse` (accepted workouts) and
// `recordHealthSyncPass` (a pass whose capabilities settled items). The
// orchestrator's report already funnels every trigger — foreground, manual,
// BGProcessing, BGAppRefresh, silent push, observer — so between them these
// four cover the background uploads that never moved the last-sync time.

extension HKSyncDiagnostics {
    /// Record that the server accepted Apple Health data at `date`.
    ///
    /// Monotonic: a late hop to the main actor carrying an older timestamp
    /// must not move the last-sync time backwards.
    func noteServerAcceptance(at date: Date, channel: SyncChannel = .current) {
        if let previous = lastServerAcceptance, previous.at > date { return }
        lastServerAcceptance = SyncActivity(at: date, channel: channel)
        persistServerAcceptance()
    }
}
