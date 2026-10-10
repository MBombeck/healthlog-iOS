import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import HealthKit

    /// **V1 (1.2)** — each way the app is woken or opened reaches the `stats:`
    /// sweep: the foreground pass (despite its 250 ms deadline), a HealthKit
    /// delivery (before its completion handler), AppRefresh, silent push,
    /// BGProcessing and the manual "Sync all", each with its own wire word.
    @Suite("V1 — every trigger reaches the stats sweep", .serialized)
    struct StatsTriggerWakeTests {
        // MARK: - Wire words and plans

        @Test("Every pass names the wire trigger it stands for")
        func passTriggerMapping() {
            let expected: [(HealthSyncTrigger, SyncTrigger?)] = [
                (.manual, .manual),
                (.foreground, .foreground),
                (.processing, .background),
                (.appRefresh, .background),
                (.observer, .background),
                (.silentPush, .push),
                (.coldActivation, nil),
                (.postAuthentication, nil),
                (.accountTeardown, nil)
            ]
            #expect(Set(expected.map(\.0)) == Set(HealthSyncTrigger.allCases))
            for (trigger, wire) in expected {
                #expect(SyncTrigger(pass: trigger) == wire, "\(trigger)")
            }
        }

        @Test(
            "Short wakes plan the day totals and the pulse buckets, and run them first",
            arguments: [HealthSyncTrigger.appRefresh, .silentPush, .processing, .foreground, .manual]
        )
        func shortAndLongPassesPlanTheAggregatesFirst(trigger: HealthSyncTrigger) {
            let planned = HealthSyncCompositionPlan.required(for: trigger)
            #expect(planned.isSuperset(of: [.dailyStatistics, .heartRateBuckets]))
            let ordered = HealthSyncCapabilityRegistry.unsupportedEverywhere().orderedPlan(planned)
            #expect(Array(ordered.prefix(2)) == [.dailyStatistics, .heartRateBuckets])
            #expect(ordered.last == .outboxDrain)
        }

        @Test(
            "The production daily-statistics adapter posts today and yesterday under the pass's trigger",
            arguments: [
                (HealthSyncTrigger.appRefresh, "background"),
                (.silentPush, "push")
            ]
        )
        func passAdapterPostsUnderThePassTrigger(trigger: HealthSyncTrigger, wire: String) async throws {
            let harness = try StatsSweepHarness()
            let context = HealthSyncRunContext(
                trigger: trigger,
                budget: HealthSyncBudget.required(for: trigger),
                observedSource: nil,
                isExpired: { false }
            )
            let result = await SyncTriggerContext.shared.runningPass(trigger) {
                await AppContainer.runDailyStatistics(harness.coordinator, keychain: InMemoryKeychain(), context: context)
            }

            #expect(result.disposition == .ran)
            #expect(harness.api.posts.map(\.trigger) == [wire])
            #expect(Set(harness.postedIds) == StatsSweepHarness.todayAndYesterdayIds)
        }

        @Test("A manual pass is `manual` on a v1.42 server")
        func manualPassIsManual() async throws {
            let context = SyncTriggerContext.shared
            context.noteServerVersion(ServerVersionInfo(version: "1.42.0"))
            defer { context.forgetServer() }
            let harness = try StatsSweepHarness()
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let stats = harness.coordinator
            coordinator.attachHealthSyncRoute { _, _ in
                _ = await stats.triggerDailyStatsSync(lookbackDays: StatsSweepHarness.recentLookback)
                return [.dailyStatistics]
            }
            await coordinator.runManualHealthSyncPass()

            #expect(harness.api.posts.map(\.trigger) == ["manual"])
        }

        // MARK: - The foreground deadline

        @Test("The foreground deadline no longer cancels the day totals")
        func foregroundDeadlineDoesNotCancelTheSweep() async throws {
            let harness = try StatsSweepHarness()
            let runner = DetachedHealthSyncRunner()
            let clock = Phase09ForegroundClock()
            let coordinator = ForegroundCoordinator(clock: clock)
            let slowDashboard = Phase09Gate()
            let started = DetachedPassBox()
            let stats = harness.coordinator

            // The production shape, with the HealthKit step doing what the
            // production adapter does: hand the pass to the runner and return.
            let plan = ForegroundPlan(legs: ForegroundPassPlan.shape.map { members in
                ForegroundLeg(members.map { member in
                    ForegroundStep(member) { _ in
                        switch member {
                        case .dashboardSummary:
                            await slowDashboard.wait()
                        case .healthKitStats:
                            let task = await runner.request(.foreground) { trigger, _ in
                                await SyncTriggerContext.shared.runningPass(trigger) {
                                    _ = await stats.triggerDailyStatsSync(lookbackDays: StatsSweepHarness.recentLookback)
                                }
                            }
                            started.set(task)
                        default:
                            break
                        }
                    }
                })
            })
            let pass = coordinator.begin(plan)
            #expect(await phase09Settle { clock.requested.contains(ForegroundCoordinator.Budget.standard.deadline) })
            #expect(await v1Settle { started.task != nil })
            clock.fire(ForegroundCoordinator.Budget.standard.deadline)
            clock.fire(ForegroundCoordinator.Budget.standard.drainAllowance)
            let report = await pass.value
            slowDashboard.open()
            await started.task?.value

            #expect(report?.outcome == .deadlineExpired)
            #expect(report?.count(.healthKitStats, .skipped) == 0)
            #expect(harness.api.posts.map(\.trigger) == ["foreground"])
            #expect(Set(harness.postedIds) == StatsSweepHarness.todayAndYesterdayIds)
        }

        @Test("The detached runner survives its requester and folds repeats into one trailing pass")
        func runnerCoalescesAndOutlivesItsCaller() async {
            let runner = DetachedHealthSyncRunner()
            let gate = Phase09Gate()
            let runs = TriggerLog()
            let pass: DetachedHealthSyncRunner.Pass = { trigger, _ in
                runs.append(trigger.rawValue)
                if runs.count == 1 { await gate.wait() }
            }
            let caller = Task { await runner.request(.coldActivation, pass: pass) }
            let first = await caller.value
            caller.cancel()
            #expect(await v1Settle { gate.arrivalCount == 1 })
            for _ in 0 ..< 4 {
                await runner.request(.foreground, pass: pass)
            }
            gate.open()
            await first.value

            #expect(runs.values == ["coldActivation", "foreground"])
            #expect(await runner.passesStarted == 2)
        }

        @Test("A detached pass stops admitting work once its own budget is spent")
        func runnerBudgetExpires() async {
            let now = DateBox(Date(timeIntervalSince1970: 0))
            let runner = DetachedHealthSyncRunner(budget: 90, clock: { now.value })
            let seen = TriggerLog()
            let task = await runner.request(.foreground) { _, isExpired in
                seen.append(isExpired() ? "expired" : "open")
                now.value = Date(timeIntervalSince1970: 91)
                seen.append(isExpired() ? "expired" : "open")
            }
            await task.value
            #expect(seen.values == ["open", "expired"])
        }

        // MARK: - HealthKit delivery

        @Test("A step delivery asks for the recent sweep under its page's trigger")
        func stepDeliveryRequestsTheSweep() async throws {
            let harness = try StatsSweepHarness()
            let standard = HealthLogStandard()
            let stats = harness.coordinator
            await standard.attachUploader(
                MeasurementBatchUploader(api: StatsRecordingAPI(), throttle: BatchSyncThrottle()),
                featureFlags: AlwaysOnFeatureFlags(),
                dailyStatsKick: { trigger in await stats.requestRecentDailyStatsSweep(trigger: trigger) }
            )
            let steps = HKQuantitySample(
                type: HKQuantityType(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 120),
                start: StatsSweepHarness.now.addingTimeInterval(-600),
                end: StatsSweepHarness.now.addingTimeInterval(-60)
            )
            await SyncTriggerContext.shared.bind(.background) {
                _ = await standard.consumePage([steps], ofType: HKQuantityTypeIdentifier.stepCount.rawValue, admitted: nil)
            }
            await stats.awaitRequestedDailyStatsSweeps()

            #expect(harness.api.posts.map(\.trigger) == ["background"])
            #expect(Set(harness.postedIds) == StatsSweepHarness.todayAndYesterdayIds)
        }

        @Test("A delivery returns only after its drain and the sweep it requested")
        func deliveryWaitsForItsSweep() async throws {
            let harness = try StatsSweepHarness()
            let stats = harness.coordinator
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: CollectorCursorBacking(), lease: lease)
            let observer = RecordingObserver()
            let consumer = KickingConsumer { await stats.requestRecentDailyStatsSweep(trigger: .background) }
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: ScriptedPageSource(pages: [CollectorFixture.page(1), CollectorFixture.page(2)]),
                consumer: consumer,
                observer: observer,
                deliveryFollowUp: AppContainer.deliveryFollowUp((nil, stats))
            )
            // A delivery never starts a first history walk, so the partition
            // gets its first cursor from a full pass, as on a device.
            _ = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )
            await stats.awaitRequestedDailyStatsSweeps()
            harness.reader.bump()
            await collector.startObserving([CollectorFixture.stepType], notBefore: .distantPast) {
                try CollectorFixture.makeLease(registry: registry)
            }

            await observer.deliver(CollectorFixture.stepType)

            // Both the page and the sweep it asked for are done when the
            // delivery returns, which is when HealthKit gets its receipt.
            #expect(consumer.pages == 2)
            #expect(harness.api.posts.map(\.trigger) == ["background", "background"])
            await collector.stopObserving()
        }

        @Test("HealthKit's completion handler is called exactly once: on finish, on error, or at the deadline")
        func deliveryReceiptFiresOnce() async {
            let calls = TriggerLog()
            let finished = HealthKitDeliveryReceipt { calls.append("finished") }
            finished.arm(deadline: .seconds(3600))
            finished.fire()
            finished.fire()
            #expect(calls.values == ["finished"])

            let stuck = HealthKitDeliveryReceipt { calls.append("deadline") }
            let sleeper = Phase09Gate()
            stuck.arm(deadline: .seconds(20)) { _ in await sleeper.wait() }
            #expect(!stuck.hasFired)
            sleeper.open()
            #expect(await v1Settle { stuck.hasFired })
            stuck.fire()
            #expect(calls.values == ["finished", "deadline"])
        }
    }

    // MARK: - Doubles

    /// A page consumer that requests the recent sweep, the way the standard
    /// does for a page of steps, and reports the page accepted.
    final class KickingConsumer: HealthSamplePageConsuming, @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = 0
        private let kick: @Sendable () async -> Void

        init(kick: @escaping @Sendable () async -> Void) {
            self.kick = kick
        }

        var pages: Int {
            lock.withLock { consumed }
        }

        func consume(
            _: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            lock.withLock { consumed += 1 }
            await kick()
            return ScriptedConsumer.accepted
        }
    }

    final class TriggerLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func append(_ value: String) {
            lock.withLock { items.append(value) }
        }

        var values: [String] {
            lock.withLock { items }
        }

        var count: Int {
            lock.withLock { items.count }
        }
    }

    final class DetachedPassBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.withLock { stored = task }
        }

        var task: Task<Void, Never>? {
            lock.withLock { stored }
        }
    }

    final class DateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date

        init(_ value: Date) {
            stored = value
        }

        var value: Date {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

#endif
