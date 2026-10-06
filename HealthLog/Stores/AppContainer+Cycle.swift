import Foundation

// MARK: - Cycle-tracking gate + store phase

extension AppContainer {
    /// Factory — constructs the cycle `CycleGate` + `CycleStore` VERBATIM from
    /// the prior inline `init` block (same args, same order, same captures), so
    /// the move is behaviour-identical. The `cycleGate` / `cycleStore`
    /// `public let` handles stay on `AppContainer` (this just feeds them).
    ///
    /// Both are dormant behind `FeatureFlag.cycleTracking` (default OFF): the
    /// gate's `isCycleTrackingAvailable` returns false while the flag is off, so
    /// the store's loads are no-ops and nothing surfaces. Path #3 fallback:
    /// server gender unknown → no-prompt HK `biologicalSex`; the provider hops
    /// to the HK actor and reads the *cached* characteristic (never prompts;
    /// `.unknown` unless auth was granted independently), so men are never
    /// surfaced the feature. `@MainActor` because the stores are
    /// `@MainActor @Observable`.
    @MainActor
    static func makeCycle(
        settingsStore: SettingsStore,
        featureFlagsStore: FeatureFlagsStore,
        moduleGate: ModuleGate,
        cycleRepo: CycleRepository,
        availability: BackendAvailability,
        healthKit: AnyHealthKitWriter?,
        keychain: KeychainStoring
    ) -> (gate: CycleGate, store: CycleStore) {
        let cycleBiologicalSexReader = healthKit
        let gate = CycleGate(
            settings: settingsStore,
            featureFlags: featureFlagsStore,
            moduleGate: moduleGate, // #30 — server map wins when present
            biologicalSexProvider: {
                await cycleBiologicalSexReader?.cycleBiologicalSex() ?? .unknown
            }
        )
        let store = CycleStore(
            repository: cycleRepo,
            gate: gate,
            availability: availability,
            healthKit: healthKit,
            userIDProvider: { [keychain] in
                keychain.getString(forKey: KeychainKey.userID)
            }
        )
        // #115 B6 — a period boundary replayed from the outbox refetches the
        // calendar, as the live write does.
        Task { await store.followBoundaryReplays() }
        return (gate, store)
    }
}

extension CycleStore {
    /// #115 B6 — reload the calendar whenever the outbox delivers a queued
    /// period start or end. The boundary can move, absorb or restore a start on
    /// the server, so the grid the person sees is refetched, as after a live
    /// boundary write (``commitCapture(dayLog:period:existingID:patch:)``).
    func followBoundaryReplays() async {
        await repository.attachBoundaryReplaySink { [weak self] in
            await self?.load()
        }
    }
}
