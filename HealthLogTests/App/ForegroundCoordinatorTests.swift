// This suite drives App-target symbols (`ForegroundCoordinator`,
// `ForegroundPassPlan`, `HLPerfSignpost`) that the SPM library build has no part
// of.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Phase 09 / plan 09-06 — the foreground pass, and the proof that it is one.**
    ///
    /// Everything asserted here is a **count or an ordering**: how many members
    /// started before another finished, how many of them were left in flight when
    /// the pass returned, how many stale publications got through, how many
    /// intervals closed and with which outcome. The `≤ 300 ms p95` foreground
    /// budget (B2) is a duration, is not claimable off a simulator, and is
    /// physical-device evidence for plan 09-09. Not one figure below is a clock
    /// reading — the clock this suite injects records the budget it is asked for
    /// and never spends it.
    ///
    /// Serialized because two cases install the process-global
    /// `HLPerfSignpost.Recorder`, which is a single slot.
    @Suite("ForegroundCoordinatorTests — one bounded, ordered, fenced foreground pass", .serialized)
    struct ForegroundCoordinatorTests {
        // MARK: - Ordering and overlap

        /// The badge reads `MedicationsStore.dueOrMissedCount`. Until this plan
        /// the two were sibling `Task { … }`s and a comment claimed the badge
        /// "runs AFTER the force-load above settles" — which two sibling tasks do
        /// not do. The contract is a happens-before, and it is read off a spy the
        /// members write themselves.
        @Test("medication completes before the badge reads it, while independent members overlap")
        func medicationCompletesBeforeBadgeWhileIndependentWorkOverlaps() async {
            let spy = Phase09ForegroundSpy()
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let medication = Phase09Gate()
            let independent = Phase09Gate()

            let plan = ForegroundPlan(legs: [
                ForegroundLeg([
                    spy.step(.medicationLoad) { _ in await medication.wait() },
                    spy.step(.badgeRefresh) { _ in }
                ]),
                ForegroundLeg([spy.step(.moodRevalidate) { _ in await independent.wait() }]),
                ForegroundLeg([spy.step(.cycleGate) { _ in }]),
                ForegroundLeg([spy.step(.networkRevalidate) { _ in }])
            ])
            let pass = coordinator.begin(plan)

            // Independent work must be able to run to completion while the
            // medication load is still parked. That is the overlap half, and it
            // is settled by the barrier rather than by a deadline.
            let independentWorkFinished = await phase09Settle {
                spy.hasEnded(.cycleGate) && spy.hasEnded(.networkRevalidate)
            }
            #expect(independentWorkFinished, "independent legs must not wait on the medication leg")
            #expect(await phase09Settle { spy.hasStarted(.moodRevalidate) })
            // 22-02 (D-20-EXEC-A) — this was the ONE bare assertion in the
            // neighbourhood: both expectations around it settle through the
            // barrier, this one read the spy directly. Under parallel-test CPU
            // pressure the medication leg's task can still be unscheduled when
            // the independent legs have already finished, and the assertion
            // then fails for a reason that has nothing to do with the contract
            // (which is a happens-before, not a deadline). The mechanism IS the
            // missing barrier; no stronger claim than that is available for a
            // scheduling hazard, and none is made.
            #expect(await phase09Settle { spy.hasStarted(.medicationLoad) })
            let overlapped = spy.maxConcurrent >= 2

            independent.open()
            medication.open()
            let report = await pass.value

            // Two independent halves of one claim, counted together so the RED
            // carries exactly one marker: what the members actually did, and what
            // the production shape says they will do.
            let racingBadgeStarts = spy.starts(of: .badgeRefresh, beforeEndOf: .medicationLoad)
            let shapeOrdersThem = ForegroundPassPlan.ordersStrictly(.badgeRefresh, after: .medicationLoad)
            let orderingViolations = racingBadgeStarts + (shapeOrdersThem ? 0 : 1)

            #expect(overlapped, "independent members must overlap; a serial pass would peak at one")
            #expect(report?.outcome == .completed)
            #expect(spy.endCount(of: .badgeRefresh) == 1, "the badge must still run")
            #expect(
                orderingViolations == 0,
                "EXPECTED_RED: medication did not complete before badge refresh"
            )
        }

        // MARK: - The session fence

        /// A member that finished its `await` is not cancelled — it is late. The
        /// fence is therefore a comparison at publication time, against both the
        /// coordinator's own pass generation and the app-wide authenticated
        /// session lease.
        @Test("a retired generation and a superseded account both refuse a late publication")
        func cancelledOldGenerationCannotPublish() async {
            let published = Phase09Counter()

            // Half one — the pass generation. A newer foreground retires this one
            // while its first step is still parked.
            let spy = Phase09ForegroundSpy()
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let gate = Phase09Gate()
            let pass = coordinator.begin(ForegroundPlan(legs: [ForegroundLeg([
                spy.step(.medicationLoad) { _ in await gate.wait() },
                spy.step(.badgeRefresh) { session in
                    await session.publish { published.record("generation") }
                }
            ])]))
            #expect(await phase09Settle { spy.hasStarted(.medicationLoad) })
            coordinator.retire()
            gate.open()
            _ = await pass.value

            // Half two — the account. The registry admits a different owner while
            // the pass is parked, so the lease this pass captured is no longer
            // current even though the coordinator's own generation is.
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = registry.activate(ownerID: "phase09-owner-a")
            let accountSpy = Phase09ForegroundSpy()
            let accountCoordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let accountGate = Phase09Gate()
            let accountPass = accountCoordinator.begin(
                ForegroundPlan(legs: [ForegroundLeg([
                    accountSpy.step(.medicationLoad) { _ in await accountGate.wait() },
                    accountSpy.step(.badgeRefresh) { session in
                        await session.publish { published.record("account") }
                    }
                ])]),
                lease: lease
            )
            #expect(await phase09Settle { accountSpy.hasStarted(.medicationLoad) })
            registry.activate(ownerID: "phase09-owner-b")
            accountGate.open()
            _ = await accountPass.value

            // The control: a pass that is still current publishes. Without it,
            // "nothing published" would also be satisfied by a gate that is
            // simply always shut.
            let liveSpy = Phase09ForegroundSpy()
            let liveCoordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            _ = await liveCoordinator.begin(ForegroundPlan(legs: [ForegroundLeg([
                liveSpy.step(.badgeRefresh) { session in
                    await session.publish { published.record("live") }
                }
            ])])).value

            #expect(published.count(of: "live") == 1, "a current session must be able to publish")
            let latePublications = published.count(of: "generation") + published.count(of: "account")
            #expect(
                latePublications == 0,
                "EXPECTED_RED: cancelled foreground generation published late state"
            )
        }

        // MARK: - The bound

        /// The pass is bounded by construction at `deadline + drainAllowance`,
        /// which is 250 ms + 50 ms — B2's 300 ms, split into "stop asking" and
        /// "finish stopping". Both halves are asserted as the budget the
        /// coordinator *requested*, never as time this test spent.
        @Test("the deadline cancels every unfinished member and the drain stays inside its allowance")
        func deadlineCancelsAndDrainsWithinBudget() async {
            var violations = 0

            // Half one — the deadline.
            let spy = Phase09ForegroundSpy()
            let clock = Phase09ForegroundClock()
            let coordinator = ForegroundCoordinator(clock: clock)
            let slow = Phase09Gate()
            let pass = coordinator.begin(ForegroundPlan(legs: [
                ForegroundLeg([spy.step(.medicationLoad) { _ in await slow.wait() }]),
                ForegroundLeg([spy.step(.outboxDrain) { _ in await slow.wait() }]),
                ForegroundLeg([spy.step(.cycleGate) { _ in }])
            ]))
            #expect(await phase09Settle { spy.hasStarted(.medicationLoad) && spy.hasStarted(.outboxDrain) })
            let deadlineRequested = await phase09Settle {
                clock.requested.contains(ForegroundCoordinator.Budget.standard.deadline)
            }
            clock.fire(ForegroundCoordinator.Budget.standard.deadline)
            // Both members end because they were cancelled, not because the test
            // let them go — the barrier is still shut at this point.
            let cancelledWithoutRelease = await phase09Settle {
                spy.hasEnded(.medicationLoad) && spy.hasEnded(.outboxDrain)
            }
            // Released unconditionally so a shape with no deadline fails rather
            // than hangs.
            slow.open()
            let report = await pass.value

            if !deadlineRequested { violations += 1 }
            if !cancelledWithoutRelease { violations += 1 }
            if clock.requested != [
                ForegroundCoordinator.Budget.standard.deadline,
                ForegroundCoordinator.Budget.standard.drainAllowance
            ] { violations += 1 }
            if report?.outcome != .deadlineExpired { violations += 1 }
            if report?.drainOverran != false { violations += 1 }
            violations += report?.stillInFlight.count ?? 1

            // Half two — owner cancellation. A scene change or a superseding pass
            // must drain the children rather than detach them.
            let ownerSpy = Phase09ForegroundSpy()
            let ownerCoordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let ownerGate = Phase09Gate()
            let ownerPass = ownerCoordinator.begin(ForegroundPlan(legs: [
                ForegroundLeg([ownerSpy.step(.medicationLoad) { _ in await ownerGate.wait() }]),
                ForegroundLeg([ownerSpy.step(.insightsWarm) { _ in await ownerGate.wait() }])
            ]))
            #expect(await phase09Settle {
                ownerSpy.hasStarted(.medicationLoad) && ownerSpy.hasStarted(.insightsWarm)
            })
            ownerCoordinator.retire()
            let drainedWithoutRelease = await phase09Settle {
                ownerSpy.hasEnded(.medicationLoad) && ownerSpy.hasEnded(.insightsWarm)
            }
            ownerGate.open()
            let ownerReport = await ownerPass.value

            if !drainedWithoutRelease { violations += 1 }
            if ownerReport?.outcome != .cancelled { violations += 1 }
            violations += ownerReport?.stillInFlight.count ?? 1

            #expect(!Task.isCancelled, "the test's own task must still be alive")
            #expect(
                violations == 0,
                "EXPECTED_RED: foreground pass exceeded deadline and drain allowance"
            )
        }

        // MARK: - Contracts the pre-09-06 fan-out already satisfied

        /// A member that appears in two legs runs twice per foreground. Asserted
        /// on the running pass *and* on the production shape, because the second
        /// is where a future member gets added.
        @Test("every member starts exactly once per pass, and appears in exactly one production leg")
        func everyMemberRunsExactlyOncePerPass() async {
            let spy = Phase09ForegroundSpy()
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let plan = ForegroundPlan(legs: [
                ForegroundLeg([spy.step(.medicationLoad) { _ in }, spy.step(.badgeRefresh) { _ in }]),
                ForegroundLeg([spy.step(.healthKitStats) { _ in }, spy.step(.dashboardSummary) { _ in }]),
                ForegroundLeg([spy.step(.insightsWarm) { _ in }])
            ])
            let report = await coordinator.begin(plan).value

            for member in plan.members {
                #expect(spy.startCount(of: member) == 1, "\(member.rawValue) started more than once")
                #expect(spy.endCount(of: member) == 1, "\(member.rawValue) ended more than once")
            }
            #expect(spy.events.filter { $0.phase == .started }.count == plan.members.count)
            #expect(report?.members(in: .started).count == plan.members.count)

            for member in ForegroundMember.allCases {
                #expect(
                    ForegroundPassPlan.legCount(mentioning: member) == 1,
                    "\(member.rawValue) must appear in exactly one production leg"
                )
            }
        }

        /// `foreground.pass` is the interval an operator reads a truncated pass
        /// off. It has to close on every exit, and it has to close *saying which
        /// exit* — an unclosed interval poisons the p95 of everything around it,
        /// and a `completed` interval on a pass that was cut short is worse than
        /// no interval at all.
        @Test("the foreground interval closes once per pass, naming the exit it took")
        func theForegroundIntervalClosesOnEveryExitPath() async {
            let recorder = HLPerfSignpost.Recorder()
            HLPerfSignpost.installRecorder(recorder)
            defer { HLPerfSignpost.installRecorder(nil) }

            // Success.
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())
            _ = await coordinator.begin(ForegroundPlan(legs: [
                ForegroundLeg([ForegroundStep(.cycleGate) { _ in }])
            ])).value

            // A member that throws.
            struct ForegroundMemberFailure: Error {}
            let failing = ForegroundCoordinator(clock: Phase09ForegroundClock())
            _ = await failing.begin(ForegroundPlan(legs: [
                ForegroundLeg([ForegroundStep(.moodReminder) { _ in throw ForegroundMemberFailure() }])
            ])).value

            // Owner cancellation.
            let spy = Phase09ForegroundSpy()
            let cancelled = ForegroundCoordinator(clock: Phase09ForegroundClock())
            let gate = Phase09Gate()
            let pass = cancelled.begin(ForegroundPlan(legs: [
                ForegroundLeg([spy.step(.outboxDrain) { _ in await gate.wait() }])
            ]))
            #expect(await phase09Settle { spy.hasStarted(.outboxDrain) })
            cancelled.retire()
            gate.open()
            _ = await pass.value

            let closed = recorder.records(for: .foregroundPass)
            #expect(closed.count == 3, "one closed interval per pass, no more and no fewer")
            #expect(closed.map(\.outcome) == [.completed, .failed, .cancelled])
        }

        /// **Every route to the thing being ordered, enumerated.**
        ///
        /// 09-05's finding, applied before this plan's ordering claim is made:
        /// `OutboxReplayService.runOnce` had three callers and only one of them
        /// was the one the ordering claim was about. The badge has four production
        /// routes — the ordered foreground step, the `onIntakesDidChange`
        /// coalescer that the medication load itself drives, the `willPresent`
        /// delegate recompute, and the logout purge — and only the first is
        /// ordered by this plan. The other three are named here so a future
        /// reader of "medication before badge" knows exactly what it does and does
        /// not cover.
        ///
        /// Verdicts are bound to a `Bool` before the `#expect`: a `#expect` on a
        /// `contains` over source pastes whole production files into the failure
        /// log, and a production-source paste inside a RED log is how a
        /// behavioural gate comes to look like a compile failure to the regex that
        /// reads it.
        @Test("the badge has exactly four production routes, and this plan orders one of them")
        func everyRouteToTheBadgeIsEnumerated() throws {
            let routes = try FirstFrameSignalTests.productionFiles(naming: "refreshBadge")
            let alwaysPresent = [
                "HealthLog/Services/NotificationService+Badge.swift",
                "HealthLog/Services/NotificationService+Handler.swift",
                "HealthLog/Stores/AppContainer+Notifications.swift"
            ]
            let routeCountIsFour = routes.count == 4
            let theThreeUnorderedRoutesAreIntact = alwaysPresent.allSatisfy { routes.contains($0) }
            // The fourth is the foreground pass itself, wherever it currently
            // lives — `RootView` before Task 2, the pass plan after it.
            let foregroundRoute = routes.filter { !alwaysPresent.contains($0) }
            let exactlyOneForegroundRoute = foregroundRoute.count == 1

            #expect(routeCountIsFour, "the badge route inventory moved: \(routes.count) files name refreshBadge")
            #expect(theThreeUnorderedRoutesAreIntact)
            #expect(exactlyOneForegroundRoute)
        }
    }

#endif // !SWIFT_PACKAGE
