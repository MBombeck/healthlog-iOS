// 13-03 (A1 / H-A1a) — the dashboard's foreground revalidation must be able to
// run at all.
//
// Since 09-06 `dashboardSummary` is the SECOND step of a sequential leg, behind
// the COMPLETE HealthKit sweep (`ForegroundPassPlan.shape`, leg
// `[.healthKitStats, .dashboardSummary]`). The pass is bounded at 250 ms + 50 ms
// (`ForegroundCoordinator.Budget.standard`), and a sweep that does real work
// does not fit in that. `ForegroundSession.isCurrent` folds in
// `!Task.isCancelled`, so once the deadline cancels the leg the next step's
// guard records `.skipped` — the summary step is starved on essentially every
// foreground outside the sweep's own 10 s throttle window.
//
// The irony is the mechanism: the ordering exists so the summary reads the
// totals the sweep just POSTed, and its effect is that the summary only ever
// runs on the passes where the sweep did nothing.
//
// The plan built here is walked out of `ForegroundPassPlan.shape` itself, so it
// measures the production ordering rather than a hand-written copy of it.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Foreground pass ordering (13-03)", .serialized)
    struct ForegroundPassOrderingTests {
        /// Walks the production shape, substituting spy steps. Every member of
        /// every leg is admitted — the gates are `ForegroundPassPlan.Builder`'s
        /// business, the ordering is `shape`'s, and only the ordering is under
        /// test here.
        private func planFromProductionShape(
            spy: Phase09ForegroundSpy,
            work: @escaping @Sendable (ForegroundMember, ForegroundSession) async throws -> Void
        ) -> ForegroundPlan {
            ForegroundPlan(legs: ForegroundPassPlan.shape.map { members in
                ForegroundLeg(members.map { member in
                    spy.step(member) { session in try await work(member, session) }
                })
            })
        }

        // MARK: - 4) the summary must outrun the sweep

        @Test("Der Dashboard-Schritt läuft auch, wenn der HealthKit-Sweep die Frist reißt")
        func dashboardSummaryOutrunsTheSweep() async {
            let spy = Phase09ForegroundSpy()
            let clock = Phase09ForegroundClock()
            let coordinator = ForegroundCoordinator(clock: clock)
            let sweep = Phase09Gate()

            let plan = planFromProductionShape(spy: spy) { member, _ in
                // Only the HealthKit sweep is slow. Everything else returns at
                // once, so nothing but the sweep can be blamed for the deadline.
                if member == .healthKitStats { await sweep.wait() }
            }
            let pass = coordinator.begin(plan)

            // The sweep is parked. Let the deadline fire on it.
            #expect(await phase09Settle { spy.hasStarted(.healthKitStats) })
            #expect(await phase09Settle {
                clock.requested.contains(ForegroundCoordinator.Budget.standard.deadline)
            })
            clock.fire(ForegroundCoordinator.Budget.standard.deadline)
            clock.fire(ForegroundCoordinator.Budget.standard.drainAllowance)
            sweep.open()
            let report = await pass.value

            // Two halves of one claim, counted together so the RED carries
            // exactly one marker: what this pass did, and what the production
            // shape says every pass will do.
            let starved = spy.hasStarted(.dashboardSummary) ? 0 : 1
            let orderedBehindTheSweep =
                ForegroundPassPlan.ordersStrictly(.dashboardSummary, after: .healthKitStats) ? 1 : 0

            #expect(
                starved + orderedBehindTheSweep == 0,
                "EXPECTED_RED: the summary step is starved behind the HealthKit sweep"
            )
            #expect(report?.count(.dashboardSummary, .skipped) == 0)
            // 09-06's invariants, unchanged: one member per pass, nothing left
            // running when the pass returned.
            #expect(ForegroundPassPlan.legCount(mentioning: .dashboardSummary) == 1)
            #expect(ForegroundPassPlan.legCount(mentioning: .healthKitStats) == 1)
            #expect(report?.stillInFlight.isEmpty == true)
        }

        // MARK: - 5) the invariant witness (green before and after)

        /// A retired generation publishes nothing. This is 09-06/09-07's fence,
        /// and this plan moves ordering, not philosophy — so this case must be
        /// green on both sides of the change, which is what makes it a witness
        /// rather than a test.
        @Test("Eine überholte Generation veröffentlicht null")
        func aRetiredGenerationPublishesNothing() async {
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let published = ForegroundPublicationCounter()
            let parked = Phase09Gate()

            let first = coordinator.begin(ForegroundPlan(legs: [ForegroundLeg([
                ForegroundStep(.dashboardSummary) { session in
                    await parked.wait()
                    await session.publish { published.increment() }
                }
            ])]))
            #expect(await phase09Settle { parked.arrivalCount == 1 })

            // A newer pass supersedes the parked one before it can publish.
            let second = coordinator.begin(ForegroundPlan(legs: [ForegroundLeg([
                ForegroundStep(.dashboardSummary) { _ in }
            ])]))
            parked.open()
            _ = await first.value
            _ = await second.value

            #expect(published.value == 0)
        }
    }

    /// Locked counter for the publication witness: `ForegroundSession.publish`
    /// takes a `@Sendable` body, so the count cannot live in a captured `var`.
    private final class ForegroundPublicationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

#endif
