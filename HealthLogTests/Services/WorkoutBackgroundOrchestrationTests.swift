#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("WorkoutBackgroundOrchestrationTests", .serialized)
    struct WorkoutBackgroundOrchestrationTests {
        @Test("Cold background launch is wired before any RootView task")
        func coldLaunchUsesCompositionRootWiring() async throws {
            let keychain = InMemoryKeychain()
            try seedSession(userID: "user-A", in: keychain)
            let writer = WorkoutOrchestrationWriter()
            let container = makeContainer(keychain: keychain, writer: writer)
            await container.authStore.bootstrap()

            let didRun = await container.backgroundSync.runWorkoutSync(mode: .processing)

            #expect(didRun)
            #expect(writer.requests == [.init(userID: "user-A", mode: .processing)])
        }

        @Test("Missing or expired authentication never reaches the workout writer")
        func missingOrExpiredAuthenticationIsRejected() async throws {
            let keychain = InMemoryKeychain()
            let writer = WorkoutOrchestrationWriter()
            let container = makeContainer(keychain: keychain, writer: writer)
            await container.authStore.bootstrap()

            let missingAuthDidRun = await container.backgroundSync.runWorkoutSync(mode: .processing)
            #expect(!missingAuthDidRun)

            // Model an expired session whose UI phase has not reacted yet: the
            // bearer is gone while the old authenticated phase is still visible.
            container.authStore.setPhaseForTesting(.authenticated(testUser(id: "user-A")))
            try keychain.setString("user-A", forKey: KeychainKey.userID)

            let expiredAuthDidRun = await container.backgroundSync.runWorkoutSync(mode: .processing)
            #expect(!expiredAuthDidRun)
            #expect(writer.requests.isEmpty)
        }

        @Test("Account switch during an await cannot report user-A work into user B")
        func accountSwitchDuringPassIsRejectedAfterAwait() async throws {
            let keychain = InMemoryKeychain()
            try seedSession(userID: "user-A", in: keychain)
            let writer = WorkoutOrchestrationWriter(blockPasses: true)
            let container = makeContainer(keychain: keychain, writer: writer)
            await container.authStore.bootstrap()

            let userAPass = Task {
                await container.backgroundSync.runWorkoutSync(mode: .processing)
            }
            await writer.passStarted.wait()

            try keychain.removeAll()
            try seedSession(userID: "user-B", in: keychain)
            container.authStore.setPhaseForTesting(.authenticated(testUser(id: "user-B")))
            writer.releasePasses()

            let userADidRun = await userAPass.value
            #expect(!userADidRun)
            #expect(writer.requests == [.init(userID: "user-A", mode: .processing)])

            writer.setBlocking(false)
            #expect(await container.backgroundSync.runWorkoutSync(mode: .processing))
            #expect(writer.requests.last == .init(userID: "user-B", mode: .processing))
        }

        @Test("Concurrent foreground and background requests retain one authenticated partition")
        func concurrentRoutesUseSameAuthenticatedPartition() async throws {
            let keychain = InMemoryKeychain()
            try seedSession(userID: "user-A", in: keychain)
            let writer = WorkoutOrchestrationWriter(blockPasses: true)
            let container = makeContainer(keychain: keychain, writer: writer)
            await container.authStore.bootstrap()

            let foreground = Task {
                await writer.runWorkoutSyncPass(
                    repo: container.serverStatsRepos.workouts,
                    userID: "user-A",
                    mode: .incrementalOnly,
                    onIngest: nil
                )
            }
            await writer.passStarted.wait()
            let background = Task {
                await container.backgroundSync.runWorkoutSync(mode: .processing)
            }
            await writer.waitForRequestCount(2)
            writer.releasePasses()

            #expect(await foreground.value)
            #expect(await background.value)
            #expect(Set(writer.requests.map(\.userID)) == ["user-A"])
            #expect(Set(writer.requests.map(\.mode)) == [.incrementalOnly, .processing])
        }

        @Test("Short wakes are incremental-only and writer-gated by anchor availability")
        func shortWakeAnchorPolicy() async throws {
            let keychain = InMemoryKeychain()
            try seedSession(userID: "user-A", in: keychain)
            let writer = WorkoutOrchestrationWriter(anchorAvailable: false)
            let container = makeContainer(keychain: keychain, writer: writer)
            await container.authStore.bootstrap()

            let anchorlessDidRun = await container.backgroundSync.runWorkoutSync(mode: .incrementalOnly)
            #expect(!anchorlessDidRun)
            #expect(writer.requests.isEmpty)

            writer.setAnchorAvailable(true)
            #expect(await container.backgroundSync.runWorkoutSync(mode: .incrementalOnly))
            #expect(writer.requests == [.init(userID: "user-A", mode: .incrementalOnly)])
        }

        #if canImport(HealthKit)
            @Test("Persisted-anchor eligibility reads the HealthKit service's injected defaults")
            func anchorEligibilityUsesInjectedDefaults() throws {
                let suite = "workout-orchestration-anchor-\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                defer { defaults.removePersistentDomain(forName: suite) }
                let userID = "anchor-user"

                #expect(!HealthKitService.hasPersistedWorkoutAnchor(userID: userID, defaults: defaults))

                let key = "hl.workout.hk.anchor." + HealthKitService.partitionToken(for: userID)
                defaults.set(Data([0x01]), forKey: key)

                #expect(HealthKitService.hasPersistedWorkoutAnchor(userID: userID, defaults: defaults))
            }
        #endif

        private func makeContainer(
            keychain: InMemoryKeychain,
            writer: WorkoutOrchestrationWriter
        ) -> AppContainer {
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

        private func seedSession(userID: String, in keychain: InMemoryKeychain) throws {
            try keychain.setString("token-\(userID)", forKey: KeychainKey.authToken)
            try keychain.setString(userID, forKey: KeychainKey.userID)
        }

        private func testUser(id: String) -> User {
            User(id: id, email: nil, username: nil, displayName: nil, createdAt: .now)
        }
    }

    private final class WorkoutOrchestrationWriter: AnyHealthKitWriter, @unchecked Sendable {
        struct Request: Equatable, Sendable {
            let userID: String
            let mode: WorkoutSyncPassMode
        }

        let passStarted = WorkoutOrchestrationGate()
        private let release = WorkoutOrchestrationGate()
        private let lock = NSLock()
        private var _requests: [Request] = []
        private var anchorAvailable: Bool
        private var blockPasses: Bool

        init(anchorAvailable: Bool = true, blockPasses: Bool = false) {
            self.anchorAvailable = anchorAvailable
            self.blockPasses = blockPasses
        }

        var requests: [Request] {
            lock.withLock { _requests }
        }

        func setAnchorAvailable(_ available: Bool) {
            lock.withLock { anchorAvailable = available }
        }

        func setBlocking(_ blocking: Bool) {
            lock.withLock { blockPasses = blocking }
        }

        func releasePasses() {
            release.set()
        }

        func waitForRequestCount(_ expected: Int) async {
            while requests.count < expected {
                await Task.yield()
            }
        }

        func runWorkoutSyncPass(
            repo _: WorkoutsRepository,
            userID: String?,
            mode: WorkoutSyncPassMode,
            onIngest _: (@Sendable () async -> Void)?
        ) async -> Bool {
            let shouldRun: Bool = lock.withLock {
                mode != .incrementalOnly || anchorAvailable
            }
            guard shouldRun, let userID, !userID.isEmpty else { return false }
            lock.withLock { _requests.append(.init(userID: userID, mode: mode)) }
            passStarted.set()
            let shouldBlock = lock.withLock { blockPasses }
            if shouldBlock {
                await release.wait()
            }
            return !Task.isCancelled
        }

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

    private final class WorkoutOrchestrationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func set() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                guard !isSet else { return [] }
                isSet = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let alreadySet: Bool = lock.withLock {
                    if isSet { return true }
                    waiters.append(continuation)
                    return false
                }
                if alreadySet { continuation.resume() }
            }
        }
    }

#endif
