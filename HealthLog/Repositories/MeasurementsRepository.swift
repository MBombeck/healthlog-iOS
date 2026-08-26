import Foundation

/// Protocol the HK service uses to forward `deletedObjects` from
/// HKAnchoredObjectQuery back to the server. Decouples the HK actor from the
/// concrete repo for testability — tests can inject a fake reconciler that
/// records the externalIDs without spinning up an APIClient.
public protocol MeasurementDeletionReconciler: Sendable {
    func reconcileDeletedExternalIDs(_ ids: [String]) async throws
}

extension MeasurementsRepository: MeasurementDeletionReconciler {
    public func reconcileDeletedExternalIDs(_ ids: [String]) async throws {
        try await deleteByExternalIDs(ids)
    }
}

public actor MeasurementsRepository {
    /// `internal` (not `private`) so the `+BloodPressure.swift` extension can
    /// issue its paired type-scoped fetches (mirrors the `standalone` seam).
    let api: APIClientProtocol
    /// `internal` (not `private`) so the `+BulkDelete.swift` extension can
    /// enqueue its replay chunks (mirrors the `api` / `swr` seams).
    let outbox: OutboxQueue
    /// `internal` (not `private`) so the `+Writes.swift` extension can encode
    /// its outbox payloads (same-module split — W-FILELEN).
    let encoder: JSONEncoder
    /// SWR coordinator wired by `AppContainer` (W1-1 / R5 #5). When `nil`
    /// every read fires a cold network round-trip — the legacy shape unit
    /// tests rely on. When wired, `recent(limit:)`, `recent(kind:limit:)`,
    /// `recentAll(limit:)` + `series(kind:days:)` route through the
    /// `measurementsRecent` / `measurementSeries` cache keys with the
    /// standard fresh-enough → offline-fallback → network ladder.
    ///
    /// **Read-only cache (R5 mitigation):** writes still go straight to the
    /// network and only invalidate cache keys on success — never write back
    /// through the cache from a write path. Keeps outbox-replay ordering
    /// identical to pre-W1-1 behaviour.
    ///
    /// `internal` (not `private`) so the `+BloodPressure.swift` extension can
    /// route its paired fetch through the same cache ladder.
    let swr: SWRCoordinator?
    /// v0.11 W2 — standalone read-union seam. `nil` (default) → the repo is the
    /// existing server/SWR path verbatim (paired invariant). Non-nil + live
    /// standalone mode → reads route to `HealthKitReadAdapter ∪ LocalRepository`
    /// and **no `/api/*` request fires**. Injected by the composition-root.
    /// `internal` (not `private`) so the `+Standalone.swift` extension can read it.
    let standalone: StandaloneGate?

    /// **AUD-3 D-3 — profile-TZ day-anchoring for `.dashboardSummary`
    /// invalidation.** `DashboardStore` / `MedicationsStore` key the
    /// `.dashboardSummary` cache row on the current calendar day in the
    /// SERVER-PROFILE timezone (`CacheKey.dashboardSummary` contract). The write
    /// paths here must invalidate the SAME day-keyed row, otherwise a write near
    /// local midnight (or for a TZ-mismatched user) invalidates the wrong day and
    /// the dashboard stale-serves a prior-day compliance ring. Defaults to
    /// `.current` (tests / pre-settings-hydration window stay byte-unchanged);
    /// the composition root points it at the same `settingsStore.profile` zone
    /// the two stores use via `setProfileTimeZoneProvider`.
    private var profileTimeZoneProvider: @Sendable () -> TimeZone = { .current }

    /// Resolved server-profile day-anchoring zone, falling back to `.current`.
    var profileTimeZone: TimeZone {
        profileTimeZoneProvider()
    }

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        swr: SWRCoordinator? = nil,
        standalone: StandaloneGate? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.swr = swr
        self.standalone = standalone
    }

    /// Wire the server-profile timezone provider from the composition root
    /// (`AppContainer`) so the `.dashboardSummary` invalidation day-key matches
    /// the day-key `DashboardStore` reads (AUD-3 D-3).
    public func setProfileTimeZoneProvider(_ provider: @escaping @Sendable () -> TimeZone) {
        profileTimeZoneProvider = provider
    }

    /// True iff the standalone branch must be taken: a gate is wired AND the
    /// live runtime mode reads standalone. Keeps the paired path the default at
    /// every call site.
    /// `internal` (not `private`) so the `+Reads.swift` / `+Writes.swift`
    /// extensions can branch on it (same-module split — W-FILELEN).
    var isStandalone: Bool {
        standalone?.isActive == true
    }
}
