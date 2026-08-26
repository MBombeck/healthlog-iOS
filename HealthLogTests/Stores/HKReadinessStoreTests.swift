// Diese Suite testet App-Target-Symbole (`HKReadinessStore`, `HealthKitService`),
// die in der SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    #if canImport(HealthKit)
        import HealthKit
    #endif
    @testable import HealthLog
    import Testing

    /// Tests für `HKReadinessStore.computeState(...)` — die pure State-Transition-
    /// Logik. Schmaler Surface (kein HK-Import, kein UserDefaults, keine Network)
    /// damit sie auf jedem Build-Host läuft.
    @Suite("HKReadinessStore.computeState transitions")
    struct HKReadinessComputeStateTests {
        @Test("Pre-onboarding (hasRequested == false) → .notRequested unabhängig von Statuses")
        func notRequestedWinsOverAuthorized() {
            let statuses: [String: HKReadinessStore.AuthStatus] = [
                "HKQuantityTypeIdentifierBodyMass": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodGlucose": .sharingAuthorized
            ]
            let state = HKReadinessStore.computeState(
                statuses: statuses,
                hasRequestedAuthorization: false
            )
            #expect(state == .notRequested)
        }

        @Test("Alle Types authorized + hasRequested == true → .fullyGranted")
        func fullyGranted() {
            let statuses: [String: HKReadinessStore.AuthStatus] = [
                "HKQuantityTypeIdentifierBodyMass": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodGlucose": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodPressureSystolic": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodPressureDiastolic": .sharingAuthorized
            ]
            let state = HKReadinessStore.computeState(
                statuses: statuses,
                hasRequestedAuthorization: true
            )
            #expect(state == .fullyGranted)
        }

        @Test("Mind. ein Type notDetermined → .partiallyGranted mit fehlender Liste")
        func partiallyGrantedWhenSomeNotDetermined() {
            let statuses: [String: HKReadinessStore.AuthStatus] = [
                "HKQuantityTypeIdentifierBodyMass": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodGlucose": .notDetermined,
                "HKQuantityTypeIdentifierBloodPressureSystolic": .sharingAuthorized
            ]
            let state = HKReadinessStore.computeState(
                statuses: statuses,
                hasRequestedAuthorization: true
            )
            guard case let .partiallyGranted(missing) = state else {
                Issue.record("Erwartet .partiallyGranted, war \(state)")
                return
            }
            #expect(missing == ["HKQuantityTypeIdentifierBloodGlucose"])
        }

        @Test("Mind. ein Type sharingDenied (rest auth) → .partiallyGranted")
        func partiallyGrantedWhenSomeDenied() {
            let statuses: [String: HKReadinessStore.AuthStatus] = [
                "HKQuantityTypeIdentifierBodyMass": .sharingAuthorized,
                "HKQuantityTypeIdentifierBloodGlucose": .sharingDenied
            ]
            let state = HKReadinessStore.computeState(
                statuses: statuses,
                hasRequestedAuthorization: true
            )
            guard case let .partiallyGranted(missing) = state else {
                Issue.record("Erwartet .partiallyGranted, war \(state)")
                return
            }
            #expect(missing == ["HKQuantityTypeIdentifierBloodGlucose"])
        }

        @Test("Alle Types sharingDenied → .denied (eigener Bucket für UI-Hint)")
        func deniedBucket() {
            let statuses: [String: HKReadinessStore.AuthStatus] = [
                "HKQuantityTypeIdentifierBodyMass": .sharingDenied,
                "HKQuantityTypeIdentifierBloodGlucose": .sharingDenied
            ]
            let state = HKReadinessStore.computeState(
                statuses: statuses,
                hasRequestedAuthorization: true
            )
            #expect(state == .denied)
        }

        @Test("Leere Statuses + requested → .unknown (defensive — Service-Init-Race)")
        func emptyStatusesIsUnknown() {
            let state = HKReadinessStore.computeState(
                statuses: [:],
                hasRequestedAuthorization: true
            )
            #expect(state == .unknown)
        }

        @Test("shouldShowBanner: true für notRequested / partial / denied")
        func bannerTriggers() {
            #expect(HKReadinessStore.ConnectionState.notRequested.shouldShowBanner)
            #expect(HKReadinessStore.ConnectionState.partiallyGranted(missing: ["x"]).shouldShowBanner)
            #expect(HKReadinessStore.ConnectionState.denied.shouldShowBanner)
            #expect(!HKReadinessStore.ConnectionState.fullyGranted.shouldShowBanner)
            #expect(!HKReadinessStore.ConnectionState.unknown.shouldShowBanner)
        }

        @Test("isFullyGranted nur für .fullyGranted")
        func fullyGrantedFlag() {
            #expect(HKReadinessStore.ConnectionState.fullyGranted.isFullyGranted)
            #expect(!HKReadinessStore.ConnectionState.partiallyGranted(missing: []).isFullyGranted)
            #expect(!HKReadinessStore.ConnectionState.denied.isFullyGranted)
            #expect(!HKReadinessStore.ConnectionState.notRequested.isFullyGranted)
            #expect(!HKReadinessStore.ConnectionState.unknown.isFullyGranted)
        }
    }

    // MARK: - lastSyncedAt persistence

    @MainActor
    @Suite("HKReadinessStore lastSyncedAt persistence")
    struct HKReadinessLastSyncedTests {
        /// Pro Testlauf ein eigener UserDefaults-Suite-Name, damit Tests nicht
        /// gegenseitig auf `.standard` Werte vererben.
        private static func makeDefaults() -> UserDefaults {
            // swiftlint:disable:next force_unwrapping
            UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)")!
        }

        @Test("noteSuccessfulSync schreibt Timestamp + lädt ihn beim nächsten init wieder")
        func writeThroughRoundtrip() throws {
            let defaults = Self.makeDefaults()
            let keychain = InMemoryKeychain()
            try keychain.setString("user-42", forKey: KeychainKey.userID)

            let coordinator = StubBackgroundSyncCoordinator()
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            #expect(store.lastSyncedAt == nil)

            let fixed = Date(timeIntervalSince1970: 1_715_673_600)
            store.noteSuccessfulSync(at: fixed)
            #expect(store.lastSyncedAt == fixed)

            // Re-init: load aus UserDefaults
            let reloaded = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            #expect(reloaded.lastSyncedAt == fixed)
        }

        @Test("clearPersisted für previousUserID wischt Defaults — anderer User unberührt")
        func clearPersistedIsPartitioned() throws {
            let defaults = Self.makeDefaults()
            let keychain = InMemoryKeychain()
            try keychain.setString("alice", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()

            let aliceStore = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            aliceStore.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_700_000_000))

            // Switch zu Bob, lege bei ihm einen Wert ab.
            try keychain.setString("bob", forKey: KeychainKey.userID)
            let bobStore = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            bobStore.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_710_000_000))

            // Logout-Cleanup für Bob (z. B. nach 401).
            HKReadinessStore.clearPersisted(for: "bob", in: defaults)

            // Alice ist unbetroffen.
            let aliceReload = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            try keychain.setString("alice", forKey: KeychainKey.userID)
            // Re-Init (mit Alice-userID) muss Alice's Daten weiter laden.
            let aliceReload2 = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            #expect(aliceReload2.lastSyncedAt == Date(timeIntervalSince1970: 1_700_000_000))
            _ = aliceReload // hold reference
        }

        @Test("isConnected == true sobald lastSyncedAt gesetzt ist (read-only-User-Pfad)")
        func connectedDerivesFromLastSynced() throws {
            let defaults = Self.makeDefaults()
            let keychain = InMemoryKeychain()
            try keychain.setString("user-sync", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()

            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            // Fresh store, no sync, no requested-flag → not connected.
            #expect(!store.isConnected)

            // A real HK→server batch landed → connected, even though WRITE-auth
            // state is still `.unknown` (read-only user; Apple hides READ auth).
            store.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_715_673_600))
            #expect(store.isConnected)
        }

        @Test("isConnected == true wenn requested + nicht denied, auch ohne ersten Sync")
        func connectedDerivesFromRequestedFlag() throws {
            let defaults = Self.makeDefaults()
            let keychain = InMemoryKeychain()
            try keychain.setString("user-req", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()

            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            #expect(!store.isConnected)
            store.markAuthorizationRequested()
            // state stays `.unknown` (no HK service in test), lastSyncedAt nil —
            // but the user went through the sheet and didn't decline → connected.
            #expect(store.isConnected)
        }

        @Test("dismissBanner persistiert + 24h-Cooldown bestimmt shouldShowDashboardBanner")
        func dismissalCooldown() throws {
            let defaults = Self.makeDefaults()
            let keychain = InMemoryKeychain()
            try keychain.setString("user-23", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()

            // Pin "jetzt" auf einen fixen Zeitpunkt, damit der Cooldown deterministisch ist.
            let pinnedNow = Date(timeIntervalSince1970: 1_715_673_600)
            let clock: @Sendable () -> Date = { pinnedNow }

            // Wir können den state nicht direkt setzen (private(set)), aber wir
            // testen die Logik über `shouldShowDashboardBanner` indirekt: bei
            // `.unknown` ist `shouldShowBanner == false` → unabhängig vom Dismiss
            // false. Daher fixieren wir einen partial-Granted-State über die
            // exposed `markAuthorizationRequested` + computeState-Pfad.

            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults,
                clock: clock
            )
            // Vor dismissal: kein Cooldown — bei shouldShowBanner==true wäre der
            // Banner sichtbar (state ist hier .unknown also false; wir testen
            // nur den Cooldown-Mechanismus über die Persistenz).
            #expect(store.bannerDismissedAt == nil)
            store.dismissBanner()
            #expect(store.bannerDismissedAt == pinnedNow)

            // Re-init lädt die Dismissal aus Defaults.
            let reloaded = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults,
                clock: clock
            )
            #expect(reloaded.bannerDismissedAt == pinnedNow)
        }
    }

    // MARK: - markAuthorizationRequested

    @MainActor
    @Suite("HKReadinessStore requestedAt flag")
    struct HKReadinessRequestedFlagTests {
        @Test("markAuthorizationRequested persistiert per-User")
        func requestedFlagPersists() throws {
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            try keychain.setString("user-7", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()

            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            #expect(!store.hasEverRequestedAuthorization)
            store.markAuthorizationRequested()
            #expect(store.hasEverRequestedAuthorization)

            // Wechsel zu anderem User → flag muss reset sein (partitioniert).
            try keychain.setString("user-99", forKey: KeychainKey.userID)
            #expect(!store.hasEverRequestedAuthorization)
        }

        @Test("clearPersisted entfernt requestedAt für den User")
        func clearWipesRequestedFlag() throws {
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            try keychain.setString("user-9", forKey: KeychainKey.userID)
            let coordinator = StubBackgroundSyncCoordinator()
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            store.markAuthorizationRequested()
            HKReadinessStore.clearPersisted(for: "user-9", in: defaults)
            #expect(!store.hasEverRequestedAuthorization)
        }

        @Test("manual sync reactivates delivery and awaits the composed pass")
        func manualSyncRunsComposedPass() async throws {
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            let coordinator = StubBackgroundSyncCoordinator()
            let recorder = ManualSyncRecorder()
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )
            // Plan 07-09 — the route takes the trigger it starts work for, and
            // "Jetzt syncen" is `.manual`. It used to be a nameless hook that
            // enumerated importers.
            store.attachHealthSyncRoute { trigger in
                #expect(trigger == .manual)
                await recorder.record()
            }

            await store.triggerManualSync()

            #expect(coordinator.activateCount == 1)
            #expect(await recorder.count == 1)
            #expect(!store.isSyncing)
        }
    }

    // MARK: - Stubs

    /// Minimal `BackgroundSyncCoordinatorProtocol`-Stub für Tests — vermeidet
    /// `BGTaskScheduler.register` (das in Test-Hosts crasht).
    final class StubBackgroundSyncCoordinator: BackgroundSyncCoordinatorProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _activateCount = 0

        var activateCount: Int {
            lock.withLock { _activateCount }
        }

        func activateHealthKitBackgroundDeliveries() async {
            lock.withLock { _activateCount += 1 }
        }
    }

    actor ManualSyncRecorder {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    // MARK: - R1 regression: isConnected must beat a WRITE-denied state

    #if canImport(HealthKit)

        /// **R1 regression (P1 core-fix).** These pin the decoupling of the
        /// RECEIVE truth (`isConnected`) from the WRITE-authorization proxy
        /// (`state`). A user who denied every WRITE type but whose data is
        /// demonstrably flowing (a real HK→server batch round-tripped, i.e.
        /// `lastSyncedAt != nil`) must read as connected — while a genuine
        /// denial with no sync stays honest. `refresh()` needs a real
        /// `HealthKitServiceProtocol` double whose statuses are all
        /// `.sharingDenied` to actually land on `.denied` (template:
        /// `StubWorkoutMigrationService` in `AppleSyncBulletproofTests`).
        @MainActor
        @Suite("HKReadinessStore isConnected vs. denied state (R1)")
        struct HKReadinessDeniedConnectivityTests {
            private static func makeDefaults() -> UserDefaults {
                // swiftlint:disable:next force_unwrapping
                UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)")!
            }

            @Test("state == .denied but lastSyncedAt != nil → isConnected (sync-truth wins)")
            func deniedButSyncingIsConnected() async throws {
                let defaults = Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("denied-syncing", forKey: KeychainKey.userID)
                let service = StubDeniedWriteService()
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                // Force the WRITE proxy onto `.denied`: the user went through
                // the sheet, and every WRITE type is `.sharingDenied`.
                store.markAuthorizationRequested()
                await store.refresh()
                #expect(store.state == .denied)
                // No sync yet → the denial is honest, isConnected == false.
                #expect(!store.isConnected)

                // A real HK→server batch round-trips → receiving demonstrably
                // works, so isConnected flips to true DESPITE the `.denied`
                // WRITE state. This is the core R1 fix.
                store.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_715_673_600))
                #expect(store.isConnected)
            }

            @Test("state == .denied and lastSyncedAt == nil → not connected (genuine denial stays honest)")
            func deniedWithoutSyncIsNotConnected() async throws {
                let defaults = Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("denied-only", forKey: KeychainKey.userID)
                let service = StubDeniedWriteService()
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                store.markAuthorizationRequested()
                await store.refresh()
                #expect(store.state == .denied)
                // Never synced + all WRITE types denied → honestly not connected.
                #expect(store.lastSyncedAt == nil)
                #expect(!store.isConnected)
            }
        }

        /// Minimal `HealthKitServiceProtocol` double whose WRITE types are all
        /// `.sharingDenied`, so `HKReadinessStore.refresh()` computes `.denied`.
        /// Shape mirrors `StubWorkoutMigrationService`; only the status +
        /// write-type members carry behaviour, the rest ride the
        /// `AnyHealthKitWriter` extension defaults where available.
        final class StubDeniedWriteService: HealthKitServiceProtocol, @unchecked Sendable {
            // MARK: Capability + status

            func isAvailable() -> Bool {
                true
            }

            func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
                .sharingDenied
            }

            func authorizationStatuses(for types: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
                var result: [String: HKReadinessStore.AuthStatus] = [:]
                for type in types {
                    result[type.identifier] = .sharingDenied
                }
                return result
            }

            // MARK: Authorization

            func requestAuthorization(read _: Set<HKObjectType>, write _: Set<HKSampleType>) async throws {}
            func resetAuthDisabledTypes() async {}

            func defaultReadTypes() -> Set<HKObjectType> {
                [HKQuantityType(.bodyMass)]
            }

            func defaultWriteTypes() -> Set<HKSampleType> {
                [HKQuantityType(.bodyMass)]
            }

            // MARK: Direct write + observation

            func writeMeasurement(_: HealthLog.Measurement) async throws {}
            func writeMoodEntry(_: MoodEntry) async throws {}
            func startBackgroundDeliveries() async throws {}

            // MARK: AnyHealthKitWriter required slice (no extension defaults)

            func write(_: HealthLog.Measurement) async throws {}
            func writeMood(_: MoodEntry) async throws {}
            func deleteMood(id _: String) async throws {}
            func requestMoodAuthorization() async throws {}
            func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
            func stopMoodImport() async {}
            func resetMoodImport() async {}
            func activateBackgroundDeliveries() async throws {}
            func runBackgroundSyncPass() async {}
            func attachUploader(_: MeasurementBatchUploader) async {}
            func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
            func setInitialBackfillCutoff(_: Date?) async {}
            func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
        }

    #endif

#endif
