#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **W-B182 — Apple-Health-sync + workout bulletproofing.**
    ///
    /// Covers the three structural fixes the audits called out:
    ///  - PART A: the `start: .manual` collector → `triggerDataSourceCollection`
    ///    trigger wiring (via the diagnostics heartbeat) + the
    ///    collector-set ↔ auth-set lockstep (FIX-4).
    ///  - PART B: the empty-first-run anchor guard (the silent history mask),
    ///    the server-samples HR preference, and the WHOOP metadata decode.
    @Suite("W-B182 — Apple sync + workouts bulletproof")
    struct AppleSyncBulletproofTests {
        // MARK: - PART B: empty-sweep anchor guard (AUDIT-WORKOUTS-RCA fix #1)

        @Test("First-run EMPTY sweep does NOT advance the anchor (history mask guard)")
        func firstRunEmptySweepSkipsAnchorSave() {
            // No persisted anchor + zero workouts = the "read auth not yet
            // granted vs no history" case. MUST skip the save.
            #expect(WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: false, fetchedCount: 0))
        }

        @Test("First-run NON-empty sweep advances the anchor")
        func firstRunNonEmptySweepSavesAnchor() {
            #expect(!WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: false, fetchedCount: 3))
        }

        @Test("Empty INCREMENTAL sweep retains the anchor because read denial is indistinguishable")
        func emptyIncrementalSweepRetainsAnchor() {
            #expect(WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: true, fetchedCount: 0))
        }

        @Test("Non-empty incremental sweep advances")
        func nonEmptyIncrementalSweepSavesAnchor() {
            #expect(!WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: true, fetchedCount: 5))
        }

        // MARK: - PART A: collection-trigger heartbeat persistence (FIX-3)

        @MainActor
        @Test("Collection-trigger heartbeat persists across a fresh diagnostics instance")
        func triggerHeartbeatPersists() throws {
            let suiteName = "w-b182-trigger-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let when = Date(timeIntervalSince1970: 1_700_000_000)
            let first = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            first.recordCollectionTrigger(source: "background", at: when)

            // A fresh instance reading the same defaults sees the persisted
            // heartbeat — this is the "never armed vs armed-idle" signal that
            // must survive the cold-launch counter reset.
            let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            #expect(reloaded.lastCollectionTriggerAt == when)
            #expect(reloaded.lastCollectionTriggerSource == "background")
        }

        @MainActor
        @Test("Per-identifier last-observation persists across a fresh diagnostics instance")
        func lastObservationPersists() throws {
            let suiteName = "w-b182-obs-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let id = HKQuantityTypeIdentifier.heartRate.rawValue
            let when = Date(timeIntervalSince1970: 1_700_001_000)
            let first = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            first.recordObservation(identifier: id, samplesRead: 4, samplesUploaded: 4, anchorAdvanced: true, at: when)

            let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            #expect(reloaded.persistedLastObservation[id] == when)
        }

        @MainActor
        @Test("reset() clears persisted heartbeat + observation")
        func resetClearsPersistence() throws {
            let suiteName = "w-b182-reset-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let diag = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            diag.recordCollectionTrigger(source: "manual")
            diag.recordObservation(
                identifier: HKQuantityTypeIdentifier.bodyMass.rawValue,
                samplesRead: 1, samplesUploaded: 1, anchorAdvanced: true
            )
            diag.reset()

            let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            #expect(reloaded.lastCollectionTriggerAt == nil)
            #expect(reloaded.persistedLastObservation.isEmpty)
        }

        // MARK: - PART B: server-samples HR preference

        @MainActor
        @Test("Server WorkoutSamples HR series maps to the chart shape, dropping non-HR rows")
        func serverHRSeriesMaps() {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let samples = WorkoutSamplesDTO(
                sampleCount: 3,
                samples: [
                    .init(t: t0, hr: 120),
                    .init(t: t0.addingTimeInterval(60), hr: nil), // dropped (no HR)
                    .init(t: t0.addingTimeInterval(120), hr: 0), // dropped (non-positive)
                    .init(t: t0.addingTimeInterval(180), hr: 145)
                ]
            )
            let series = WorkoutsStore.hrSeries(from: samples)
            #expect(series?.count == 2)
            #expect(series?.first?.bpm == 120)
            #expect(series?.last?.bpm == 145)
        }

        @MainActor
        @Test("Server HR series is nil when no HR-bearing samples exist (fall back to HK)")
        func serverHRSeriesNilWhenNoHR() {
            let samples = WorkoutSamplesDTO(sampleCount: 1, samples: [.init(t: .now, hr: nil)])
            #expect(WorkoutsStore.hrSeries(from: samples) == nil)
            #expect(WorkoutsStore.hrSeries(from: nil) == nil)
        }

        // MARK: - PART B: WHOOP metadata helpers

        @Test("percent_recorded normalizes 0–1 fraction to a percentage")
        func percentRecordedNormalizes() {
            #expect(WorkoutDetailView.normalizedPercent(0.97) == 97)
            #expect(WorkoutDetailView.normalizedPercent(85) == 85)
            #expect(WorkoutDetailView.normalizedPercent(0) == nil)
            #expect(WorkoutDetailView.normalizedPercent(nil) == nil)
        }

        @Test("WHOOP zone_durations parse + order from zone-0 to zone-5")
        func zoneDurationsOrder() {
            let raw: [String: Double] = [
                "zone_two_milli": 120_000,
                "zone_zero_milli": 600_000,
                "zone_five_milli": 30000,
                "zone_one_milli": 0 // dropped (non-positive)
            ]
            let zones = WorkoutDetailView.orderedZones(from: raw)
            #expect(zones.map(\.index) == [0, 2, 5])
            #expect(zones.first?.seconds == 600) // 600_000 ms → 600 s
        }

        @Test("zoneIndex parses worded + digit keys")
        func zoneIndexParsing() {
            #expect(WorkoutDetailView.zoneIndex(for: "zone_three_milli") == 3)
            #expect(WorkoutDetailView.zoneIndex(for: "zone_5") == 5)
            #expect(WorkoutDetailView.zoneIndex(for: "garbage") == nil)
        }

        @Test("hasDisplayableMetadata true only when a field is present + positive")
        func displayableMetadata() {
            #expect(WorkoutDetailView.hasDisplayableMetadata(.init(whoopWorkoutStrain: 12.3)))
            #expect(WorkoutDetailView.hasDisplayableMetadata(.init(altitudeGainMeter: 50)))
            #expect(!WorkoutDetailView.hasDisplayableMetadata(.init()))
            #expect(!WorkoutDetailView.hasDisplayableMetadata(.init(whoopWorkoutStrain: 0)))
        }

        // MARK: - FIX-4: collector-set ↔ auth-set lockstep

        @Test("Every diagnostics-mapped HK identifier is in defaultReadTypes")
        func diagnosticsIdentifiersAreInReadSet() {
            let readIdentifiers = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            for id in HKSyncDiagnostics.identifierToKind.keys {
                #expect(
                    readIdentifiers.contains(id),
                    "Diagnostics maps \(id) but it is missing from HealthKitService.defaultReadTypes — add the read-auth entry or the collector silently never starts."
                )
            }
        }

        @Test("workoutType() read is present in defaultReadTypes (b171 regression guard)")
        func workoutReadInDefaultReadTypes() {
            #expect(HealthKitService.defaultReadTypes.contains(HKObjectType.workoutType()))
        }
    }

    // MARK: - W-B184: workout-read re-auth migration → forced full re-sweep

    //
    // AUDIT-WORKOUTS-RCA fix #2 second sub-fix: the one-shot per-user migration
    // must (a) run at most once, and (b) signal a FULL workout re-sweep for
    // returning users, because a pre-b182 build may have advanced the workout
    // anchor over an empty (read-unauthorized) sweep — re-auth alone wouldn't
    // recover that history.

    #if !SWIFT_PACKAGE
        @MainActor
        @Suite("W-B184 — workout-read migration forces a full re-sweep")
        struct WorkoutReadMigrationTests {
            private static func makeDefaults() throws -> UserDefaults {
                try #require(UserDefaults(suiteName: "hl.tests.wb184.\(UUID().uuidString)"))
            }

            @Test("Returning user (requested before) → migration returns true (force re-sweep) + marks flag once")
            func returningUserForcesReSweep() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("returning-user", forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                let service = StubWorkoutMigrationService()
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                // Simulate a pre-b182 returning user: they went through the HK
                // sheet before workout-read existed.
                store.markAuthorizationRequested()

                let didReAuth = await store.requestWorkoutReadAuthorizationMigrationIfNeeded()
                #expect(didReAuth) // → caller resets the anchor + full re-sweep
                #expect(service.requestAuthorizationCount == 1)
                #expect(
                    defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "returning-user"))
                )
                #expect(
                    defaults.bool(forKey: HKReadinessStore.workoutReadRearmPendingKey(for: "returning-user"))
                )

                // A reconstruction retries the durable service-side rearm
                // without presenting the authorization sheet again.
                let again = await store.requestWorkoutReadAuthorizationMigrationIfNeeded()
                #expect(again)
                #expect(service.requestAuthorizationCount == 1)
                HKReadinessStore.clearWorkoutReadRearmPending(for: "returning-user", defaults: defaults)
                #expect(await !(store.requestWorkoutReadAuthorizationMigrationIfNeeded()))
            }

            @Test("Never-requested user → no re-auth, no force re-sweep, flag still marked")
            func newUserSkipsButMarks() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("new-user", forKey: KeychainKey.userID)
                let service = StubWorkoutMigrationService()
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                // No markAuthorizationRequested → new user; first onboarding
                // request already includes workout read.
                let didReAuth = await store.requestWorkoutReadAuthorizationMigrationIfNeeded()
                #expect(!didReAuth)
                #expect(service.requestAuthorizationCount == 0)
                #expect(
                    defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "new-user"))
                )
            }

            @Test("Migration is per-user partitioned")
            func perUserPartitioned() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                let service = StubWorkoutMigrationService()
                try keychain.setString("alice", forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                store.markAuthorizationRequested()
                _ = await store.requestWorkoutReadAuthorizationMigrationIfNeeded()
                #expect(defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "alice")))
                // Bob has not migrated yet.
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "bob")))
            }

            @Test("Failed workout-read authorization leaves migration and rearm pending unset")
            func failedAuthorizationRemainsRetryable() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("returning-user", forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                let service = StubWorkoutMigrationService(authorizationError: CancellationError())
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                store.markAuthorizationRequested()

                #expect(await !(store.requestWorkoutReadAuthorizationMigrationIfNeeded()))
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "returning-user")))
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadRearmPendingKey(for: "returning-user")))
            }

            @Test("A pending-first crash retries rearm without another authorization request")
            func pendingBeforeMigratedSurvivesReconstruction() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("returning-user", forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                defaults.set(
                    true,
                    forKey: HKReadinessStore.workoutReadRearmPendingKey(for: "returning-user")
                )
                let service = StubWorkoutMigrationService()
                let reconstructed = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )

                #expect(await reconstructed.requestWorkoutReadAuthorizationMigrationIfNeeded())
                #expect(service.requestAuthorizationCount == 0)
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "returning-user")))
            }

            @Test("Cancellation while authorization is suspended writes neither migration key")
            func cancellationBeforeAuthorizationReturnDoesNotPersist() async throws {
                let defaults = try Self.makeDefaults()
                let keychain = InMemoryKeychain()
                try keychain.setString("returning-user", forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                let gate = WorkoutAuthorizationGate()
                let service = StubWorkoutMigrationService(authorizationGate: gate)
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                store.markAuthorizationRequested()
                let migration = Task {
                    await store.requestWorkoutReadAuthorizationMigrationIfNeeded()
                }
                await gate.waitUntilStarted()

                migration.cancel()
                await gate.open()

                #expect(await migration.value == false)
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadMigratedKey(for: "returning-user")))
                #expect(!defaults.bool(forKey: HKReadinessStore.workoutReadRearmPendingKey(for: "returning-user")))
            }
        }

        actor WorkoutAuthorizationGate {
            private var started = false
            private var waiter: CheckedContinuation<Void, Never>?

            func wait() async {
                started = true
                await withCheckedContinuation { waiter = $0 }
            }

            func waitUntilStarted() async {
                while !started {
                    await Task.yield()
                }
            }

            func open() {
                waiter?.resume()
                waiter = nil
            }
        }

        /// Minimal `HealthKitServiceProtocol` double — only the members the
        /// migration touches do real work; everything else is a no-op. The
        /// workout + cycle seams ride the `AnyHealthKitWriter` extension defaults.
        final class StubWorkoutMigrationService: HealthKitServiceProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private let authorizationError: (any Error)?
            private let authorizationGate: WorkoutAuthorizationGate?
            private var _requestAuthorizationCount = 0

            init(
                authorizationError: (any Error)? = nil,
                authorizationGate: WorkoutAuthorizationGate? = nil
            ) {
                self.authorizationError = authorizationError
                self.authorizationGate = authorizationGate
            }

            var requestAuthorizationCount: Int {
                lock.withLock { _requestAuthorizationCount }
            }

            // MARK: HealthKitServiceProtocol — capability + status

            func isAvailable() -> Bool {
                true
            }

            func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
                .notDetermined
            }

            func authorizationStatuses(for _: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
                [:]
            }

            // MARK: Authorization — the only member the migration exercises

            func requestAuthorization(read _: Set<HKObjectType>, write _: Set<HKSampleType>) async throws {
                lock.withLock { _requestAuthorizationCount += 1 }
                await authorizationGate?.wait()
                if let authorizationError { throw authorizationError }
            }

            func resetAuthDisabledTypes() async {}
            func defaultReadTypes() -> Set<HKObjectType> {
                [HKObjectType.workoutType()]
            }

            func defaultWriteTypes() -> Set<HKSampleType> {
                []
            }

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
