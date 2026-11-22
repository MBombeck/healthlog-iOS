#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(UIKit)
        import UIKit
    #endif

    /// When HealthKit and APNs hear back from a wake: an observer delivery
    /// after its work (or its deadline), a silent push within its budget.
    @Suite("Observer receipt and silent-push budget")
    struct ObserverReceiptAndPushBudgetTests {
        private struct Failure: Error {}

        @Test("an observer error is acknowledged at once and runs no work")
        func errorAcknowledgesAtOnce() async {
            let calls = TriggerLog()
            HealthKitDeliveryReceipt.deliver(
                error: Failure(),
                completionHandler: { calls.append("receipt") },
                work: { calls.append("work") }
            )
            #expect(calls.values == ["receipt"])
            try? await Task.sleep(for: .milliseconds(50))
            #expect(calls.values == ["receipt"])
        }

        @Test("a delivery is acknowledged after its work, not before")
        func receiptFollowsTheWork() async {
            let calls = TriggerLog()
            let gate = Phase09Gate()
            HealthKitDeliveryReceipt.deliver(
                error: nil,
                completionHandler: { calls.append("receipt") },
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                work: {
                    calls.append("work started")
                    await gate.wait()
                    calls.append("work done")
                }
            )
            #expect(await v1Settle { calls.values == ["work started"] })
            gate.open()
            #expect(await v1Settle { calls.count == 3 })
            #expect(calls.values == ["work started", "work done", "receipt"])
        }

        @Test("work that never returns is acknowledged at the deadline, exactly once")
        func stuckWorkIsAcknowledgedAtTheDeadline() async {
            let calls = TriggerLog()
            let deadline = Phase09Gate()
            let stuck = Phase09Gate()
            HealthKitDeliveryReceipt.deliver(
                error: nil,
                completionHandler: { calls.append("receipt") },
                sleep: { _ in await deadline.wait() },
                work: { await stuck.wait() }
            )
            #expect(calls.values.isEmpty)
            deadline.open()
            #expect(await v1Settle { calls.values == ["receipt"] })
            stuck.open()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(calls.values == ["receipt"])
        }

        // MARK: - Silent push

        @Test("the push budget stays under the 30 seconds iOS grants")
        func budgetIsUnderTheSystemLimit() {
            #expect(SilentPushWakeBudget.limit < .seconds(30))
            #expect(SilentPushWakeBudget.limit >= .seconds(20))
        }

        @Test("work inside the budget answers with its own value and never sees the expiry")
        func fastWorkAnswersItself() async {
            let sawExpiry = TriggerLog()
            let value = await SilentPushWakeBudget.run(
                fallback: "fallback",
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                work: { isExpired in
                    if isExpired() { sawExpiry.append("expired") }
                    return "done"
                }
            )
            #expect(value == "done")
            #expect(sawExpiry.values.isEmpty)
        }

        @Test("work past the budget is told, cancelled, and the answer is the fallback")
        func slowWorkIsCutOff() async {
            let log = TriggerLog()
            let started = Phase09Gate()
            // The deadline passes as soon as the work is under way.
            let value = await SilentPushWakeBudget.run(
                fallback: "fallback",
                sleep: { _ in await started.wait() },
                work: { isExpired in
                    started.open()
                    while !isExpired() || !Task.isCancelled {
                        await Task.yield()
                    }
                    log.append("expired")
                    log.append("cancelled")
                    return "late"
                }
            )
            #expect(value == "fallback")
            #expect(await v1Settle { log.count == 2 })
            #expect(log.values == ["expired", "cancelled"])
        }

        @Test("a worker that answers the moment it is cancelled never overtakes the fallback")
        func cancelledWorkerNeverWins() async {
            // Many rounds at once: the cancel wakes the worker on another
            // thread, and it answers at once. The fallback must still win.
            let answers = await withTaskGroup(of: String.self) { group in
                for _ in 0 ..< 200 {
                    group.addTask {
                        await SilentPushWakeBudget.run(
                            fallback: "fallback",
                            sleep: { _ in await Task.yield() },
                            work: { _ in
                                try? await Task.sleep(for: .seconds(3600))
                                return "late"
                            }
                        )
                    }
                }
                var collected: [String] = []
                for await answer in group {
                    collected.append(answer)
                }
                return collected
            }
            #expect(answers.count == 200)
            #expect(answers.allSatisfy { $0 == "fallback" })
        }

        #if canImport(UIKit)
            @Test("a push wake answers iOS with failed when the budget ran out")
            func pushFallbackIsFailed() async {
                let result = await SilentPushWakeBudget.run(
                    fallback: UIBackgroundFetchResult.failed,
                    sleep: { _ in },
                    work: { _ in
                        try? await Task.sleep(for: .seconds(3600))
                        return .newData
                    }
                )
                #expect(result == .failed)
            }
        #endif
    }

#endif
