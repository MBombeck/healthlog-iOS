#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// "Daten zurücksetzen" uploads Apple Health again (1.7, Alex's decision).
    ///
    /// The reset deletes the server's record, the Apple Health readings
    /// included. The cursors and the day-total cache said "already sent", so up
    /// to 1.6 the record stayed empty for everything older than the reset.
    @Suite("Data reset: Apple Health uploads again", .serialized)
    struct HealthDataResetResyncTests {
        static let type = HKQuantityTypeIdentifier.bodyMass.rawValue

        @Test("an armed reset drops the cursor of every partition once, then disarms")
        func armedResetDropsCursorsOnce() async throws {
            let defaults = try #require(UserDefaults(suiteName: "test.data.reset.\(UUID().uuidString)"))
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            try await cursors.save(HKQueryAnchor(fromValue: 42), for: key, requiring: lease)
            _ = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
            try await cursors.save(HKQueryAnchor(fromValue: 77), for: key, requiring: lease)

            #expect(
                await HealthDataResetResync.apply(store: cursors, typeIdentifiers: [Self.type], requiring: lease, defaults: defaults) == 0,
                "nothing happens while no reset is armed"
            )
            #expect(await cursors.anchor(for: key) != nil)

            HealthDataResetResync.arm(ownerID: lease.ownerID, defaults: defaults)
            let reset = await HealthDataResetResync.apply(
                store: cursors,
                typeIdentifiers: [Self.type],
                requiring: lease,
                defaults: defaults
            )

            #expect(reset == 1)
            #expect(await cursors.anchor(for: key) == nil, "the partition walks again like a fresh one")
            #expect(await cursors.splitState(for: key) == nil)
            #expect(HealthDataResetResync.pendingResetID(ownerID: lease.ownerID, defaults: defaults) == nil)

            try await cursors.save(HKQueryAnchor(fromValue: 99), for: key, requiring: lease)
            #expect(await HealthDataResetResync
                .apply(store: cursors, typeIdentifiers: [Self.type], requiring: lease, defaults: defaults) == 0)
            #expect(await cursors.anchor(for: key) != nil, "the next cursor stays")
        }

        @Test("a second reset arms again, and another account is not touched")
        func eachResetArmsOnceMore() throws {
            let defaults = try #require(UserDefaults(suiteName: "test.data.reset.\(UUID().uuidString)"))
            HealthDataResetResync.arm(ownerID: "account-a", defaults: defaults)
            let first = HealthDataResetResync.pendingResetID(ownerID: "account-a", defaults: defaults)
            HealthDataResetResync.arm(ownerID: "account-a", defaults: defaults)
            let second = HealthDataResetResync.pendingResetID(ownerID: "account-a", defaults: defaults)

            #expect(first != nil && second != nil && first != second)
            #expect(HealthDataResetResync.pendingResetID(ownerID: "account-b", defaults: defaults) == nil)
            HealthDataResetResync.finish(first ?? "", ownerID: "account-a", defaults: defaults)
            #expect(HealthDataResetResync.pendingResetID(ownerID: "account-a", defaults: defaults) == second, "never a newer reset")
        }

        @Test("the day totals are forgotten, so the next sweeps send them again")
        func dayTotalsAreForgotten() async throws {
            let harness = try HealthKitStatsDurabilityTests.harness(rows: [HealthKitStatsDurabilityTests.row(0, value: 500)])
            _ = await harness.coordinator.sync(lookbackDays: 7)
            #expect(try await harness.cache.count(ownerUserID: HealthKitStatsDurabilityTests.owner) > 0)
            let postsBefore = harness.api.posts.count

            await harness.coordinator.forgetUploadedTotals(ownerID: HealthKitStatsDurabilityTests.owner)

            #expect(try await harness.cache.count(ownerUserID: HealthKitStatsDurabilityTests.owner) == 0)
            _ = await harness.coordinator.sync(lookbackDays: 7)
            #expect(harness.api.posts.count > postsBefore, "the same day goes out again")
        }
    }
#endif
