import Foundation

// Phase 07 Wave 0 — the frozen inventory of every direct HealthKit trigger and
// every HealthKit construction/teardown seam in the app.
//
// The rows are the executable twin of
// `.planning/phases/07-healthkit-durability-and-complete-sync/07-TRIGGER-OWNERSHIP.md`.
// `CompleteHealthSyncCompositionTests` proves each row still names a real file
// and symbol and that the markdown and this table agree; the routing suite
// proves each row enters orchestration exactly once. A row may only move from
// `.direct` to `.orchestrated` together with the production change that routes
// it.

/// One direct trigger or construction seam with its exact Phase-07 owner.
struct HealthSyncTriggerOwnership: Sendable, Equatable, Hashable {
    /// Whether the seam already enters the single Phase-07 orchestrator.
    enum Routing: String, Sendable {
        /// Reaches importers through the orchestrator, once, with a lease.
        ///
        /// **Plan 07-09 — what "through the orchestrator" means for each of the
        /// three kinds of row this inventory holds.**
        ///
        ///   * A **pull trigger** (`coldActivation`, `postAuthentication`,
        ///     `foreground`, `manual`, `silentPush`, `appRefresh`, `processing`)
        ///     names its `HealthSyncTrigger` and enters
        ///     `AppContainer.runHealthSyncPass` once. It decides nothing about
        ///     *what* runs; the plan, the budget and the admission are the
        ///     orchestrator's single answer.
        ///   * A **construction seam** (`makeHealthKitInfra`,
        ///     `wireWorkoutBackgroundSync`, the two backfill-cutoff seams) builds
        ///     or installs; it starts no work of its own, and what it builds is
        ///     reached only through the one pass.
        ///   * An **observer** and an **account teardown** reach the importer
        ///     that owns them — under the same admitted `HealthSyncOwnerLease`,
        ///     the same `HealthSyncCursorPolicy`, and the same coalescer — rather
        ///     than through `run(_:)`. That is deliberate and it is the honest
        ///     reading of "once, with a lease": an observer pass plans exactly
        ///     the signalled source (`required(for: .observer)` is empty), and
        ///     routing a heart-rate signal into a complete pass would be a
        ///     fan-out this phase exists to prevent. Teardown is Phase 06's
        ///     awaited orchestrator, which is the same statement for the
        ///     opposite direction.
        case orchestrated
        /// Calls importers, collectors, or resets on its own today.
        case direct
    }

    let id: String
    let file: String
    let symbol: String
    let trigger: HealthSyncTrigger
    let ownerPlan: String
    let testIdentifier: String
    let routing: Routing
}

