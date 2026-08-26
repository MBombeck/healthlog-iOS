import Foundation
@testable import HealthLog
import Synchronization
import Testing

#if canImport(HealthKit)
    @Suite("HealthKit workout detail — cancellable HR query")
    struct HealthKitWorkoutDetailServiceTests {
        private final class Driver: HealthKitHeartRateQueryDriving, Sendable {
            private struct State {
                var startCount = 0
                var stopCount = 0
                var callback: (@Sendable (HealthKitHeartRateQueryResult) -> Void)?
            }

            private let state = Mutex(State())

            func start(
                id _: UUID,
                from _: Date,
                to _: Date,
                limit _: Int,
                completion: @escaping @Sendable (HealthKitHeartRateQueryResult) -> Void
            ) {
                state.withLock {
                    $0.startCount += 1
                    $0.callback = completion
                }
            }

            func stop(id _: UUID) {
                state.withLock { $0.stopCount += 1 }
            }

            var starts: Int {
                state.withLock { $0.startCount }
            }

            var stops: Int {
                state.withLock { $0.stopCount }
            }

            func complete(_ result: HealthKitHeartRateQueryResult) {
                let callback = state.withLock { $0.callback }
                callback?(result)
            }
        }

        private actor Gate {
            private var arrived = false
            private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                arrived = true
                let waiters = arrivalWaiters
                arrivalWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func waitUntilArrived() async {
                guard !arrived else { return }
                await withCheckedContinuation { arrivalWaiters.append($0) }
            }

            func release() {
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        private static let start = Date(timeIntervalSince1970: 1_700_000_000)

        @Test("cancellation before registration never starts or stops a query")
        func cancellationBeforeRegistration() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let gate = Gate()
            let task = Task {
                await gate.wait()
                return await service.heartRateSeries(from: Self.start, to: Self.start.addingTimeInterval(60))
            }
            await gate.waitUntilArrived()
            task.cancel()
            await gate.release()

            #expect(await task.value.isEmpty)
            #expect(driver.starts == 0)
            #expect(driver.stops == 0)
        }

        @Test("active cancellation stops exactly once and ignores a callback after stop")
        func callbackAfterStop() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let task = Task {
                await service.heartRateSeries(from: Self.start, to: Self.start.addingTimeInterval(60))
            }
            while driver.starts == 0 {
                await Task.yield()
            }

            task.cancel()
            #expect(await task.value.isEmpty)
            #expect(driver.stops == 1)

            driver.complete(.samples([WorkoutHRSample(timestamp: Self.start, bpm: 130)]))
            await Task.yield()
            #expect(driver.stops == 1)
        }

        @Test("sync outcome preserves a redacted query failure")
        func typedFailure() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let task = Task {
                await service.heartRateSeriesOutcome(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while driver.starts == 0 {
                await Task.yield()
            }

            driver.complete(.failed)

            #expect(await task.value == .failed(.query))
        }

        @Test("sync cancellation stays typed and stops the live query once")
        func typedCancellation() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let task = Task {
                await service.heartRateSeriesOutcome(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while driver.starts == 0 {
                await Task.yield()
            }

            task.cancel()

            #expect(await task.value == .cancelled)
            #expect(driver.stops == 1)
            driver.complete(.samples([WorkoutHRSample(timestamp: Self.start, bpm: 130)]))
            await Task.yield()
            #expect(driver.stops == 1)
        }

        @Test("successful empty and ordered samples remain distinct sync outcomes")
        func typedSamples() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let emptyTask = Task {
                await service.heartRateSeriesOutcome(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while driver.starts == 0 {
                await Task.yield()
            }
            driver.complete(.samples([]))
            #expect(await emptyTask.value == .samples([]))

            let samples = [
                WorkoutHRSample(timestamp: Self.start, bpm: 120),
                WorkoutHRSample(timestamp: Self.start.addingTimeInterval(5), bpm: 125)
            ]
            let samplesTask = Task {
                await service.heartRateSeriesOutcome(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while driver.starts < 2 {
                await Task.yield()
            }
            driver.complete(.samples(samples))
            #expect(await samplesTask.value == .samples(samples))
        }

        @Test("UI adapter remains best effort for every non-success boundary")
        func uiAdapterRemainsBestEffort() async {
            let unavailable = HealthKitWorkoutDetailService(
                queryDriver: Driver(),
                healthDataIsAvailable: { false }
            )
            #expect(await unavailable.heartRateSeries(from: Self.start, to: Self.start.addingTimeInterval(60)).isEmpty)
            #expect(await unavailable.heartRateSeries(from: Self.start, to: Self.start).isEmpty)

            let failureDriver = Driver()
            let failureService = HealthKitWorkoutDetailService(queryDriver: failureDriver)
            let failed = Task {
                await failureService.heartRateSeries(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while failureDriver.starts == 0 {
                await Task.yield()
            }
            failureDriver.complete(.failed)
            #expect(await failed.value.isEmpty)

            let emptyDriver = Driver()
            let emptyService = HealthKitWorkoutDetailService(queryDriver: emptyDriver)
            let empty = Task {
                await emptyService.heartRateSeries(
                    from: Self.start,
                    to: Self.start.addingTimeInterval(60)
                )
            }
            while emptyDriver.starts == 0 {
                await Task.yield()
            }
            emptyDriver.complete(.samples([]))
            #expect(await empty.value.isEmpty)
        }

        @Test("callback owns completion before a later cancellation")
        func callbackBeforeCancellation() async {
            let driver = Driver()
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let task = Task {
                await service.heartRateSeries(from: Self.start, to: Self.start.addingTimeInterval(60))
            }
            while driver.starts == 0 {
                await Task.yield()
            }
            let expected = [WorkoutHRSample(timestamp: Self.start, bpm: 127)]
            driver.complete(.samples(expected))

            #expect(await task.value == expected)
            task.cancel()
            await Task.yield()
            #expect(driver.stops == 0)
        }
    }
#endif
