// 14-05 (J3 foreground half, D-09-06-A) — a truncated pass stops burning the window.
//
// Since build 266 the foreground pass is bounded at 250 ms + 50 ms (09-06). The
// coarse A7-M1 throttle that admits its six cheap members is read — and STAMPED
// — when the plan is built (`ForegroundPassPlan.make` →
// `AppContainer.shouldRunForegroundCheapMembers()` →
// `ForegroundRefreshThrottle.shouldRun`), which is before a single member has
// run. A pass that is then cancelled or truncated therefore spends an 8-second
// window on work it never did, and the next foreground inside that window is
// refused the members it was owed. That is D-09-06-A, and it is the foreground
// half of the operator's J3 ("Gefühl, dass eher weniger Daten ankommen").
//
// The second half is the field question this leaves unanswerable: "did the
// dashboard refresh run?" The pass ledger knows — every member that did not run
// is recorded `.skipped` — and nothing reads it.
//
// Everything asserted here is a count, an ordering or a closed-set word. The
// injected clock records the budget it is asked for and never spends it, which
// is the 09-06 discipline and stays it.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Foreground pass window accounting (14-05)", .serialized)
    struct ForegroundPassWindowTests {
        // MARK: - 1) a pass that did nothing did not spend the window

        /// Two foregrounds inside eight seconds. The first is cancelled before
        /// any member can run — the shape a second foreground, a scene change or
        /// a sign-out produces — so its throttled members never ran. The second
        /// must therefore get them.
        @Test("Ein abgebrochener Pass verbrennt das Fenster nicht")
        @MainActor
        func truncatedPassDoesNotBurnTheWindow() async {
            let container = Self.makeContainer()
            let coordinator = ForegroundCoordinator(clock: Phase09ForegroundClock())

            // Foreground 1 — the production builder reads the coarse gate, and
            // stamps it in the same breath.
            let first = Self.makePlan(container)
            #expect(
                first.members.contains(.cycleGate),
                "the first foreground of a window must admit the throttled members"
            )

            // ... and the pass is cancelled before a member can run. Cancellation
            // reaches the legs' own session check, so every step records `.skipped`.
            let pass = coordinator.begin(first)
            pass.cancel()
            let report = await pass.value
            #expect(
                report?.members(in: .finished).isEmpty ?? true,
                "this pass must have run nothing at all"
            )

            // Foreground 2, inside the same eight seconds.
            let second = Self.makePlan(container)
            #expect(
                second.members.contains(.cycleGate),
                "EXPECTED_RED: a pass that did nothing still consumes the 8 s window"
            )
        }

        // MARK: - 2) which members did not run must be readable

        /// A pass truncated by its own deadline leaves a complete ledger: the
        /// member that was running, and every member behind it that never
        /// started. Nothing reads it, so a field report of "the dashboard did not
        /// refresh" is answerable only from vibes.
        @Test("Ein abgebrochener Pass hinterlässt, wer nicht lief")
        func skippedMembersAreReadable() async {
            let observed = PassDiagnosticLog()
            StoreEffectDiagnostics.sink = { line in observed.append(line) }
            defer { StoreEffectDiagnostics.sink = nil }

            let spy = Phase09ForegroundSpy()
            let clock = Phase09ForegroundClock()
            let coordinator = ForegroundCoordinator(clock: clock)
            // D-14-07-C. The slow member returns when the PASS IS CANCELLED,
            // not when the test opens a gate. That is the whole scenario — a
            // member still running when the deadline expires — and stating it
            // this way makes it deterministic.
            //
            // What it replaces: a `Phase09Gate` that the test opened in the
            // same scheduling turn as `clock.fire(...)`. Firing the clock only
            // resumes the deadline child's parked sleep; the truncation is
            // delivered a few hops later, when the group reads
            // `.deadlineExpired` and calls `cancelAll()`. Releasing the blocked
            // member in that same turn races those hops, and if the member wins
            // the leg advances to `.badgeRefresh` and the skipped ledger is
            // legitimately empty. Measured at plan 14-07 on one tree and one
            // selector: red in 2 of 8 observations, red and green both under
            // whole-target load AND in isolation.
            //
            // Nothing about what is asserted changes; the fixture stops racing
            // the mechanism it is measuring. The wall-clock bound only exists
            // so a genuine failure to cancel is a failure rather than a hang.
            let pass = coordinator.begin(ForegroundPlan(legs: [
                ForegroundLeg([
                    spy.step(.medicationLoad) { _ in
                        let bound = ContinuousClock.now + .seconds(5)
                        while !Task.isCancelled, ContinuousClock.now < bound {
                            await Task.yield()
                        }
                    },
                    spy.step(.badgeRefresh) { _ in },
                    spy.step(.cycleGate) { _ in }
                ])
            ]))
            #expect(await phase09Settle { spy.hasStarted(.medicationLoad) })
            clock.fire(ForegroundCoordinator.Budget.standard.deadline)
            let report = await pass.value

            // The ledger has the fact.
            #expect(report?.members(in: .skipped).contains(.badgeRefresh) == true)
            #expect(report?.members(in: .skipped).contains(.cycleGate) == true)
            // Something must say it out loud, in the diagnostics vocabulary that
            // already exists — closed-set words, no identifiers, no payloads.
            #expect(
                observed.lines.contains { $0.hasPrefix("foreground-pass ") && $0.contains("skipped=") },
                "EXPECTED_RED: which members did not run is not recorded anywhere readable"
            )
        }

        // MARK: - 3) the throttle still throttles (control)

        /// A completed pass must stamp the window exactly as it does today. Only
        /// the lie is removed from the stamp, never the throttle.
        @Test("Der Throttle drosselt weiterhin")
        func aCompletedPassStillThrottlesTheNextForeground() {
            var throttle = ForegroundRefreshThrottle(window: 8)
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            // `shouldRun` is `mutating`, and `#expect` evaluates its argument
            // inside a closure that cannot mutate the capture — so each read is
            // taken first and asserted after.
            let first = throttle.shouldRun(now: t0)
            let inside = throttle.shouldRun(now: t0.addingTimeInterval(2))
            let afterWindow = throttle.shouldRun(now: t0.addingTimeInterval(9))
            let forced = throttle.shouldRun(force: true, now: t0.addingTimeInterval(9))
            #expect(first, "the first foreground of a window runs")
            #expect(inside == false, "a second foreground inside the window is coalesced away")
            #expect(afterWindow, "the window expires")
            #expect(forced, "an explicit refresh always runs")
        }

        // MARK: - 4) the 09-06 invariants are untouched (control)

        /// One owner, a bounded pass asking the clock for exactly `[250 ms,
        /// 50 ms]`, and a retired generation that publishes nothing.
        @Test("Budget und Fence bleiben, wie 09-06 sie gesetzt hat")
        func theBudgetAndTheFenceAreUnchanged() async {
            let clock = Phase09ForegroundClock()
            let coordinator = ForegroundCoordinator(clock: clock)
            let published = Phase09Counter()
            let slow = Phase09Gate()
            let pass = coordinator.begin(ForegroundPlan(legs: [
                ForegroundLeg([ForegroundStep(.medicationLoad) { session in
                    await slow.wait()
                    await session.publish { published.record("late") }
                }])
            ]))
            _ = await phase09Settle { clock.requested.contains(ForegroundCoordinator.Budget.standard.deadline) }
            coordinator.retire()
            slow.open()
            let report = await pass.value

            #expect(published.count(of: "late") == 0, "a retired generation publishes nothing")
            #expect(report?.outcome == .cancelled)
            #expect(report?.stillInFlight.isEmpty ?? false, "no child may outlive the pass")
            #expect(
                clock.requested == [ForegroundCoordinator.Budget.standard.deadline],
                "the pass asks for its deadline and nothing else while it is cancelled"
            )
            #expect(ForegroundCoordinator.Budget.standard.deadline == .milliseconds(250))
            #expect(ForegroundCoordinator.Budget.standard.drainAllowance == .milliseconds(50))
        }

        // MARK: - Harness

        @MainActor
        private static func makePlan(_ container: AppContainer) -> ForegroundPlan {
            ForegroundPassPlan.make(
                container: container,
                authStore: container.authStore,
                settings: container.settingsStore,
                hkReadiness: container.hkReadinessStore
            )
        }

        @MainActor
        private static func makeContainer() -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }
    }

    /// Collects the diagnostic lines a pass emits.
    private final class PassDiagnosticLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(line)
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

#endif
