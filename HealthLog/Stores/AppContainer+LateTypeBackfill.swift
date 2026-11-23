import Foundation

// MARK: - Day-total history for types that join later

/// A summed type added after an account's all-time backfill (resting energy
/// in 1.7) would only ever get the 7-day catch-up: its history would never
/// reach the server. Each such type carries its own one-shot, set only after
/// its own backfill completed. It also waits for the server: a type the
/// server does not map yet is not collected, so its one-shot stays open
/// until a later server update lets the backfill run.
extension AppContainer {
    /// The summed types that joined after the shared one-shot existed.
    nonisolated static let lateDailyStatsTypes: [String] = [HealthKitBasalEnergy.identifier]
        + AppleHealthIngestQuantityTypes.dayTotalIdentifiers

    nonisolated static let lateDailyStatsBackfillFlagPrefix = "hl.healthkit.dailyStatsTypeBackfillCompleted."

    nonisolated static func lateDailyStatsBackfillFlagKey(_ identifier: String, keychain: KeychainStoring) -> String {
        lateDailyStatsBackfillFlagPrefix + identifier + "."
            + HealthKitBackfillWindowStore.partitionToken(for: keychain.getString(forKey: KeychainKey.userID))
    }

    /// Runs after a full (non-incremental) daily-statistics sweep.
    ///
    /// - `sharedBackfillRan`: this very pass ran the account's all-time
    ///   backfill and it completed. It covered every type the server took at
    ///   that moment, so those are marked without a second read.
    nonisolated static func runLateDailyStatsBackfills(
        _ sync: any HealthKitDailyStatsSyncing,
        keychain: KeychainStoring,
        sharedBackfillRan: Bool,
        defaults: UserDefaults = .standard,
        serverAccepts: (String) -> Bool = { HealthKitServerTypeGate.serverAccepts($0) }
    ) async {
        for identifier in lateDailyStatsTypes where serverAccepts(identifier) {
            let flag = lateDailyStatsBackfillFlagKey(identifier, keychain: keychain)
            guard !defaults.bool(forKey: flag) else { continue }
            if sharedBackfillRan {
                defaults.set(true, forKey: flag)
                continue
            }
            let lookback = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults)
                .map(lookbackDays(for:)) ?? incrementalLookbackDays
            if await sync.backfillDailyStats(identifier: identifier, lookbackDays: lookback) {
                defaults.set(true, forKey: flag)
            }
        }
    }
}
