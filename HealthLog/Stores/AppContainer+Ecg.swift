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
        moduleGate: ModuleGate,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry
    ) -> EcgCluster {
        #if canImport(HealthKit)
            guard healthKit != nil else {
                return EcgCluster(sync: nil, store: EcgHealthSyncStore(healthKit: healthKit, sync: nil))
            }
            let coordinator = EcgSyncCoordinator(
                source: EcgHealthKitSource(store: HKHealthStore()),
                repo: repo,
                keychain: keychain,
                isOptedIn: { EcgHealthSyncStore.isOptedIn() },
                isModuleEnabled: { [moduleGate] in
                    // The SAME module that gates the ECG reads — the server
                    // gates the write behind it too, so the client must not
                    // pretend otherwise.
                    await MainActor.run { moduleGate.isEnabled(.insights) }
                },
                // Plan 07-06 — the account authority the reset's partition is
                // named by. Passed at construction rather than bound later:
                // a coordinator that learns its account after its first sweep
                // has already had a window in which it had none.
                admission: .keychainBound(keychain: keychain, registry: authenticatedSessionRegistry)
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
            _ = moduleGate
            return EcgCluster(sync: nil, store: EcgHealthSyncStore(healthKit: healthKit, sync: nil))
        #endif
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
