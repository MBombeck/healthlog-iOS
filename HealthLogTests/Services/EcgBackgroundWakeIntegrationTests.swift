#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Restated by plan 07-09 — same contract, one route.**
    ///
    /// These two tests pinned that a granted BGProcessing wake awaits the ECG
    /// anchored sweep *before* it completes the task, and that an expiring wake
    /// never starts it. Both facts still hold and both still matter; what
    /// changed underneath is that the wake no longer calls a dedicated ECG hook
    /// (which the orchestrated pass duplicated) but enters the one
    /// `.processing` pass, in which `ecgUpload` is one of eleven named
    /// capabilities. The route hook stands in for that pass here, exactly as
    /// `AppContainer.wireBGRefreshCollectionHook` wires it in production.
    @Suite("ECG — BGProcessing integration")
    struct EcgBackgroundWakeIntegrationTests {
        @Test("one granted heavy wake awaits the ECG anchored sweep before completion")
        @MainActor
        func heavyWakeCallsEcgBeforeCompletion() async {
            let order = EcgWakeOrder()
            let ecg = EcgWakeSyncSpy(order: order)
            let background = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            background.attachHealthSyncRoute { trigger, _ in
                #expect(trigger == .processing)
                await ecg.triggerEcgSync()
                return [.ecgUpload]
            }
            let task = EcgWakeTaskSpy(order: order)

            await background.runBGSync(on: task)

            #expect(ecg.callCount == 1)
            #expect(task.completionCount == 1)
            #expect(task.lastSuccess == true)
            #expect(order.events == ["ecg", "complete:true"])
        }

        @Test("an expired heavy wake does not start the downstream ECG sweep")
        @MainActor
        func expirationPreventsEcgSweep() async {
            let order = EcgWakeOrder()
            let ecg = EcgWakeSyncSpy(order: order)
            let background = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let entered = AsyncFlag()
            let release = AsyncFlag()
            // The pass blocks after it has been entered, so the wake is expired
            // strictly between "the route was entered" and "the ECG capability
            // was admitted" — the window the expiration predicate exists for.
            background.attachHealthSyncRoute { _, isExpired in
                entered.set()
                await release.wait()
                guard !isExpired() else { return [] }
                await ecg.triggerEcgSync()
                return [.ecgUpload]
            }
            let task = EcgWakeTaskSpy(order: order)

            let run = Task { await background.runBGSync(on: task) }
            await entered.wait()
            task.fireExpiration()
            release.set()
            await run.value

            #expect(ecg.callCount == 0)
            #expect(task.completionCount == 1)
            #expect(task.lastSuccess == false)
            #expect(order.events == ["complete:false"])
        }
    }

    private final class EcgWakeSyncSpy: EcgSyncing, @unchecked Sendable {
        private let lock = NSLock()
        private let order: EcgWakeOrder
        private var calls = 0

        init(order: EcgWakeOrder) {
            self.order = order
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func triggerEcgSync() async {
            lock.withLock { calls += 1 }
            order.append("ecg")
        }
    }

    private final class EcgWakeTaskSpy: BGTaskCompleting, @unchecked Sendable {
        private let lock = NSLock()
        private let order: EcgWakeOrder
        private var completions = 0
        private var success: Bool?
        private var expirationHandler: (@Sendable () -> Void)?

        init(order: EcgWakeOrder) {
            self.order = order
        }

        var completionCount: Int {
            lock.withLock { completions }
        }

        var lastSuccess: Bool? {
            lock.withLock { success }
        }

        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { expirationHandler = handler }
        }

        func setTaskCompleted(success: Bool) {
            lock.withLock {
                completions += 1
                self.success = success
            }
            order.append("complete:\(success)")
        }

        func fireExpiration() {
            let handler = lock.withLock { expirationHandler }
            handler?()
        }
    }

    private final class EcgWakeOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        var events: [String] {
            lock.withLock { values }
        }

        func append(_ event: String) {
            lock.withLock { values.append(event) }
        }
    }

#endif
