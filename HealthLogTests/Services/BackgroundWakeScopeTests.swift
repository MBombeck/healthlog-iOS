#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// Background wakes without a HealthKit setup: a person who uses HealthLog
    /// for medications alone gets reminders, outbox replay and the medication
    /// reconcile (widgets, watch, Live Activity), and no HealthKit pass.
    @Suite("Background wake scope")
    struct BackgroundWakeScopeTests {
        // MARK: - Rule

        @Test("HealthKit set up → full, signed in without it → without HealthKit, neither → idle")
        func resolveTable() {
            #expect(BackgroundWakeScope.resolve(signedIn: true, healthKitAvailable: true, healthKitRequested: true) == .full)
            #expect(BackgroundWakeScope.resolve(signedIn: false, healthKitAvailable: true, healthKitRequested: true) == .full)
            #expect(BackgroundWakeScope.resolve(signedIn: true, healthKitAvailable: true, healthKitRequested: false) == .withoutHealthKit)
            #expect(BackgroundWakeScope.resolve(signedIn: true, healthKitAvailable: false, healthKitRequested: true) == .withoutHealthKit)
            #expect(BackgroundWakeScope.resolve(signedIn: false, healthKitAvailable: true, healthKitRequested: false) == .idle)
            #expect(BackgroundWakeScope.resolve(signedIn: false, healthKitAvailable: false, healthKitRequested: false) == .idle)
        }

        @Test("no token read, but the session in memory is not signed out → the wake chain continues")
        func unreadableKeychainKeepsChain() {
            #expect(BackgroundWakeScope.resolve(
                signedIn: false,
                healthKitAvailable: false,
                healthKitRequested: false,
                sessionSaysSignedOut: false
            ) == .withoutHealthKit)
            #expect(BackgroundWakeScope.resolve(
                signedIn: false,
                healthKitAvailable: false,
                healthKitRequested: false,
                sessionSaysSignedOut: true
            ) == .idle)
        }

        @Test("only the idle scope stops asking for the next wake")
        func reschedulesUnlessIdle() {
            #expect(BackgroundWakeScope.full.reschedules)
            #expect(BackgroundWakeScope.withoutHealthKit.reschedules)
            #expect(!BackgroundWakeScope.idle.reschedules)
            #expect(BackgroundWakeScope.full.runsHealthKitPass)
            #expect(!BackgroundWakeScope.withoutHealthKit.runsHealthKitPass)
        }

        // MARK: - Processing wake

        @Test("processing wake without HealthKit runs every non-HealthKit hook and the outbox, never the HealthKit pass")
        func processingWithoutHealthKit() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .withoutHealthKit }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            let recorded = await calls.calls
            #expect(!recorded.contains("healthKitPass"))
            #expect(recorded == ["topUp", "cacheSweep", "medReconcile", "liveActivity", "mood", "outbox"])
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("processing wake with HealthKit keeps the pass and leaves the outbox to it")
        func processingFull() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .full }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            let recorded = await calls.calls
            #expect(recorded.contains("healthKitPass"))
            // The orchestrated pass plans the drain itself; a second drain here
            // would replay the same rows twice.
            #expect(!recorded.contains("outbox"))
            #expect(spy.completionCount == 1)
        }

        @Test("idle processing wake touches nothing and completes once without failure")
        func processingIdle() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .idle }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            #expect(await calls.calls.isEmpty)
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        // MARK: - AppRefresh wake

        @Test("refresh wake without HealthKit carries top-up, outbox, medication reconcile and Live Activity")
        func refreshWithoutHealthKit() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .withoutHealthKit }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGRefresh(on: spy)

            #expect(await calls.calls == ["topUp", "outbox", "medReconcile", "liveActivity"])
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("#189 (5): refresh wake with HealthKit reconciles medications before the pass")
        func refreshFull() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .full }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGRefresh(on: spy)

            #expect(await calls.calls == ["topUp", "medReconcile", "liveActivity", "healthKitPass"])
        }

        @Test("idle refresh wake does nothing")
        func refreshIdle() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let calls = WakeCallRecorder()
            Self.attachAll(to: coordinator, calls: calls)
            coordinator.attachWakeScopeProvider { .idle }
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGRefresh(on: spy)

            #expect(await calls.calls.isEmpty)
            #expect(spy.completionCount == 1)
        }

        // MARK: - Helpers

        private static func attachAll(to coordinator: BackgroundSyncCoordinator, calls: WakeCallRecorder) {
            coordinator.attachReminderTopUpHook { await calls.note("topUp") }
            coordinator.attachHealthSyncRoute { _, _ in
                await calls.note("healthKitPass")
                return []
            }
            coordinator.attachCacheSweepHook { await calls.note("cacheSweep") }
            coordinator.attachMedicationReconcileHook { await calls.note("medReconcile") }
            coordinator.attachLiveActivityReconcileHook { await calls.note("liveActivity") }
            coordinator.attachMoodReconcileHook { await calls.note("mood") }
            coordinator.attachOutboxDrainHook { await calls.note("outbox") }
        }
    }

    actor WakeCallRecorder {
        private(set) var calls: [String] = []

        func note(_ call: String) {
            calls.append(call)
        }
    }

#endif
