import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **X4 (1.3, #138 / #77)** — the hourly path end to end through the
    /// production coordinator: the server gate, live hours on every sweep,
    /// the `backfill` label, idempotency, bounds, and the update path from a
    /// 1.2.0 / 1.3 install whose day totals already converged.
    @Suite("X4 hourly stats: live hours, backfill and the server gate")
    struct HourlyStatsSyncTests {
        typealias Harness = HourlySweepHarness

        /// Today 00:00 ... 14:59 and all of yesterday, four types.
        static let openHourCount = (15 + 24) * 4
        static let backfillDayCount = 28

        // MARK: - Gate

        @Test("an older server sees exactly 1.2's day totals; no hourly read, no hourly row")
        func olderServerKeepsTodaysBehaviour() async throws {
            for (version, features) in [
                ("1.42.4", Set(KnownServerVersion.Feature.allCases)),
                ("1.43.0", Set<KnownServerVersion.Feature>()),
                ("1.43.0", [KnownServerVersion.Feature.syncTriggerBackfill])
            ] {
                let harness = try Harness()
                harness.serverSays(version: version, features: features)
                await harness.coordinator.sync(lookbackDays: 1)
                let outcome = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28))

                #expect(harness.reader.hourlyReadCount == 0, "\(version) \(features)")
                #expect(harness.hourlyPosts.isEmpty)
                #expect(outcome == .serverUnsupported)
                #expect(harness.api.posts.count == 1)
                #expect(Set(harness.dayPosts.flatMap(\.externalIds)).count == HealthKitCumulativeTypeConfig.defaults.count * 2)
            }
            // Never probed at all: the same.
            let fresh = try Harness()
            await fresh.coordinator.sync(lookbackDays: 1)
            #expect(fresh.reader.hourlyReadCount == 0)
            #expect(fresh.hourlyPosts.isEmpty)
        }

        @Test("the gate is version AND flag, and a server change forgets both")
        func gateNeedsVersionAndFlag() throws {
            let defaults = try #require(UserDefaults(suiteName: "test.x4.gate.\(UUID().uuidString)"))
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            KnownServerVersion.recordFeatures([.cumulativeHourBuckets], defaults: defaults)
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            KnownServerVersion.record(ServerVersionInfo(version: "1.43.0"), defaults: defaults)
            #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            #expect(!KnownServerVersion.supports(.syncTriggerBackfill, defaults: defaults))
            KnownServerVersion.record(ServerVersionInfo(version: "1.42.9"), defaults: defaults)
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            KnownServerVersion.record(ServerVersionInfo(version: "1.44.0"), defaults: defaults)
            #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            // An older server answering `/me` without the block clears it.
            KnownServerVersion.recordFeatures(ServerFeatures.recorded(nil), defaults: defaults)
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            KnownServerVersion.recordFeatures(Set(KnownServerVersion.Feature.allCases), defaults: defaults)
            KnownServerVersion.forget(defaults: defaults)
            KnownServerVersion.record(ServerVersionInfo(version: "1.43.0"), defaults: defaults)
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
        }

        @Test("`/api/auth/me` features decode leniently and never cost the module map")
        func featuresDecodeLeniently() throws {
            let decode = { (json: String) throws -> AuthMeModules in
                try JSONDecoder().decode(AuthMeModules.self, from: Data(json.utf8))
            }
            let full =
                try decode(
                    #"{"modules":{"cycle":true},"features":{"trackIntake":true,"cumulativeHourBuckets":true,"syncTriggerBackfill":true,"biomarkerMerge":true}}"#
                )
            #expect(ServerFeatures.recorded(full.features) == [.cumulativeHourBuckets, .syncTriggerBackfill])
            let partial = try decode(#"{"modules":{"cycle":true},"features":{"trackIntake":true,"cumulativeHourBuckets":false}}"#)
            #expect(ServerFeatures.recorded(partial.features).isEmpty)
            let absent = try decode(#"{"modules":{"cycle":true}}"#)
            #expect(absent.features == nil)
            let malformed = try decode(#"{"modules":{"cycle":true},"features":"yes"}"#)
            #expect(malformed.features == nil)
            #expect(malformed.modules == ["cycle": true])
            let wrongType = try decode(#"{"modules":{},"features":{"cumulativeHourBuckets":"true","syncTriggerBackfill":true}}"#)
            #expect(ServerFeatures.recorded(wrongType.features) == [.syncTriggerBackfill])
        }

        @MainActor
        @Test("every `/me` load hands its features to the sink; an older server's answer clears them")
        func moduleGateLoadRecordsFeatures() async throws {
            let api = HourlyMeAPI()
            let gate = ModuleGate(repo: ModuleGateRepository(api: api))
            let defaults = try #require(UserDefaults(suiteName: "test.x4.me.\(UUID().uuidString)"))
            KnownServerVersion.record(ServerVersionInfo(version: "1.43.0"), defaults: defaults)
            nonisolated(unsafe) let unsafeDefaults = defaults
            gate.serverFeaturesSink = { features in
                KnownServerVersion.recordFeatures(ServerFeatures.recorded(features), defaults: unsafeDefaults)
            }
            api.json = #"{"modules":{},"features":{"trackIntake":true,"cumulativeHourBuckets":true,"syncTriggerBackfill":true}}"#
            await gate.load()
            #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
            #expect(KnownServerVersion.supports(.syncTriggerBackfill, defaults: defaults))

            api.json = #"{"modules":{}}"#
            await gate.load()
            #expect(!KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))

            // A failed load says nothing and keeps the last answer.
            api.json = #"{"modules":{},"features":{"cumulativeHourBuckets":true}}"#
            await gate.load()
            api.json = nil
            await gate.load()
            #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
        }

        // MARK: - Live

        @Test("a v1.43 sweep posts today's and yesterday's hours under the sweep's own trigger")
        func liveHoursRideEverySweep() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            await harness.context.bind(.background) {
                _ = await harness.coordinator.sync(lookbackDays: 1)
            }

            #expect(harness.dayPosts.count == 1)
            #expect(Set(harness.dayPosts.flatMap(\.externalIds)).count == HealthKitCumulativeTypeConfig.defaults.count * 2)
            let hourly = try #require(harness.hourlyPosts.first)
            #expect(harness.hourlyPosts.count == 1)
            #expect(hourly.trigger == "background")
            #expect(hourly.externalIds.count == Self.openHourCount)
            #expect(Set(hourly.externalIds.map { String($0.split(separator: ":")[2].prefix(10)) })
                == [Harness.dayKey(0), Harness.dayKey(1)])
            // The hour in progress (14:00) is in, the next one is not.
            #expect(hourly.externalIds.contains("stats:HKQuantityTypeIdentifierStepCount:\(Harness.dayKey(0))T14"))
            #expect(!hourly.externalIds.contains("stats:HKQuantityTypeIdentifierStepCount:\(Harness.dayKey(0))T15"))
            #expect(!hourly.externalIds.contains { $0.contains("TimeInDaylight") })
            #expect(hourly.units.allSatisfy { ["steps", "kcal", "m", "flights"].contains($0) })
            #expect(harness.ledger.lastLiveOutcome == .uploaded)
        }

        @Test("idempotent: an unchanged hour is never sent twice; a changed one is sent alone")
        func liveHoursAreIdempotent() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            await harness.coordinator.sync(lookbackDays: 1)
            await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.hourlyPosts.count == 1)
            #expect(harness.ledger.lastLiveOutcome == .upToDate)

            harness.reader.bumpHours()
            await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.hourlyPosts.count == 2)
            // 08:00 ... 14:00 today and 08:00 ... 20:00 yesterday carry data.
            #expect(harness.hourlyPosts[1].externalIds.count == (7 + 13) * 4)
            // Every id stays the same stable slot: the server overwrites it.
            #expect(Set(harness.hourlyPosts[1].externalIds).isSubset(of: Set(harness.hourlyPosts[0].externalIds)))
        }

        @Test("a failed hourly upload holds nothing of the day totals and is sent again next sweep")
        func failedLiveUploadIsRetried() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            await harness.coordinator.sync(lookbackDays: 1)
            harness.reader.bumpHours()
            harness.api.failing = true
            let held = await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.ledger.lastLiveOutcome == .uploadFailed)
            // The day totals had nothing new; an hourly failure never makes
            // their sweep incomplete.
            #expect(held.isComplete)
            harness.api.failing = false
            await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.hourlyPosts.count == 2)
            #expect(harness.ledger.lastLiveOutcome == .uploaded)
        }

        // MARK: - Backfill

        @Test("the backfill sends 28 closed days as `backfill`, whole days, at most 500 rows a batch")
        func backfillLabelsAndBounds() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            let outcome = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28))

            #expect(outcome == .uploaded)
            let posts = harness.hourlyPosts
            #expect(posts.count == 6)
            #expect(posts.allSatisfy { $0.trigger == "backfill" })
            #expect(posts.allSatisfy { $0.externalIds.count <= 500 && $0.externalIds.count % 96 == 0 })
            let days = posts.flatMap(\.externalIds).map { String($0.split(separator: ":")[2].prefix(10)) }
            #expect(Set(days) == Set((2 ..< 30).map { Harness.dayKey($0) }))
            #expect(days.first == Harness.dayKey(2)) // newest first
            #expect(posts.flatMap(\.externalIds).count == Self.backfillDayCount * 96)
            #expect(harness.ledger.completedDays.count == Self.backfillDayCount)
            #expect(HourlyStatsLedgerStore.status(ownerID: Harness.owner, defaults: harness.defaults).isBackfillComplete)

            // Done is done: the next pass neither reads nor sends.
            let reads = harness.reader.hourlyReadCount
            #expect(await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28)) == .upToDate)
            #expect(harness.reader.hourlyReadCount == reads)
            #expect(harness.hourlyPosts.count == 6)
        }

        @Test("without `syncTriggerBackfill` the hours go out under the live trigger, never `backfill`")
        func backfillWordNeedsItsOwnFlag() async throws {
            let harness = try Harness()
            harness.serverSays(version: "1.43.0", features: [.cumulativeHourBuckets])
            await harness.context.bind(.foreground) {
                _ = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 3))
            }
            #expect(harness.hourlyPosts.count == 1)
            #expect(harness.hourlyPosts.allSatisfy { $0.trigger == "foreground" })
        }

        @Test("a pass budget of seven days walks the window back a week per pass")
        func backfillIsBoundedPerPass() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            _ = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 7))
            #expect(harness.ledger.completedDays == Set((2 ..< 9).map { Harness.dayKey($0) }))
            _ = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 7))
            #expect(harness.ledger.completedDays == Set((2 ..< 16).map { Harness.dayKey($0) }))
            #expect(harness.hourlyPosts.flatMap(\.externalIds).count == 14 * 96)
        }

        @Test("an expired pass sends nothing and leaves every day owed; a failed batch keeps its days")
        func backfillStopsCleanly() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            let expired = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28, expired: true))
            #expect(expired == .expired)
            #expect(harness.hourlyPosts.isEmpty)
            #expect(harness.ledger.completedDays.isEmpty)

            harness.api.failing = true
            #expect(await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28)) == .uploadFailed)
            #expect(harness.ledger.completedDays.isEmpty)

            harness.api.failing = false
            harness.reader.failingHourly = true
            #expect(await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28)) == .queryFailed)
            #expect(harness.ledger.completedDays.isEmpty)
            #expect(harness.hourlyPosts.isEmpty)
        }

        @Test("a day that closes is read once more as history and sends only the hours that changed")
        func closingDayIsReconciledOnce() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            let calendar = Harness.utc
            let dayStart = try #require(calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Harness.now)))
            let dayEnd = dayStart.addingTimeInterval(86399)
            // The live path accepted day 2 while it was open (same zone).
            let seen = await harness.reader.hourlyRows(from: dayStart, through: dayEnd).rows
            var ledger = HourlyStatsLedger()
            ledger.adopt(timeZoneIdentifier: harness.reader.zone.identifier)
            ledger.remember(seen)
            HourlyStatsLedgerStore.save(ledger, ownerID: Harness.owner, defaults: harness.defaults)

            #expect(await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 1)) == .upToDate)
            #expect(harness.hourlyPosts.isEmpty) // nothing changed since
            #expect(harness.ledger.completedDays == [Harness.dayKey(2)])
            #expect(harness.ledger.accepted[Harness.dayKey(2)] == nil)

            // Day 3 got a late Watch sample after the live path saw it.
            let dayThree = dayStart.addingTimeInterval(-86400)
            var older = harness.ledger
            await older.remember(harness.reader.hourlyRows(from: dayThree, through: dayThree.addingTimeInterval(86399)).rows)
            HourlyStatsLedgerStore.save(older, ownerID: Harness.owner, defaults: harness.defaults)
            harness.reader.bumpHours()
            #expect(await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 1)) == .uploaded)
            #expect(harness.hourlyPosts.count == 1)
            #expect(harness.hourlyPosts[0].externalIds.count == 13 * 4) // the hours with data
            #expect(harness.hourlyPosts[0].trigger == "backfill")
        }

        @Test("`backfill` goes on the wire only when the server takes it, and never changes `current`")
        func backfillWireValue() async {
            let context = SyncTriggerContext()
            await context.bind(.background) {
                // SYNC-TRIG (1.5) — the mark is an argument of the upload, no
                // longer a task-local; the expectations are unchanged.
                #expect(context.current == .background)
                #expect(context.wireValue(backfill: true) == .background)
                context.noteServerVersion(ServerVersionInfo(version: "1.43.0"))
                #expect(context.wireValue(backfill: true) == .background)
                context.noteServerFeatures([.syncTriggerBackfill])
                #expect(context.wireValue(backfill: true) == .backfill)
                #expect(context.current == .background)
                context.noteServerVersion(ServerVersionInfo(version: "1.42.4"))
                #expect(context.wireValue(backfill: true) == .background)
                // Without the mark the pass keeps its own word.
                context.noteServerVersion(ServerVersionInfo(version: "1.43.0"))
                #expect(context.wireValue == .background)
            }
            context.forgetServer()
            await context.withTrigger(.backfill) {
                #expect(context.wireValue == .foreground)
            }
        }

        @Test("a new account zone sends every hour again, cut in the new zone")
        func zoneChangeResends() async throws {
            let harness = try Harness()
            harness.serverIsV143()
            _ = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28))
            #expect(harness.ledger.completedDays.count == 28)
            harness.reader.zone = try #require(TimeZone(identifier: "Europe/Berlin"))
            _ = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28))
            #expect(harness.ledger.timeZoneIdentifier == "Europe/Berlin")
            #expect(harness.ledger.completedDays.count == 28)
            #expect(harness.hourlyPosts.count == 12)
        }

        // MARK: - Update path

        @Test("update path: a 1.2.0 install whose day totals converged sends hours, never a day row twice")
        func updatePathFromConvergedDayTotals() async throws {
            let harness = try Harness()
            // 1.2.0 against a v1.42 server: day totals only.
            harness.serverSays(version: "1.42.4", features: [])
            await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.api.posts.count == 1)
            let dayIds = Set(harness.dayPosts.flatMap(\.externalIds))
            // The 1.2 state the next build finds: the day-total sweep end and
            // the V1 upload log, no hourly ledger.
            #expect(harness.defaults.object(forKey: HealthKitStatisticsSyncCoordinator.lastSweepEndKey(ownerID: Harness.owner)) != nil)
            #expect(harness.defaults.data(forKey: HourlyStatsLedgerStore.key(ownerID: Harness.owner)) == nil)

            // The server is upgraded to v1.43 and `/me` says so.
            harness.serverIsV143()
            await harness.coordinator.sync(lookbackDays: 1)
            #expect(harness.dayPosts.count == 1) // the converged day totals are not re-sent
            #expect(Set(harness.dayPosts.flatMap(\.externalIds)) == dayIds)
            #expect(harness.hourlyPosts.count == 1)
            #expect(harness.hourlyPosts[0].externalIds.count == Self.openHourCount)

            let outcome = await harness.coordinator.runHourlyStatsBackfill(Harness.allowance(days: 28))
            #expect(outcome == .uploaded)
            #expect(harness.ledger.completedDays.count == 28)
            // No hour id collides with a day id: two different forms.
            let hourIds = Set(harness.hourlyPosts.flatMap(\.externalIds))
            #expect(hourIds.isDisjoint(with: dayIds))
            #expect(hourIds.count == Self.openHourCount + 28 * 96)
        }

        // MARK: - Pass wiring

        @Test("only triggers that may walk history get a backfill allowance")
        func allowancePerTrigger() {
            for trigger in HealthSyncTrigger.allCases {
                let context = HealthSyncRunContext(
                    trigger: trigger,
                    budget: .required(for: trigger),
                    observedSource: nil,
                    isExpired: { false }
                )
                let allowance = AppContainer.hourlyBackfillAllowance(for: context)
                switch trigger {
                case .appRefresh, .silentPush, .observer, .accountTeardown:
                    #expect(allowance == nil, "\(trigger)")
                case .processing:
                    #expect(allowance?.maxDays == 28)
                    #expect(allowance?.timeBudget == 120)
                case .coldActivation, .postAuthentication, .foreground, .manual:
                    #expect(allowance?.maxDays == 7, "\(trigger)")
                    #expect(allowance?.timeBudget == 20)
                }
            }
        }
    }

#endif
