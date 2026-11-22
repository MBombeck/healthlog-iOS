import Foundation
@testable import HealthLog
import Testing

/// A summed type that joins after the account's all-time backfill (resting
/// energy) gets its own history once, never only the 7-day catch-up.
@Suite("Late day-total types: their own backfill")
struct LateDailyStatsBackfillTests {
    actor RecordingBackfill: HealthKitDailyStatsSyncing {
        private(set) var backfills: [(identifier: String, lookbackDays: Int)] = []
        private var answers: [Bool]

        init(answers: [Bool] = [true]) {
            self.answers = answers
        }

        @discardableResult
        func triggerDailyStatsSync(lookbackDays _: Int) async -> Bool {
            true
        }

        func backfillDailyStats(identifier: String, lookbackDays: Int) async -> Bool {
            backfills.append((identifier, lookbackDays))
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }

    private static let basal = HealthKitBasalEnergy.identifier

    /// 1.7: cycling and rowing distance are day totals too. Each gets its
    /// own one-shot once the server takes it; the cases below keep to
    /// resting energy by letting the server take only that one.
    @Test("update to 1.7: the two distances get their own history once their capability opens")
    func distancesGetTheirOwnBackfill() async throws {
        let (keychain, defaults) = try Self.installation16()
        let sync = RecordingBackfill()
        let distances = Set(AppleHealthIngestQuantityTypes.dayTotalIdentifiers)
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { distances.contains($0) }
        )
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { distances.contains($0) }
        )
        let calls = await sync.backfills
        #expect(Set(calls.map(\.identifier)) == distances)
        #expect(calls.count == 2, "once each")
    }

    /// The state a 1.6 installation leaves: signed in, a one-year window,
    /// and the shared all-time backfill long done.
    private static func installation16(window: HealthKitBackfillWindow = .oneYear) throws -> (InMemoryKeychain, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "hl.tests.latebackfill.\(UUID().uuidString)"))
        let keychain = InMemoryKeychain()
        try keychain.setString("usr_16", forKey: KeychainKey.userID)
        HealthKitBackfillWindowStore.persist(window, keychain: keychain, defaults: defaults)
        AppContainer.markDailyStatsAllTimeBackfillCompleted(keychain: keychain, defaults: defaults)
        return (keychain, defaults)
    }

    @Test("update from 1.6: resting energy gets its year of history once, on a server that maps it")
    func updateFromOnePointSix() async throws {
        let (keychain, defaults) = try Self.installation16()
        #expect(AppContainer.dailyStatsLookbackForNextSweep(keychain: keychain, defaults: defaults) == 7)
        let sync = RecordingBackfill()

        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )

        let calls = await sync.backfills
        #expect(calls.count == 1)
        #expect(calls.first?.identifier == Self.basal)
        #expect(calls.first?.lookbackDays == 365)
    }

    @Test("a server that does not map it yet keeps the backfill owed until it does")
    func waitsForTheServer() async throws {
        let (keychain, defaults) = try Self.installation16(window: .allTime)
        let sync = RecordingBackfill()

        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { _ in false }
        )
        #expect(await sync.backfills.isEmpty)

        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        #expect(await sync.backfills.map(\.lookbackDays) == [AppContainer.allTimeLookbackDays])
    }

    @Test("an incomplete backfill is tried again on the next full pass")
    func incompleteBackfillRetries() async throws {
        let (keychain, defaults) = try Self.installation16()
        let sync = RecordingBackfill(answers: [false, true, true])

        for _ in 0 ..< 3 {
            await AppContainer.runLateDailyStatsBackfills(
                sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
            )
        }
        #expect(await sync.backfills.count == 2)
    }

    @Test("a new install's shared backfill already covered it: no second read")
    func newInstallIsCoveredByTheSharedBackfill() async throws {
        let defaults = try #require(UserDefaults(suiteName: "hl.tests.latebackfill.new.\(UUID().uuidString)"))
        let keychain = InMemoryKeychain()
        try keychain.setString("usr_new", forKey: KeychainKey.userID)
        let sync = RecordingBackfill()

        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: true, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        #expect(await sync.backfills.isEmpty)
    }

    @Test("the one-shot belongs to the account: another account on the device still gets its backfill")
    func flagIsPerAccount() async throws {
        let (keychain, defaults) = try Self.installation16()
        let sync = RecordingBackfill()
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        try keychain.setString("usr_other", forKey: KeychainKey.userID)
        HealthKitBackfillWindowStore.persist(.thirtyDays, keychain: keychain, defaults: defaults)
        await AppContainer.runLateDailyStatsBackfills(
            sync, keychain: keychain, sharedBackfillRan: false, defaults: defaults, serverAccepts: { $0 == Self.basal }
        )
        #expect(await sync.backfills.map(\.lookbackDays) == [365, 30])
    }
}
