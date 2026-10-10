import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **V1 (1.2, #66 / HealthLog#1173) — the `stats:` uploads reach the server on
    /// every trigger, for today and yesterday, under the trigger that caused them.**
    ///
    /// Field picture on 1.1.1 (292): every single-sample type arrived on its own,
    /// while the day totals and the pulse buckets stayed at the last "Sync all".
    /// The day totals had no trigger of their own: the foreground pass that
    /// carried them was cancelled at 250 ms, AppRefresh and silent push did not
    /// plan them, and a step delivery was dropped from the per-sample batch
    /// without asking for the sweep that replaces it.
    @Suite("V1 — stats sweeps per trigger", .serialized)
    struct StatsTriggerPathTests {
        // MARK: - The requested sweep

        @Test(
            "A requested sweep posts today and yesterday under the requester's trigger",
            arguments: [SyncTrigger.foreground, .background, .push]
        )
        func requestedSweepPostsRecentDaysUnderItsTrigger(trigger: SyncTrigger) async throws {
            let harness = try StatsSweepHarness()
            await harness.coordinator.requestRecentDailyStatsSweep(trigger: trigger)
            await harness.coordinator.awaitRequestedDailyStatsSweeps()

            #expect(harness.api.posts.count == 1)
            #expect(harness.api.posts.first?.trigger == trigger.rawValue)
            #expect(Set(harness.postedIds) == StatsSweepHarness.todayAndYesterdayIds)
            #expect(harness.postedIds.count == StatsSweepHarness.todayAndYesterdayIds.count)
        }

        @Test("`manual` goes on the wire only to a server that knows it (v1.42+)")
        func manualIsGatedOnTheServerVersion() async throws {
            let context = SyncTriggerContext.shared
            defer { context.forgetServer() }

            context.noteServerVersion(ServerVersionInfo(version: "1.41.2"))
            let older = try StatsSweepHarness()
            await context.withTrigger(.manual) {
                _ = await older.coordinator.sync(lookbackDays: StatsSweepHarness.recentLookback)
            }
            #expect(older.api.posts.map(\.trigger) == ["foreground"])

            context.noteServerVersion(ServerVersionInfo(version: "1.42.0"))
            let current = try StatsSweepHarness()
            await context.withTrigger(.manual) {
                _ = await current.coordinator.sync(lookbackDays: StatsSweepHarness.recentLookback)
            }
            #expect(current.api.posts.map(\.trigger) == ["manual"])
        }

        @Test("Requests while a sweep runs fold into exactly one trailing sweep")
        func repeatedRequestsCoalesce() async throws {
            let gate = Phase09Gate()
            let harness = try StatsSweepHarness(parkFirstPost: gate)
            await harness.coordinator.requestRecentDailyStatsSweep(trigger: .background)
            #expect(await v1Settle { gate.arrivalCount == 1 })
            for _ in 0 ..< 5 {
                await harness.coordinator.requestRecentDailyStatsSweep(trigger: .foreground)
            }
            gate.open()
            await harness.coordinator.awaitRequestedDailyStatsSweeps()

            // One sweep plus one trailing sweep, never six.
            #expect(harness.reader.readCount == 2)
            // The trailing sweep found nothing changed, so nothing went out twice.
            #expect(harness.api.posts.count == 1)
            #expect(harness.api.posts.first?.trigger == "background")
        }

        @Test("A requested sweep never posts a day older than yesterday")
        func noPostsBeyondTodayAndYesterday() async throws {
            let harness = try StatsSweepHarness()
            // A full 7-day catch-up first, so every older day is converged.
            _ = await harness.coordinator.sync(lookbackDays: 7)
            let first = harness.api.posts.count
            harness.reader.bump()
            await harness.coordinator.requestRecentDailyStatsSweep(trigger: .background)
            await harness.coordinator.awaitRequestedDailyStatsSweeps()

            let later = harness.api.posts.dropFirst(first).flatMap(\.externalIds)
            #expect(Set(later) == StatsSweepHarness.todayAndYesterdayIds)
            #expect(later.count == StatsSweepHarness.todayAndYesterdayIds.count)
        }

        @Test("An orchestrated sweep and a requested one do not post the same day twice")
        func orchestratedAndRequestedSweepsSerialize() async throws {
            let gate = Phase09Gate()
            let harness = try StatsSweepHarness(parkFirstPost: gate)
            let coordinator = harness.coordinator
            let orchestrated = Task { await coordinator.triggerDailyStatsSync(lookbackDays: StatsSweepHarness.recentLookback) }
            #expect(await v1Settle { gate.arrivalCount == 1 })
            await coordinator.requestRecentDailyStatsSweep(trigger: .background)
            gate.open()
            _ = await orchestrated.value
            await coordinator.awaitRequestedDailyStatsSweeps()

            #expect(harness.api.posts.count == 1)
            #expect(harness.reader.readCount == 2)
        }

        @Test("Cancelling the requester does not cancel the sweep it asked for")
        func requesterCancellationDoesNotStopTheSweep() async throws {
            let gate = Phase09Gate()
            let harness = try StatsSweepHarness(parkFirstPost: gate)
            let coordinator = harness.coordinator
            let requester = Task {
                await coordinator.requestRecentDailyStatsSweep(trigger: .foreground)
                try? await Task.sleep(for: .seconds(60))
            }
            #expect(await v1Settle { gate.arrivalCount == 1 })
            requester.cancel()
            gate.open()
            await coordinator.awaitRequestedDailyStatsSweeps()

            #expect(harness.api.posts.map(\.trigger) == ["foreground"])
        }

        @Test("Every accepted type is recorded with time, trigger and count, across launches")
        func uploadLogRecordsTypeTimeAndTrigger() async throws {
            let harness = try StatsSweepHarness()
            await harness.coordinator.requestRecentDailyStatsSweep(trigger: .background)
            await harness.coordinator.awaitRequestedDailyStatsSweeps()

            let log = HealthKitStatsUploadLogStore.load(ownerID: StatsSweepHarness.owner, defaults: harness.defaults)
            #expect(Set(log.uploads.keys) == Set(HealthKitCumulativeTypeConfig.defaults.map(\.identifier)))
            #expect(log.uploads.values.allSatisfy { $0.trigger == "background" && $0.count == 2 })
            #expect(log.uploads.values.allSatisfy { $0.at == StatsSweepHarness.now })
            #expect(log.lastSweep == .init(at: StatsSweepHarness.now, trigger: "background", count: 10))
            // Another account reads its own (empty) record.
            #expect(HealthKitStatsUploadLogStore.load(ownerID: "someone-else", defaults: harness.defaults).uploads.isEmpty)
        }
    }

    extension StatsSweepHarness {
        static let recentLookback = HealthKitStatisticsSyncCoordinator.recentLookbackDays
    }

#endif
