// The process start without a scene.
//
// iOS starts the app for a HealthKit delivery, a background task or a silent
// push without connecting a scene, so no view task runs. These tests drive the
// launch step `HealthLogApp.init` runs right after the container is built and
// check the three facts a background wake depends on: the stored account is
// admitted, the sample observers are registered, and a pass is let through.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    /// A passkey service that is never asked: launch restores read the Keychain only.
    private final class LaunchNoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        @MainActor func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("noop")
        }

        @MainActor func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("noop")
        }
    }

    @MainActor
    @Suite("Launch session activation", .serialized, .mockURLSession)
    struct LaunchSessionActivationTests {
        // MARK: - Harness

        private struct Fixture {
            let store: AuthStore
            let keychain: InMemoryKeychain
            let registry: AuthenticatedSessionLeaseRegistry
            let admission: HealthSyncImporterAdmission
        }

        private final class Calls {
            var wakes = 0
            var arms = 0
            var imports = 0
        }

        private static let owner = "usr_launch_1"

        private func makeFixture(token: String? = "launch-bearer", userID: String? = owner) throws -> Fixture {
            let keychain = InMemoryKeychain()
            if let token { try keychain.setString(token, forKey: KeychainKey.authToken) }
            if let userID { try keychain.setString(userID, forKey: KeychainKey.userID) }
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
            let auth = AuthService(api: api, keychain: keychain, passkey: LaunchNoopPasskey())
            let registry = AuthenticatedSessionLeaseRegistry()
            let suite = "launch-session.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let store = AuthStore(auth: auth, keychain: keychain, defaults: defaults, sessionRegistry: registry)
            return Fixture(
                store: store,
                keychain: keychain,
                registry: registry,
                admission: .keychainBound(keychain: keychain, registry: registry)
            )
        }

        @discardableResult
        private func launch(
            _ fixture: Fixture,
            readsHealthKit: Bool = true,
            healthKitRequested: Bool = true,
            calls: Calls
        ) -> LaunchSessionActivation.Outcome {
            LaunchSessionActivation.run(
                authStore: fixture.store,
                steps: steps(readsHealthKit: readsHealthKit, healthKitRequested: { healthKitRequested }, calls: calls)
            )
        }

        private func steps(
            readsHealthKit: Bool = true,
            healthKitRequested: @escaping () -> Bool = { true },
            calls: Calls
        ) -> LaunchSessionActivation.Steps {
            LaunchSessionActivation.Steps(
                readsHealthKit: readsHealthKit,
                healthKitRequested: healthKitRequested,
                scheduleWakes: { calls.wakes += 1 },
                armObservers: { calls.arms += 1 },
                startImports: { calls.imports += 1 }
            )
        }

        // MARK: - Session

        @Test("a stored session is admitted at launch, without bootstrap and without a scene")
        func storedSessionIsAdmittedAtLaunch() throws {
            let fixture = try makeFixture()
            #expect(fixture.admission.refusal(for: .speziSamples) == .notAdmitted)

            let calls = Calls()
            let outcome = launch(fixture, calls: calls)

            #expect(outcome == .init(
                sessionAdmitted: true,
                wakesScheduled: true,
                observersRequested: true,
                importsStarted: true
            ))
            #expect(AuthStore.sessionOwner(in: fixture.store.phase) == Self.owner)
            #expect(fixture.registry.capture(ownerID: Self.owner) != nil)
            #expect(fixture.admission.refusal(for: .speziSamples) == nil)
            #expect(calls.wakes == 1)
            #expect(calls.arms == 1)
            // Workouts, heart events and ECG start without a scene too.
            #expect(calls.imports == 1)
        }

        @Test("bootstrap after the launch re-asserts the owner without moving the session generation")
        func bootstrapKeepsLaunchLeaseCurrent() async throws {
            let fixture = try makeFixture()
            launch(fixture, calls: Calls())
            let lease = try #require(fixture.registry.capture(ownerID: Self.owner))

            await fixture.store.bootstrap()

            #expect(AuthStore.sessionOwner(in: fixture.store.phase) == Self.owner)
            // A wake that captured its lease at launch keeps running when the
            // scene later connects and its view task bootstraps.
            #expect(lease.ownsRegistryGeneration)
        }

        @Test("without a token nothing is admitted, scheduled or armed")
        func signedOutInstallationArmsNothing() throws {
            let fixture = try makeFixture(token: nil)
            let calls = Calls()

            let outcome = launch(fixture, calls: calls)

            #expect(outcome == .init())
            #expect(fixture.store.phase == .unknown)
            #expect(fixture.registry.capture(ownerID: Self.owner) == nil)
            #expect(calls.wakes == 0)
            #expect(calls.arms == 0)
            #expect(calls.imports == 0)
        }

        @Test("a blanked user id stays unknown for the bootstrap repair")
        func blankedIdentityIsLeftToBootstrap() throws {
            let fixture = try makeFixture(userID: "  ")
            let calls = Calls()

            let outcome = launch(fixture, calls: calls)

            #expect(outcome == .init())
            #expect(fixture.store.phase == .unknown)
            #expect(calls.wakes == 0)
        }

        @Test("the iPad admits the session and schedules wakes but arms no HealthKit observer")
        func padArmsNoObservers() throws {
            let fixture = try makeFixture()
            let calls = Calls()

            let outcome = launch(fixture, readsHealthKit: false, calls: calls)

            #expect(outcome == .init(sessionAdmitted: true, wakesScheduled: true))
            #expect(calls.arms == 0)
            #expect(calls.imports == 0)
        }

        @Test("an account that never saw the HealthKit sheet arms no observer")
        func unrequestedHealthKitArmsNoObservers() throws {
            let fixture = try makeFixture()
            let calls = Calls()

            let outcome = launch(fixture, healthKitRequested: false, calls: calls)

            #expect(outcome.sessionAdmitted)
            #expect(!outcome.observersRequested)
            #expect(!outcome.importsStarted)
            #expect(calls.arms == 0)
        }

        @Test("a phase already resolved is left alone")
        func resolvedPhaseIsLeftAlone() async throws {
            let fixture = try makeFixture(token: nil)
            await fixture.store.bootstrap()
            #expect(fixture.store.phase == .unauthenticated)
            try fixture.keychain.setString("late-token", forKey: KeychainKey.authToken)

            #expect(!fixture.store.restoreStoredSessionAtLaunch())
            #expect(fixture.store.phase == .unauthenticated)
        }

        // MARK: - Lock

        @Test("the cold-launch lock still fires for a session restored at launch")
        func coldLaunchLockStillFires() throws {
            let fixture = try makeFixture()
            launch(fixture, calls: Calls())
            var clock = AppLockClock()

            // The first phase the window sees is the restored one; nobody
            // signed in during this process, so the lock is due.
            let locks = clock.authPhaseChanged(to: fixture.store.phase, lockEnabled: true)
            #expect(locks)
        }

        @Test("a cold launch with a session and the lock on composes the shield first, never the content")
        func firstCompositionIsShielded() throws {
            let fixture = try makeFixture()
            launch(fixture, calls: Calls())

            let initiallyLocked = AppLockClock.startsLocked(phase: fixture.store.phase, lockEnabled: true)

            #expect(initiallyLocked)
            // Whatever the scene phase of the first frame: the shield is the
            // only view at the root, `AuthenticatedShell` is not built.
            #expect(
                RootPrivacyShieldPolicy.resolve(sceneIsActive: true, biometricLocked: initiallyLocked)
                    == .protected(.biometricLocked)
            )
            #expect(
                RootPrivacyShieldPolicy.resolve(sceneIsActive: false, biometricLocked: initiallyLocked)
                    == .protected(.inactive)
            )
        }

        @Test("the lock off, or no stored session, starts unlocked as before")
        func startsUnlockedWithoutSessionOrSetting() throws {
            let fixture = try makeFixture()
            launch(fixture, calls: Calls())
            #expect(!AppLockClock.startsLocked(phase: fixture.store.phase, lockEnabled: false))
            #expect(!AppLockClock.startsLocked(phase: .unknown, lockEnabled: true))
            #expect(!AppLockClock.startsLocked(phase: .unauthenticated, lockEnabled: true))
        }

        // MARK: - Before the first unlock

        @Test("a sealed Keychain at launch is admitted again once protected data arrives")
        func protectedDataRetryAdmitsTheSession() async throws {
            // Before the first unlock the Keychain answers nothing.
            let fixture = try makeFixture(token: nil)
            let calls = Calls()
            let first = launch(fixture, calls: calls)
            #expect(!first.sessionAdmitted)
            #expect(fixture.store.phase == .unknown)

            let (signal, unlock) = AsyncStream<Void>.makeStream()
            let launchSteps = steps(calls: calls)
            let store = fixture.store
            let retry = Task {
                await LaunchSessionActivation.retryWhenProtectedDataArrives(signal, authStore: store) {
                    LaunchSessionActivation.run(authStore: store, steps: launchSteps)
                }
            }
            // The device is unlocked: the Keychain opens, then iOS posts.
            try fixture.keychain.setString("launch-bearer", forKey: KeychainKey.authToken)
            unlock.yield()

            let second = await retry.value
            #expect(second?.sessionAdmitted == true)
            #expect(second?.observersRequested == true)
            #expect(AuthStore.sessionOwner(in: fixture.store.phase) == Self.owner)
            #expect(calls.wakes == 1)
            #expect(calls.arms == 1)
        }

        @Test("no retry when a scene resolved the session before the unlock signal")
        func protectedDataRetrySkipsResolvedPhase() async throws {
            let fixture = try makeFixture(token: nil)
            await fixture.store.bootstrap()
            let calls = Calls()
            let (signal, unlock) = AsyncStream<Void>.makeStream()
            unlock.yield()
            let launchSteps = steps(calls: calls)

            let outcome = await LaunchSessionActivation.retryWhenProtectedDataArrives(
                signal,
                authStore: fixture.store
            ) {
                LaunchSessionActivation.run(authStore: fixture.store, steps: launchSteps)
            }

            #expect(outcome == nil)
            #expect(calls.wakes == 0)
        }

        // MARK: - Wakes

        @Test("a launch submits only the wakes that are not waiting")
        func launchKeepsWaitingWakes() {
            let sync = BackgroundSyncCoordinator.bgTaskIdentifier
            let refresh = BackgroundSyncCoordinator.bgRefreshTaskIdentifier

            #expect(BackgroundSyncCoordinator.wakesToSubmit(pending: [], registersHealthKitTask: true) == [sync, refresh])
            // A waiting request keeps its date: it is not submitted again.
            #expect(BackgroundSyncCoordinator.wakesToSubmit(pending: [refresh], registersHealthKitTask: true) == [sync])
            #expect(BackgroundSyncCoordinator.wakesToSubmit(pending: [sync, refresh], registersHealthKitTask: true).isEmpty)
            // The iPad never submits the HealthKit task.
            #expect(BackgroundSyncCoordinator.wakesToSubmit(pending: [], registersHealthKitTask: false) == [refresh])
        }

        // MARK: - Older installations

        #if canImport(HealthKit)
            @Test("an older installation with grants but no marker is migrated before the launch gate")
            func grantedInstallWithoutMarkerIsObservedAtLaunch() throws {
                let fixture = try makeFixture()
                let suite = "launch-marker.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                // Onboarded before v0.4.1: write access granted, marker never set.
                let readiness = HKReadinessStore(
                    healthKit: MutableWriteStatusService(
                        statuses: [MutableWriteStatusService.bodyMassID: .sharingAuthorized]
                    ),
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: fixture.keychain,
                    defaults: defaults
                )
                #expect(!readiness.hasEverRequestedAuthorization)
                let calls = Calls()

                let outcome = LaunchSessionActivation.run(
                    authStore: fixture.store,
                    steps: steps(healthKitRequested: { readiness.migrateRequestedMarkerFromGrants() }, calls: calls)
                )

                #expect(outcome.observersRequested)
                #expect(calls.arms == 1)
                #expect(readiness.hasEverRequestedAuthorization)
            }

            @Test("without any grant the marker stays unset and nothing is observed")
            func deniedInstallWithoutMarkerStaysUnobserved() throws {
                let fixture = try makeFixture()
                let suite = "launch-marker.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                let readiness = HKReadinessStore(
                    healthKit: MutableWriteStatusService(
                        statuses: [MutableWriteStatusService.bodyMassID: .notDetermined]
                    ),
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: fixture.keychain,
                    defaults: defaults
                )
                let calls = Calls()

                let outcome = LaunchSessionActivation.run(
                    authStore: fixture.store,
                    steps: steps(healthKitRequested: { readiness.migrateRequestedMarkerFromGrants() }, calls: calls)
                )

                #expect(!outcome.observersRequested)
                #expect(calls.arms == 0)
                #expect(!readiness.hasEverRequestedAuthorization)
            }
        #endif
    }

    #if canImport(HealthKit) && canImport(SpeziHealthKit)
        @MainActor
        @Suite("Launch observer arming", .serialized, .mockURLSession)
        struct LaunchObserverArmingTests {
            private static let owner = "usr_launch_arm"

            private struct Harness {
                let coordinator: AppOwnedHealthCollectionCoordinator
                let observer: RecordingObserver
                let source: ScriptedPageSource
            }

            private func makeHarness(
                registry: AuthenticatedSessionLeaseRegistry,
                keychain: InMemoryKeychain
            ) throws -> Harness {
                let suite = "launch-arming.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                let cursors = DurableHealthCursorStore(storage: CollectorCursorBacking().storage)
                let observer = RecordingObserver()
                let source = ScriptedPageSource(pages: [])
                // The production admission: the Keychain's owner, admitted only
                // while the shared registry holds that owner.
                let admission: @Sendable () throws -> HealthSyncAuthenticatedLease = {
                    try HealthSyncAuthenticatedLease.admit(
                        from: registry,
                        ownerID: keychain.getString(forKey: KeychainKey.userID) ?? "",
                        source: .speziSamples,
                        bearerProvider: { keychain.getString(forKey: KeychainKey.authToken) }
                    )
                }
                let coordinator = AppOwnedHealthCollectionCoordinator(
                    collector: AnchoredHealthSampleCollector(
                        cursors: cursors,
                        query: source,
                        consumer: ScriptedConsumer(outcomes: []),
                        observer: observer
                    ),
                    cursors: cursors,
                    admission: admission,
                    cutoff: { Date(timeIntervalSince1970: 1_700_000_000) },
                    defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
                )
                return Harness(coordinator: coordinator, observer: observer, source: source)
            }

            private func signedInKeychain() throws -> InMemoryKeychain {
                let keychain = InMemoryKeychain()
                try keychain.setString("arm-bearer", forKey: KeychainKey.authToken)
                try keychain.setString(Self.owner, forKey: KeychainKey.userID)
                return keychain
            }

            @Test("an admitted launch registers the observers without running a pass")
            func admittedLaunchRegistersObservers() async throws {
                let registry = AuthenticatedSessionLeaseRegistry()
                let harness = try makeHarness(registry: registry, keychain: signedInKeychain())
                registry.activate(ownerID: Self.owner)

                #expect(await harness.coordinator.armAtLaunch())

                let expected = AppOwnedHealthCollectionCoordinator.serverCollectable(
                    AppOwnedHealthCollectionCoordinator.observedTypeIdentifiers
                )
                #expect(!expected.isEmpty)
                #expect(harness.observer.observedTypes == expected)
                // Arming reads nothing: the wake that launched the process
                // runs its own pass.
                #expect(harness.source.queryCount == 0)
            }

            @Test("without an admitted account no observer is registered")
            func unadmittedLaunchRegistersNothing() async throws {
                let registry = AuthenticatedSessionLeaseRegistry()
                let harness = try makeHarness(registry: registry, keychain: signedInKeychain())

                #expect(await !harness.coordinator.armAtLaunch())
                #expect(harness.observer.observedTypes.isEmpty)
            }

            @Test("a background pass is refused before the fix and admitted after the launch step")
            func launchStepLetsTheBackgroundPassThrough() async throws {
                let keychain = try signedInKeychain()
                let registry = AuthenticatedSessionLeaseRegistry()
                let harness = try makeHarness(registry: registry, keychain: keychain)

                // The old background launch: nobody bootstrapped, so the pass
                // is refused for want of an admitted account.
                let refused = await harness.coordinator.run(.processing)
                #expect(refused.failure == .notAdmitted)

                // The launch step on the same Keychain, with the real store.
                let baseURL = try #require(URL(string: "https://test.healthlog.local"))
                let environment = AppEnvironment(
                    baseURL: baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.1.0",
                    buildNumber: "1"
                )
                let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
                let auth = AuthService(api: api, keychain: keychain, passkey: LaunchNoopPasskey())
                let store = AuthStore(auth: auth, keychain: keychain, sessionRegistry: registry)
                LaunchSessionActivation.run(
                    authStore: store,
                    steps: .init(readsHealthKit: true, healthKitRequested: { true }, scheduleWakes: {}, armObservers: {})
                )

                let admitted = await harness.coordinator.run(.processing)
                #expect(admitted.disposition == .ran)
                #expect(admitted.failure == nil)
                #expect(!harness.observer.observedTypes.isEmpty)
            }

            @Test("a launch that asks before the composition installed is served on install")
            func requestBeforeInstallIsServed() async throws {
                HealthObserverLaunchArming.resetForTesting()
                defer { HealthObserverLaunchArming.resetForTesting() }
                let registrations = Mutex(0)
                let register: HealthObserverLaunchArming.Register = {
                    registrations.withLock { $0 += 1 }
                    return 1
                }

                // Asked first, installed second: served on install.
                #expect(HealthObserverLaunchArming.request() == nil)
                #expect(registrations.withLock { $0 } == 0)
                let served = try #require(HealthObserverLaunchArming.install(register: register) { true })
                #expect(registrations.withLock { $0 } == 1)
                #expect(await served.value)

                // Installed first, asked second: served at once, and only once.
                let direct = try #require(HealthObserverLaunchArming.request())
                #expect(registrations.withLock { $0 } == 2)
                #expect(await direct.value)
                #expect(HealthObserverLaunchArming.install(register: register) { true } == nil)
            }

            @Test("the launch registers every observer before it returns and prepares afterwards")
            func registrationIsSynchronousPreparationIsNot() async throws {
                HealthObserverLaunchArming.resetForTesting()
                defer { HealthObserverLaunchArming.resetForTesting() }
                let registrations = Mutex(0)
                let prepared = Mutex(false)
                let release = AsyncStream<Void>.makeStream()
                HealthObserverLaunchArming.install(
                    register: {
                        registrations.withLock { $0 += 1 }
                        return AppOwnedHealthCollectionCoordinator.observedTypeIdentifiers.count
                    },
                    prepare: {
                        // The migration is still running.
                        for await _ in release.stream {
                            break
                        }
                        prepared.withLock { $0 = true }
                        return true
                    }
                )

                let preparation = try #require(HealthObserverLaunchArming.request())

                // Registered inside the call, while the preparation still waits.
                #expect(registrations.withLock { $0 } == 1)
                #expect(!prepared.withLock { $0 })
                release.continuation.yield()
                #expect(await preparation.value)
                #expect(prepared.withLock { $0 })
            }

            @Test("a delivery before the preparation waits for it and is then handled once")
            func deliveryWaitsForTheReadySignal() async {
                let gate = HealthSampleDeliveryGate()
                let handled = Mutex<[String]>([])
                let delivery = Task { await gate.deliver(CollectorFixture.stepType) }
                while gate.waitingCount == 0 {
                    await Task.yield()
                }
                #expect(handled.withLock { $0 }.isEmpty)
                #expect(!gate.isOpen)

                gate.open { typeIdentifier in handled.withLock { $0.append(typeIdentifier) } }
                await delivery.value
                #expect(handled.withLock { $0 } == [CollectorFixture.stepType])

                // Open: a later delivery goes straight through.
                await gate.deliver(CollectorFixture.stepType)
                #expect(handled.withLock { $0 }.count == 2)
            }

            @Test("a sign-out drops a waiting delivery instead of handling it later")
            func closedGateDropsWaitingDeliveries() async {
                let gate = HealthSampleDeliveryGate()
                let handled = Mutex(0)
                let delivery = Task { await gate.deliver(CollectorFixture.stepType) }
                while gate.waitingCount == 0 {
                    await Task.yield()
                }
                gate.close()
                await delivery.value
                gate.open { _ in handled.withLock { $0 += 1 } }
                #expect(handled.withLock { $0 } == 0)
                #expect(gate.waitingCount == 0)
            }
        }
    #endif

#endif
