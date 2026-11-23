import Foundation

/// Resting energy (`BasalEnergyBurned`), server type `BASAL_ENERGY_BURNED`
/// since v1.47.1 (HealthLog#1340).
///
/// It accrues through the day like active energy and goes the same way: a
/// day total (`stats:`) in kilocalories, never added to active energy. Until
/// the configured server is known to map it, it is neither asked for nor
/// collected (``HealthKitServerTypeGate``), and an installation that went
/// through the HealthKit sheet before is asked for it after an explanation,
/// like the server-v1.44 types.
enum HealthKitBasalEnergy {
    static let identifier = "HKQuantityTypeIdentifierBasalEnergyBurned"

    /// The first server release whose batch route maps it.
    static let minimumServerVersion = "1.47.1"

    /// The server's unit for it (`apple-health-mapping.ts`: kcal in, kcal stored).
    static let wireUnit = "kcal"

    /// Every read type a returning installation is asked for after the
    /// "what is new" card, in the order the card names them.
    static let announcedLateReadIdentifiers: [String] =
        HealthKitServer144Types.lateReadIdentifiers + [identifier]
}
