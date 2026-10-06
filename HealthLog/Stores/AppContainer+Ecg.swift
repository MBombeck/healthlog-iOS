import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

// MARK: - ECG upload path (GH #74, server v1.35.3)

public extension AppContainer {
    /// The coordinator plus the switch that owns it, built as one pair because
    /// each needs the other: the store triggers and resets the coordinator, and
    /// the coordinator self-gates on the switch.
    ///
    /// The cycle is broken through `UserDefaults` rather than a captured
    /// reference — the switch IS a `UserDefaults` pref, and reading it where it
    /// lives keeps the coordinator free of a `@MainActor` store.
    struct EcgCluster {
        let sync: (any EcgSyncing)?
        let store: EcgHealthSyncStore
    }

    /// Builds the ECG upload pair. Returns an inert switch (no coordinator) when
    /// `healthKit == nil` — a non-HealthKit build or an HK-less test host has
    /// nothing to read, and the toggle correspondingly reports `enabled == false`
    /// forever rather than offering an upload that cannot run.
    internal static func makeEcgCluster(
        healthKit: AnyHealthKitWriter?,
        repo: EcgRepository,
        keychain: KeychainStoring,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry
    ) -> EcgCluster {
        #if canImport(HealthKit)
            guard healthKit != nil else {
                return EcgCluster(sync: nil, store: EcgHealthSyncStore(healthKit: healthKit, sync: nil))
            }
            let coordinator = makeEcgCoordinator(
                source: EcgHealthKitSource(store: HKHealthStore()),
                repo: repo,
                keychain: keychain,
                authenticatedSessionRegistry: authenticatedSessionRegistry
            )
            return EcgCluster(
                sync: coordinator,
                store: EcgHealthSyncStore(
                    healthKit: healthKit,
                    sync: coordinator,
                    resetAnchor: { await coordinator.resetAnchor() }
                )
            )
        #else
            _ = repo
            _ = keychain
            _ = authenticatedSessionRegistry
            return EcgCluster(sync: nil, store: EcgHealthSyncStore(healthKit: healthKit, sync: nil))
        #endif
    }

    /// The production coordinator wiring, apart from the HealthKit source.
    ///
    /// **No module gate** (server v1.39). The ECG routes carry no AI gate and no
    /// module gate; the `insights` module means "AI analysis" only. Build 279
    /// gated this sweep on `insights`, which migration 0343 switched off for
    /// every "Hide Coach" account — their recordings waited behind the held
    /// anchor and upload on the first sweep after this build lands.
    internal static func makeEcgCoordinator(
        source: any EcgRecordingSource,
        repo: EcgRepository,
        keychain: KeychainStoring,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
    ) -> EcgSyncCoordinator {
        EcgSyncCoordinator(
            source: source,
            repo: repo,
            keychain: keychain,
            isOptedIn: { EcgHealthSyncStore.isOptedIn(in: defaultsProvider()) },
            defaultsProvider: defaultsProvider,
            // Plan 07-06 — the account authority the reset's partition is
            // named by. Passed at construction rather than bound later:
            // a coordinator that learns its account after its first sweep
            // has already had a window in which it had none.
            admission: .keychainBound(keychain: keychain, registry: authenticatedSessionRegistry)
        )
    }
}

public extension EcgHealthSyncStore {
    /// Read the device-local opt-in without touching the `@MainActor` store.
    ///
    /// The coordinator runs off the main actor on background wake paths; hopping
    /// to the main actor merely to read a boolean pref would serialise a
    /// background sweep behind whatever the UI is doing. The store is the only
    /// writer of this key, so reading it here cannot diverge.
    nonisolated static func isOptedIn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: prefKey)
    }
}