enum HealthSyncTriggerInventory {
    /// Bounded `rg`-backed inventory. Zero rows may be unassigned, and every
    /// row carries the suite that will hold it.
    static let rows: [HealthSyncTriggerOwnership] = [
        make("T-01", "HealthLog/App/RootView.swift", "activateHealthKitBackgroundIfReady", .coldActivation, "07-09", routing),
        make("T-02", "HealthLog/App/RootView.swift", "restoreHealthKitBackfillWindow", .coldActivation, "07-03", composition),
        make("T-03", "HealthLog/App/ForegroundPassPlan.swift", "healthKitStats", .foreground, "07-09", routing),
        make(
            "T-04",
            "HealthLog/Screens/Onboarding/HealthKitPermissionStep.swift",
            "setHealthKitBackfillWindow",
            .coldActivation,
            "07-03",
            composition
        ),
        make(
            "T-05",
            "HealthLog/Screens/Onboarding/HealthKitPermissionStep.swift",
            "activateHealthKitBackground",
            .postAuthentication,
            "07-09",
            routing
        ),
        make("T-06", "HealthLog/Stores/HKReadinessStore.swift", "triggerManualSync", .manual, "07-09", routing),
        make("T-07", "HealthLog/Stores/HKReadinessStore.swift", "requestAuthorization", .postAuthentication, "07-09", routing),
        make("T-08", "HealthLog/Stores/AppContainer+Wiring.swift", "attachHealthSyncRoute", .manual, "07-09", routing),
        make(
            "T-09",
            "HealthLog/Services/NotificationService+Registration.swift",
            "runHealthSyncPass",
            .silentPush,
            "07-09",
            routing
        ),
        make("T-10", "HealthLog/Services/BackgroundSyncCoordinator.swift", "runBGRefreshPassesBody", .appRefresh, "07-09", routing),
        make("T-11", "HealthLog/Services/BackgroundSyncCoordinator.swift", "runBGSyncPassesBody", .processing, "07-09", routing),
        make("T-12", "HealthLog/Services/BackgroundSyncCoordinator.swift", "runManualHealthSyncPass", .manual, "07-09", routing),
        make("T-13", "HealthLog/Stores/AppContainer+OutboxBGDrain.swift", "wireBGRefreshCollectionHook", .appRefresh, "07-09", routing),
        make("T-14", "HealthLog/Services/HealthKitService.swift", "runOneShotAnchorSweep", .processing, "07-03", routing),
        make(
            "T-15",
            "HealthLog/Stores/AppContainer+HealthKitLifecycle.swift",
            "refreshHealthKitDailyStatsForToday",
            .foreground,
            "07-04",
            routing
        ),
        make("T-16", "HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "makeHealthKitInfra", .coldActivation, "07-09", composition),
        make(
            "T-17",
            "HealthLog/Stores/AppContainer+HealthKitStats.swift",
            "wireWorkoutBackgroundSync",
            .coldActivation,
            "07-09",
            composition
        ),
        make(
            "T-18",
            "HealthLog/Services/HealthKit/AnchoredHealthSampleCollector.swift",
            "handleObservedChange",
            .observer,
            "07-03",
            routing
        ),
        make("T-19", "HealthLog/Services/HealthKit/MoodStateOfMindImporter.swift", "start", .observer, "07-05", routing),
        make("T-20", "HealthLog/Services/HealthKit/HeartHealthEventImporter.swift", "start", .observer, "07-06", routing),
        make("T-21", "HealthLog/Services/HealthKit/CycleHealthKitImporter.swift", "start", .observer, "07-06", routing),
        make("T-22", "HealthLog/Services/HealthKitService.swift", "resetStateOfMindImport", .accountTeardown, "07-02", isolation),
        make("T-23", "HealthLog/Services/HealthKitService.swift", "resetEventImport", .accountTeardown, "07-02", isolation),
        make("T-24", "HealthLog/Services/HealthKitService.swift", "resetWorkoutImport", .accountTeardown, "07-02", isolation),
        make("T-25", "HealthLog/Services/HealthKitService.swift", "resetCycleImport", .accountTeardown, "07-02", isolation),
        make("T-26", "HealthLog/Services/EcgSyncCoordinator.swift", "resetAnchor", .accountTeardown, "07-06", isolation)
    ]

    static func row(_ id: String) -> HealthSyncTriggerOwnership? {
        rows.first { $0.id == id }
    }

    private static let routing = "HealthLogTests/HealthSyncTriggerRoutingTests/everyInventoriedRouteEntersExactlyOnce"
    private static let composition =
        "HealthLogTests/CompleteHealthSyncCompositionTests/exactRegistryAndEveryDirectTriggerAreComplete"
    private static let isolation = "HealthLogTests/HealthSyncAccountIsolationTests/lateAccountACannotMutateB"

    /// Every row was `direct` from Wave 0 through Wave 4. **Plan 07-09 routed
    /// all twenty-six in the commit that made them true**, which is the only way
    /// this constant is allowed to change: a row that claimed orchestration while
    /// its call site still reached an importer itself would be exactly the
    /// falsehood `HealthSyncTriggerRoutingTests` exists to catch.
    private static func make(
        _ id: String,
        _ file: String,
        _ symbol: String,
        _ trigger: HealthSyncTrigger,
        _ ownerPlan: String,
        _ testIdentifier: String
    ) -> HealthSyncTriggerOwnership {
        HealthSyncTriggerOwnership(
            id: id,
            file: file,
            symbol: symbol,
            trigger: trigger,
            ownerPlan: ownerPlan,
            testIdentifier: testIdentifier,
            routing: .orchestrated
        )
    }
}
