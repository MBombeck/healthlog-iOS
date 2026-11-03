// Diese Suite testet App-Target-Symbole (`BackgroundSyncCoordinator`,
// `BGTaskWake`), die in der SPM-Library nicht enthalten sind.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **R-A1 (1.4) — the BGTask expiration handler goes in first.**
    ///
    /// Up to 1.3 both BGTask cores recorded the wake (a main-actor hop),
    /// re-submitted the next request and started their work before they set
    /// the expiration handler. An expiry in that window found no handler and
    /// the task was never completed. The spy below expires the task the moment
    /// a handler is installed, which is the earliest an expiry can be seen.
    @Suite("BGTask wake — expiration handler first (R-A1)")
    struct BGTaskWakeTests {
        @Test("an expiry during the launch hops completes the processing task once and starts no pass")
        func processingExpiryBeforeWorkStartsNothing() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let spy = ExpiringOnInstallSpy()
            let passEntered = AsyncFlag()
            coordinator.attachHealthSyncRoute { _, _ in
                passEntered.set()
                return []
            }

            await coordinator.runBGSync(on: spy)

            #expect(spy.completions == [false])
            #expect(!passEntered.value, "an expired grant starts no work")
        }

        @Test("an expiry during the launch hops completes the refresh task once and starts no pass")
        func refreshExpiryBeforeWorkStartsNothing() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let spy = ExpiringOnInstallSpy()
            let passEntered = AsyncFlag()
            coordinator.attachHealthSyncRoute { _, _ in
                passEntered.set()
                return []
            }

            await coordinator.runBGRefresh(on: spy)

            #expect(spy.completions == [false])
            #expect(!passEntered.value)
        }

        @Test("the handler is installed when the wake is created, before any work")
        func handlerIsInstalledAtCreation() async {
            let spy = BGTaskCompletionSpy()
            let wake = BGTaskWake(task: spy) {}
            #expect(spy.expirationHandlerInstalled)

            spy.fireExpiration()
            let ran = AsyncFlag()
            await wake.run { _ in ran.set() }
            wake.finish()

            #expect(!ran.value)
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
        }

        @Test("a normal wake runs its work and completes once with success")
        func normalWakeCompletesOnce() async {
            let spy = BGTaskCompletionSpy()
            let wake = BGTaskWake(task: spy) {}
            let ran = AsyncFlag()
            let sawExpiry = AsyncBox()
            await wake.run { expiration in
                sawExpiry.set(expiration.value)
                ran.set()
            }
            wake.finish()

            #expect(ran.value)
            #expect(sawExpiry.value == false)
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("an expiry during the work cancels it and completes once with failure")
        func expiryDuringWorkCancels() async {
            let spy = BGTaskCompletionSpy()
            let expiredNote = AsyncFlag()
            let wake = BGTaskWake(task: spy) { expiredNote.set() }
            let started = AsyncFlag()
            let release = AsyncFlag()
            let sawCancellation = AsyncBox()

            let run = Task {
                await wake.run { _ in
                    started.set()
                    await release.wait()
                    sawCancellation.set(Task.isCancelled)
                }
            }
            await started.wait()
            spy.fireExpiration()
            release.set()
            await run.value
            wake.finish()

            #expect(sawCancellation.value == true)
            #expect(wake.expiration.value)
            #expect(expiredNote.value)
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
        }
    }

    /// A task that iOS expires the moment the app installs its handler.
    final class ExpiringOnInstallSpy: BGTaskCompleting, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Bool] = []

        var completions: [Bool] {
            lock.withLock { results }
        }

        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            handler()
        }

        func setTaskCompleted(success: Bool) {
            lock.withLock { results.append(success) }
        }
    }

#endif
