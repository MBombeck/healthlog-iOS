import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    @Suite("Workout HealthKit background-delivery lifecycle", .serialized)
    struct WorkoutBackgroundDeliveryTests {
        @Test("Observer executes before immediate delivery is enabled and before the initial sweep")
        func executeEnableSweepOrdering() async throws {
            let harness = try makeHarness()

            await harness.importer.start()

            #expect(await harness.events.snapshot() == [.execute, .enable, .sweep])
        }

        @Test("Repeated start enables delivery exactly once")
        func repeatedStartIsIdempotent() async throws {
            let harness = try makeHarness()

            await harness.importer.start()
            await harness.importer.start()

            #expect(await harness.events.count(.execute) == 1)
            #expect(await harness.events.count(.enable) == 1)
            #expect(await harness.events.count(.sweep) == 1)
        }

        @Test("An explicit page on a live observer does not stop or re-register delivery")
        func explicitPageKeepsLiveLifecycleStable() async throws {
            let harness = try makeHarness()
            await harness.importer.start()

            let didRun = await harness.importer.runBoundedPage(mode: .incrementalOnly)

            #expect(didRun.didRun)
            #expect(await harness.events.snapshot() == [.execute, .enable, .sweep, .sweep])
        }

        @Test("Observer callback returns promptly before its asynchronous sweep")
        func observerCallbackIsPrompt() async throws {
            let harness = try makeHarness()
            await harness.importer.start()

            await harness.lifecycle.fireObserverUpdate()

            #expect(await harness.lifecycle.callbackReturnCount() == 1)
            await waitForEventCount(.sweep, count: 2, in: harness.events)
            #expect(await harness.events.count(.sweep) == 2)
        }

        @Test("Activation failure stops the observer and does not sweep")
        func activationFailureRollsBack() async throws {
            let harness = try makeHarness(enableFailures: 1)

            await harness.importer.start()

            #expect(await harness.events.snapshot() == [.execute, .enable, .stop])
        }

        @Test("Observer callbacks received during activation are discarded")
        func callbackDuringActivationIsDiscarded() async throws {
            let enableGate = SuspensionGate()
            let harness = try makeHarness(enableGate: enableGate)
            let start = Task { await harness.importer.start() }
            await waitForEventCount(.enable, count: 1, in: harness.events)

            await harness.lifecycle.fireObserverUpdate()
            await Task.yield()
            #expect(await harness.events.count(.sweep) == 0)

            await enableGate.open()
            await start.value
            #expect(await harness.events.count(.sweep) == 1)
        }

        @Test("Observer callbacks received before failed activation never sweep")
        func callbackDuringFailedActivationIsDiscarded() async throws {
            let enableGate = SuspensionGate()
            let harness = try makeHarness(enableFailures: 1, enableGate: enableGate)
            let start = Task { await harness.importer.start() }
            await waitForEventCount(.enable, count: 1, in: harness.events)

            await harness.lifecycle.fireObserverUpdate()
            await enableGate.open()
            await start.value
            await Task.yield()

            #expect(await harness.events.count(.sweep) == 0)
        }

        @Test("A failed activation leaves start retryable")
        func activationFailureCanRetry() async throws {
            let harness = try makeHarness(enableFailures: 1)

            await harness.importer.start()
            await harness.importer.start()

            #expect(await harness.events.snapshot() == [.execute, .enable, .stop, .execute, .enable, .sweep])
        }

        @Test("Stop invalidates a start suspended in observer execution")
        func stopInvalidatesBlockedObserverExecution() async throws {
            let executeGate = SuspensionGate()
            let harness = try makeHarness(executeGate: executeGate)
            let start = Task { await harness.importer.start() }
            await waitForEventCount(.execute, count: 1, in: harness.events)

            await harness.importer.stop()
            await executeGate.open()
            await start.value

            #expect(await harness.events.count(.enable) == 0)
            #expect(await harness.events.count(.sweep) == 0)
            #expect(await harness.events.count(.stop) == 2)
        }

        @Test("A stale successful enable is compensated after stop")
        func staleEnableIsDisabled() async throws {
            let enableGate = SuspensionGate()
            let harness = try makeHarness(enableGate: enableGate)
            let start = Task { await harness.importer.start() }
            await waitForEventCount(.enable, count: 1, in: harness.events)

            await harness.importer.stop()
            await enableGate.open()
            await start.value

            #expect(await harness.events.count(.sweep) == 0)
            #expect(await harness.events.count(.stop) == 2)
            #expect(await harness.events.count(.disable) == 2)
        }

        @Test("Replacement activation waits for stale enable compensation")
        func replacementWaitsForStaleActivationSettlement() async throws {
            let events = LifecycleEvents()
            let enableGate = SuspensionGate()
            let old = try makeHarness(userID: "user-A", enableGate: enableGate, events: events)
            let replacement = try makeHarness(userID: "user-B", events: events)
            let oldStart = Task { await old.importer.start() }
            await waitForEventCount(.enable, count: 1, in: events)

            let replace = Task {
                await old.importer.stopAndWaitUntilSettled()
                await replacement.importer.start()
            }
            await waitForEventCount(.disable, count: 1, in: events)
            #expect(await events.count(.enable) == 1)

            await enableGate.open()
            await oldStart.value
            await replace.value

            #expect(await events.count(.enable) == 2)
            let snapshot = await events.snapshot()
            #expect(snapshot.suffix(3) == [.execute, .enable, .sweep])
        }

        @Test("Stop removes the observer then disables only workout delivery")
        func stopDisablesWorkoutDelivery() async throws {
            let harness = try makeHarness()
            await harness.importer.start()

            await harness.importer.stop()

            #expect(await harness.events.snapshot().suffix(2) == [.stop, .disable])
            #expect(await harness.lifecycle.disabledTypes() == [HKObjectType.workoutType().identifier])
        }

        @Test("Transient delivery-disable failure is retried")
        func transientDisableFailureIsRetried() async throws {
            let harness = try makeHarness(disableFailures: 1)
            await harness.importer.start()

            await harness.importer.stop()

            #expect(await harness.events.count(.disable) == 2)
            #expect(await harness.lifecycle.disabledTypes() == [HKObjectType.workoutType().identifier])
        }

        @Test("Delivery-disable retries are bounded")
        func persistentDisableFailureIsBounded() async throws {
            let harness = try makeHarness(disableFailures: 10)
            await harness.importer.start()

            await harness.importer.stop()

            #expect(await harness.events.count(.disable) == 3)
            #expect(await harness.lifecycle.disabledTypes().isEmpty)
        }

        @Test("Stop cancels an in-flight observer sweep before its side effect")
        func stopCancelsInFlightSweep() async throws {
            let sweep = ControlledSweep(events: LifecycleEvents())
            let harness = try makeHarness(sweep: sweep)
            await harness.importer.start()

            await harness.lifecycle.fireObserverUpdate()
            await sweep.waitUntilBlocked()
            await harness.importer.stop()
            await sweep.release()
            await Task.yield()

            #expect(await sweep.sideEffectCount() == 0)
        }

        @Test("Reset cancels an in-flight observer sweep before its side effect")
        func resetCancelsInFlightSweep() async throws {
            let sweep = ControlledSweep(events: LifecycleEvents())
            let harness = try makeHarness(sweep: sweep)
            await harness.importer.start()

            await harness.lifecycle.fireObserverUpdate()
            await sweep.waitUntilBlocked()
            await harness.importer.resetAnchor()
            await sweep.release()
            await Task.yield()

            #expect(await sweep.sideEffectCount() == 0)
        }

        @Test("Reset clears only the importer user's workout anchor")
        func resetPreservesOtherUserAnchor() async throws {
            let suite = "workout-background-delivery-anchor-\(UUID().uuidString)"
            let userAKey = anchorKey(for: "user-A")
            let userBKey = anchorKey(for: "user-B")
            let seed = try #require(UserDefaults(suiteName: suite))
            seed.removePersistentDomain(forName: suite)
            seed.set(Data([0xA]), forKey: userAKey)
            seed.set(Data([0xB]), forKey: userBKey)

            let harness = try makeHarness(userID: "user-A", defaultsSuite: suite)
            await harness.importer.resetAnchor()

            let check = try #require(UserDefaults(suiteName: suite))
            #expect(check.data(forKey: userAKey) == nil)
            #expect(check.data(forKey: userBKey) == Data([0xB]))
        }

        private func makeHarness(
            userID: String = "workout-lifecycle-user",
            defaultsSuite: String? = nil,
            enableFailures: Int = 0,
            disableFailures: Int = 0,
            executeGate: SuspensionGate? = nil,
            enableGate: SuspensionGate? = nil,
            sweep: ControlledSweep? = nil,
            events sharedEvents: LifecycleEvents? = nil
        ) throws -> Harness {
            let events = sharedEvents ?? LifecycleEvents()
            let lifecycle = FakeWorkoutHealthKitStore(
                events: events,
                enableFailures: enableFailures,
                disableFailures: disableFailures,
                executeGate: executeGate,
                enableGate: enableGate
            )
            let suite = defaultsSuite ?? "workout-background-delivery-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            if defaultsSuite == nil {
                defaults.removePersistentDomain(forName: suite)
            }
            let importer = try WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: makeRepository(),
                userID: userID,
                defaults: defaults,
                lifecycleStore: lifecycle,
                sweepOverride: {
                    if let sweep {
                        await sweep.run()
                    } else {
                        await events.append(.sweep)
                    }
                }
            )
            return Harness(importer: importer, lifecycle: lifecycle, events: events)
        }

        private func makeRepository() throws -> WorkoutsRepository {
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            let api = APIClient(
                environment: environment,
                keychain: InMemoryKeychain(),
                sessionConfiguration: .mock()
            )
            return try WorkoutsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        }

        private func anchorKey(for userID: String) -> String {
            "hl.workout.hk.anchor." + HealthKitService.partitionToken(for: userID)
        }

        private func waitForEventCount(
            _ event: LifecycleEvent,
            count: Int,
            in events: LifecycleEvents
        ) async {
            for _ in 0 ..< 10000 {
                if await events.count(event) >= count { return }
                await Task.yield()
            }
        }
    }

    private struct Harness: Sendable {
        let importer: WorkoutHealthKitImporter
        let lifecycle: FakeWorkoutHealthKitStore
        let events: LifecycleEvents
    }

    private enum LifecycleEvent: Equatable, Sendable {
        case execute
        case enable
        case sweep
        case stop
        case disable
    }

    private actor LifecycleEvents {
        private var values: [LifecycleEvent] = []

        func append(_ event: LifecycleEvent) {
            values.append(event)
        }

        func snapshot() -> [LifecycleEvent] {
            values
        }

        func count(_ event: LifecycleEvent) -> Int {
            values.count { $0 == event }
        }
    }

    private actor FakeWorkoutHealthKitStore: WorkoutHealthKitStore {
        enum FakeError: Error {
            case activationFailed
        }

        private let events: LifecycleEvents
        private var remainingEnableFailures: Int
        private var remainingDisableFailures: Int
        private let executeGate: SuspensionGate?
        private let enableGate: SuspensionGate?
        private var observerUpdate: (@Sendable () -> Void)?
        private var callbackReturns = 0
        private var disabledTypeIdentifiers: [String] = []

        init(
            events: LifecycleEvents,
            enableFailures: Int,
            disableFailures: Int,
            executeGate: SuspensionGate?,
            enableGate: SuspensionGate?
        ) {
            self.events = events
            remainingEnableFailures = enableFailures
            remainingDisableFailures = disableFailures
            self.executeGate = executeGate
            self.enableGate = enableGate
        }

        func executeWorkoutObserver(onUpdate: @escaping @Sendable () -> Void) async {
            observerUpdate = onUpdate
            await events.append(.execute)
            await executeGate?.wait()
        }

        func stopWorkoutObserver() async {
            observerUpdate = nil
            await events.append(.stop)
        }

        func enableWorkoutBackgroundDelivery() async throws {
            await events.append(.enable)
            await enableGate?.wait()
            if remainingEnableFailures > 0 {
                remainingEnableFailures -= 1
                throw FakeError.activationFailed
            }
        }

        func disableWorkoutBackgroundDelivery() async throws {
            await events.append(.disable)
            if remainingDisableFailures > 0 {
                remainingDisableFailures -= 1
                throw FakeError.activationFailed
            }
            disabledTypeIdentifiers.append(HKObjectType.workoutType().identifier)
        }

        func fireObserverUpdate() {
            observerUpdate?()
            callbackReturns += 1
        }

        func callbackReturnCount() -> Int {
            callbackReturns
        }

        func disabledTypes() -> [String] {
            disabledTypeIdentifiers
        }
    }

    private actor SuspensionGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor ControlledSweep {
        private let events: LifecycleEvents
        private let gate = SuspensionGate()
        private var runs = 0
        private var blocked = false
        private var effects = 0

        init(events: LifecycleEvents) {
            self.events = events
        }

        func run() async {
            runs += 1
            await events.append(.sweep)
            guard runs > 1 else { return }
            blocked = true
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                Task { await self.gate.open() }
            }
            guard !Task.isCancelled else { return }
            effects += 1
        }

        func waitUntilBlocked() async {
            while !blocked {
                await Task.yield()
            }
        }

        func release() async {
            await gate.open()
        }

        func sideEffectCount() -> Int {
            effects
        }
    }

#endif
