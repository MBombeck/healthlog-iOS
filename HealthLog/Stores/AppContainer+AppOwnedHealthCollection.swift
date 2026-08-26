#if canImport(Spezi) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @_spi(APISupport) import Spezi
    import SpeziHealthKit

    // Phase 07 Wave 2 — composition for the app-owned sample collection.
    //
    // Kept in its own Spezi-scoped extension file for the same reason
    // `AppContainer+SpeziStandard.swift` exists: the `@_spi(APISupport)` Spezi
    // import that resolves the running `HealthLogStandard` should not leak into
    // `AppContainer.swift`.

    extension AppContainer {
        /// Builds the collector and installs it behind ``AppOwnedHealthCollection``.
        ///
        /// The admission is a closure, evaluated fresh on every trigger and every
        /// observer wake, and it is the only place an owner is chosen. It reads the
        /// signed-in user and the bearer paired with it, and fails closed when
        /// either is missing — so a signed-out process collects nothing rather than
        /// collecting under whoever signed in last.
        ///
        /// The cutoff is likewise a closure rather than a captured value: a user who
        /// changes the backfill window in onboarding must not be held to whatever
        /// was persisted when the container was built.
        static func installAppOwnedHealthCollection(
            keychain: KeychainStoring,
            registry: AuthenticatedSessionLeaseRegistry,
            retryQueue: OutboxQueue
        ) {
            let admission: @Sendable () throws -> HealthSyncAuthenticatedLease = {
                let owner = keychain.getString(forKey: KeychainKey.userID) ?? ""
                return try HealthSyncAuthenticatedLease.admit(
                    from: registry,
                    ownerID: owner,
                    source: .speziSamples,
                    bearerProvider: { keychain.getString(forKey: KeychainKey.authToken) }
                )
            }
            let cutoff: @Sendable () -> Date = {
                // The window the authenticated user chose during onboarding. Before
                // that choice exists there is nothing to narrow to, so the first
                // walk sees the full on-device history rather than silently
                // dropping pre-install samples.
                HealthKitBackfillWindowStore.load(keychain: keychain)?.lowerBound() ?? .distantPast
            }

            let store = HKHealthStore()
            let cursors = DurableHealthCursorStore()
            let coordinator = AppOwnedHealthCollectionCoordinator(
                collector: AnchoredHealthSampleCollector(
                    cursors: cursors,
                    query: HealthKitAnchoredPageSource(store: store),
                    consumer: SpeziStandardPageConsumer(),
                    observer: HealthKitSampleChangeObserver(store: store)
                ),
                cursors: cursors,
                admission: admission,
                cutoff: cutoff
            )
            Task { @MainActor in
                AppOwnedHealthCollection.installSampleCollection { trigger in
                    await coordinator.run(trigger)
                }
            }
        }
    }

    /// Routes a page to the running `HealthLogStandard`, which owns the one
    /// implementation of the anti-echo filter, the wire conversion, and the two
    /// upload gates.
    ///
    /// Resolving the Standard per page rather than capturing it keeps this
    /// composition free of a boot-order assumption: a page that arrives before the
    /// Spezi graph is up reports a refused outcome, which holds the cursor, instead
    /// of being silently dropped.
    struct SpeziStandardPageConsumer: HealthSamplePageConsuming {
        func consume(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            guard let standard = await MainActor.run(body: { SpeziAppDelegate.spezi?.module(HealthLogStandard.self) }) else {
                HLLog.healthKit.info("HealthLogStandard not registered — page held")
                return HealthSyncPageOutcome(
                    postedCount: samples.count,
                    entries: [],
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: false,
                    wasCancelled: false
                )
            }
            return await standard.consume(samples, ofType: typeIdentifier, requiring: lease)
        }
    }
#endif
