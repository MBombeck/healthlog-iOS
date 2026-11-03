// Diese Suite testet App-Target-Symbole (`AppContainer`), die in der
// SPM-Library nicht enthalten sind.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import os
    import Testing

    /// **R-A2 (1.4) — the dose and State-of-Mind observers start at launch.**
    ///
    /// Up to 1.3 `RootView` armed both after eight awaits of its phase task,
    /// so a launch that never drew a view never registered them. They are now
    /// armed while the container is built (signed-in installations only) and
    /// again whenever an account is admitted, and arming twice must not start
    /// two observers.
    @MainActor
    @Suite("R-A2 — opt-in HealthKit observers start at launch", .serialized, .timeLimit(.minutes(1)))
    struct LaunchHealthObserverTests {
        private static func makeContainer(keychain: InMemoryKeychain, writer: MoodStartCountingWriter) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: writer
            )
        }

        /// Runs `body` with the State-of-Mind toggle on in the standard
        /// defaults the container's store reads, and puts the old value back.
        private static func withMoodSyncOn(_ body: () async throws -> Void) async rethrows {
            let key = MoodHealthSyncStore.prefKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer {
                if let previous {
                    UserDefaults.standard.set(previous, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            try await body()
        }

        private static func signedInKeychain() throws -> InMemoryKeychain {
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-launch", forKey: KeychainKey.authToken)
            try keychain.setString("user-launch", forKey: KeychainKey.userID)
            return keychain
        }

        @Test("a signed-in launch arms the State-of-Mind observer without any view")
        func signedInLaunchArms() async throws {
            try await Self.withMoodSyncOn {
                let writer = MoodStartCountingWriter()
                let container = try Self.makeContainer(keychain: Self.signedInKeychain(), writer: writer)
                #expect(await phase09AwaitCondition { writer.moodStartCount >= 1 })
                #expect(writer.lastUserID == "user-launch")
                withExtendedLifetime(container) {}
            }
        }

        @Test("a launch without an account arms nothing")
        func signedOutLaunchArmsNothing() async {
            await Self.withMoodSyncOn {
                let writer = MoodStartCountingWriter()
                let container = Self.makeContainer(keychain: InMemoryKeychain(), writer: writer)
                await phase09Settle { writer.moodStartCount > 0 }
                #expect(writer.moodStartCount == 0)
                withExtendedLifetime(container) {}
            }
        }

        @Test("an admitted account arms again through the same idempotent path")
        func admissionArmsAgain() async throws {
            try await Self.withMoodSyncOn {
                let writer = MoodStartCountingWriter()
                let container = try Self.makeContainer(keychain: Self.signedInKeychain(), writer: writer)
                #expect(await phase09AwaitCondition { writer.moodStartCount >= 1 })
                let before = writer.moodStartCount

                container.authenticatedSessionRegistry.activate(ownerID: "user-launch")

                #expect(await phase09AwaitCondition { writer.moodStartCount > before })
                withExtendedLifetime(container) {}
            }
        }

        @Test("two callers at once arm one dose observer and stop none", .mockURLSession)
        func concurrentArmingArmsOnce() async throws {
            let suite = "a3.launch.medobserver.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: MedicationHealthSyncStore.prefKey)
            let (api, keychain) = MedFixtures.makeAPI()
            let reader = SlowArmingReader()
            let store = try MedicationHealthSyncStore(
                repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
                keychain: keychain,
                reader: reader,
                defaults: defaults
            )

            async let launch: Void = store.startObservingIfEnabled()
            async let admission: Void = store.startObservingIfEnabled()
            _ = await (launch, admission)

            #expect(reader.observeCount == 1)
            // Stopping a second observer would switch background delivery for
            // the dose type off for the whole app.
            #expect(reader.stopCount == 0)
        }
    }

    /// A writer that only counts how often the State-of-Mind import is started.
    final class MoodStartCountingWriter: AnyHealthKitWriter, @unchecked Sendable {
        private struct State {
            var starts = 0
            var userID: String?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var moodStartCount: Int {
            state.withLock { $0.starts }
        }

        var lastUserID: String? {
            state.withLock { $0.userID }
        }

        func startMoodImport(repo _: MoodRepository, userID: String?) async {
            state.withLock {
                $0.starts += 1
                $0.userID = userID
            }
        }

        func write(_: HealthLog.Measurement) async throws {}
        func writeMood(_: MoodEntry) async throws {}
        func deleteMood(id _: String) async throws {}
        func requestMoodAuthorization() async throws {}
        func stopMoodImport() async {}
        func resetMoodImport() async {}
        func activateBackgroundDeliveries() async throws {}
        func runBackgroundSyncPass() async {}
        func attachUploader(_: MeasurementBatchUploader) async {}
        func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
        func setInitialBackfillCutoff(_: Date?) async {}
        func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
    }

    /// A dose reader whose arming takes a moment, so a second caller arrives
    /// while the first is still arming.
    private final class SlowArmingReader: AppleHealthMedicationReading, @unchecked Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: (observe: 0, stop: 0))

        var observeCount: Int {
            counts.withLock { $0.observe }
        }

        var stopCount: Int {
            counts.withLock { $0.stop }
        }

        var isAvailable: Bool {
            true
        }

        func requestAuthorization() async throws {}

        func readMedications() async throws -> [AppleHealthMedicationRecord] {
            []
        }

        func readDoseEvents(since _: Date?) async throws -> [AppleHealthDoseRecord] {
            []
        }

        func observeDoseEvents(
            _: @escaping @Sendable () async -> Void
        ) async -> (any AppleHealthDoseEventObservation)? {
            counts.withLock { $0.observe += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return Observation(reader: self)
        }

        fileprivate func noteStop() {
            counts.withLock { $0.stop += 1 }
        }

        private struct Observation: AppleHealthDoseEventObservation {
            let reader: SlowArmingReader

            func stop() async {
                reader.noteStop()
            }
        }
    }

#endif
