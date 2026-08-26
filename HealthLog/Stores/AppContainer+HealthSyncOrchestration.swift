import Foundation

// Phase 07 Wave 5 — the routing half of the orchestrator.
//
// `AppContainer+HealthSyncOrchestrator.swift` builds the one orchestrator and
// installs it behind `AppOwnedHealthCollection`. This file is the other end:
// the single named entry every inventoried trigger uses, and the wiring that
// hands that entry to the two objects which own triggers of their own (the
// background coordinator and the HealthKit readiness store).
//
// What this file removes is as important as what it adds. Through Wave 4 the
// orchestrated pass ran *in addition to* the direct call sites: a foreground
// tick fired `.foreground` through `SpeziCollectionTrigger` **and**
// `AppContainer.refreshHealthKitDailyStatsForToday`, which fans out to daily
// stats, HR buckets, nutrients, ECG and medications; "Jetzt syncen" fired
// `.manual` **and** the split manual hook; the BGProcessing wake fired
// `.processing` **and** four coordinator hooks. Every duplicated call is
// idempotent, and every one of them was still a second set of HealthKit reads,
// a second set of POSTs and a second slice of a background grant. One trigger is
// now one pass.

@MainActor
extension AppContainer {
    /// The single named entry into the one orchestrated pass.
    ///
    /// Every row of `07-TRIGGER-OWNERSHIP.md` that starts collection reaches
    /// HealthKit through this method and through nothing else. It resolves the
    /// trigger's plan, its budget, and its account admission exactly once, and
    /// answers with the capabilities the pass named — so a caller can report what
    /// a wake reached rather than that it happened.
    ///
    /// - Parameters:
    ///   - trigger: the `HealthSyncTrigger` this call site starts work for.
    ///   - observedSource: for an observer signal, the one source that fired. The
    ///     pass resolves to exactly that capability and never fans out.
    ///   - isExpired: the caller's own window. `BackgroundSyncCoordinator` passes
    ///     its `BGTask.expirationHandler` flag, so a wake iOS is about to
    ///     terminate stops admitting and names the remainder `expired` instead of
    ///     being cut off mid-sweep.
    @discardableResult
    func runHealthSyncPass(
        _ trigger: HealthSyncTrigger,
        observedSource: HealthSyncSource? = nil,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> [HealthSyncCapability] {
        // Arm SpeziHealthKit's `start: .manual` collectors first. That module is
        // still registered and still owns authorization; a collector nobody
        // triggers pulls nothing. Arming is not a pass, which is exactly the
        // distinction that was missing while `runOneShotAnchorSweep` started one.
        await healthKit?.runBackgroundSyncPass()
        return await SpeziCollectionTrigger.run(
            trigger,
            observedSource: observedSource,
            isExpired: isExpired
        )
    }
}
