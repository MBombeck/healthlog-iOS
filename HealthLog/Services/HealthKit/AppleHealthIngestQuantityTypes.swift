import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// The quantity types 1.7 adds to the measurement batch, by registry
/// (run-time) identifier. Each one is an ordinary per-sample row
/// (`externalId` = the sample UUID) and goes through the app-owned
/// collection like every other registry type, so an installation that
/// already syncs gets the live window first and the history through the
/// existing backward cursor, never a full re-read.
///
/// | group | HealthKit | server type | wire unit | gate |
/// |---|---|---|---|---|
/// | insulin and breathing | `InsulinDelivery` | `INSULIN_DELIVERY` | IU | 1.48.2 or `acceptedTypes` |
/// | | `InhalerUsage` | `INHALER_USAGE` | count | |
/// | | `ForcedExpiratoryVolume1` | `FEV1` | L | |
/// | | `ForcedVitalCapacity` | `FVC` | L | |
/// | | `PeakExpiratoryFlowRate` | `PEAK_EXPIRATORY_FLOW` | L/min | |
/// | effort (HealthLog#1416) | `WorkoutEffortScore` | `WORKOUT_EFFORT_SCORE` | count | `acceptedTypes` only |
/// | | `EstimatedWorkoutEffortScore` | `ESTIMATED_WORKOUT_EFFORT_SCORE` | count | |
/// | | `PhysicalEffort` | `PHYSICAL_EFFORT` | kcal/(hr*kg) | |
/// | training (HealthLog#1415) | `DistanceCycling` | `CYCLING_DISTANCE` (day total `stats:`) | m | capability `apple-health.types-2026-11`,
/// `acceptedTypes` as fallback |
/// | | `RunningSpeed` | `RUNNING_SPEED` | m/s | |
/// | | `RunningPower` | `RUNNING_POWER` | W | |
/// | | `RunningGroundContactTime` | `RUNNING_GROUND_CONTACT_TIME` | ms | |
/// | | `RunningVerticalOscillation` | `RUNNING_VERTICAL_OSCILLATION` | cm | |
/// | | `RunningStrideLength` | `RUNNING_STRIDE_LENGTH` | m | |
/// | | `DistanceRowing` | `ROWING_DISTANCE` (day total `stats:`) | m | |
/// | | `RowingSpeed` | `ROWING_SPEED` | m/s | |
///
/// The effort group opens by the capability `apple-health.effort-scores`,
/// with `acceptedTypes` as the fallback (server 1.49.0, #191).
///
/// **The two distances are day totals**, like steps and walking distance:
/// `stats:<identifier>:<YYYY-MM-DD>` from a cumulative-sum statistics query,
/// so a ride the Watch and the iPhone both recorded counts once. They are in
/// the read set and on the card, but not in the per-sample registry.
///
/// The app sends the HealthKit identifier, never the server type, so a
/// renamed server type changes nothing here. What does matter is the unit:
/// the server compares it with its own table and answers `unit_mismatch`
/// otherwise. The effort and training types are collected only once the
/// server lists them in `acceptedTypes`; an older server never sees a row
/// it would refuse.
enum AppleHealthIngestQuantityTypes {
    static let insulinDelivery = "HKQuantityTypeIdentifierInsulinDelivery"
    static let inhalerUsage = "HKQuantityTypeIdentifierInhalerUsage"
    static let forcedExpiratoryVolume1 = "HKQuantityTypeIdentifierForcedExpiratoryVolume1"
    static let forcedVitalCapacity = "HKQuantityTypeIdentifierForcedVitalCapacity"
    static let peakExpiratoryFlowRate = "HKQuantityTypeIdentifierPeakExpiratoryFlowRate"

    static let workoutEffortScore = "HKQuantityTypeIdentifierWorkoutEffortScore"
    static let estimatedWorkoutEffortScore = "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore"
    static let physicalEffort = "HKQuantityTypeIdentifierPhysicalEffort"

    static let distanceCycling = "HKQuantityTypeIdentifierDistanceCycling"
    static let runningSpeed = "HKQuantityTypeIdentifierRunningSpeed"
    static let runningPower = "HKQuantityTypeIdentifierRunningPower"
    static let runningGroundContactTime = "HKQuantityTypeIdentifierRunningGroundContactTime"
    static let runningVerticalOscillation = "HKQuantityTypeIdentifierRunningVerticalOscillation"
    static let runningStrideLength = "HKQuantityTypeIdentifierRunningStrideLength"
    static let distanceRowing = "HKQuantityTypeIdentifierDistanceRowing"
    static let rowingSpeed = "HKQuantityTypeIdentifierRowingSpeed"

    /// Insulin, inhaler and spirometry: mapped since server 1.48.2 (#183).
    static let respiratoryIdentifiers: [String] = [
        insulinDelivery, inhalerUsage, forcedExpiratoryVolume1, forcedVitalCapacity, peakExpiratoryFlowRate
    ]

    /// Workout and physical effort (HealthLog#1416).
    static let effortIdentifiers: [String] = [workoutEffortScore, estimatedWorkoutEffortScore, physicalEffort]

    /// Cycling distance, running form and rowing (HealthLog#1415).
    static let trainingIdentifiers: [String] = [
        distanceCycling, runningSpeed, runningPower, runningGroundContactTime,
        runningVerticalOscillation, runningStrideLength, distanceRowing, rowingSpeed
    ]

    /// Every quantity type this file adds, in card and sweep order.
    static let allIdentifiers: [String] = respiratoryIdentifiers + effortIdentifiers + trainingIdentifiers

    /// The two distances, summed per day by the statistics sync.
    static let dayTotalIdentifiers: [String] = [distanceCycling, distanceRowing]

    /// The ones that go per sample through the registry.
    static let sampleIdentifiers: [String] = allIdentifiers.filter { !dayTotalIdentifiers.contains($0) }

    /// The capability on `GET /api/version` that opens the effort group.
    static let effortCapability = "apple-health.effort-scores"

    /// The release that maps the respiratory group, for a server that does
    /// not publish `acceptedTypes`.
    static let respiratoryMinimumServerVersion = "1.48.2"

    static let minimumServerVersionByIdentifier: [String: String] = Dictionary(
        uniqueKeysWithValues: respiratoryIdentifiers.map { ($0, respiratoryMinimumServerVersion) }
    )

    /// Opened only by the server's own list, never by version.
    static let publishedOnlyIdentifiers: Set<String> = Set(effortIdentifiers + trainingIdentifiers)

    /// The capability on `GET /api/version` that opens the training types
    /// (server 1.49.0, #191).
    static let trainingCapability = "apple-health.types-2026-11"

    /// The server type each identifier lands on. Documentation and Sync
    /// Diagnostics and the replay shortcut only: the wire carries the HealthKit
    /// identifier. Confirmed by the server (#191).
    static let serverTypeByIdentifier: [String: String] = [
        insulinDelivery: "INSULIN_DELIVERY",
        inhalerUsage: "INHALER_USAGE",
        forcedExpiratoryVolume1: "FEV1",
        forcedVitalCapacity: "FVC",
        peakExpiratoryFlowRate: "PEAK_EXPIRATORY_FLOW",
        workoutEffortScore: "WORKOUT_EFFORT_SCORE",
        estimatedWorkoutEffortScore: "ESTIMATED_WORKOUT_EFFORT_SCORE",
        physicalEffort: "PHYSICAL_EFFORT",
        distanceCycling: "CYCLING_DISTANCE",
        runningSpeed: "RUNNING_SPEED",
        runningPower: "RUNNING_POWER",
        runningGroundContactTime: "RUNNING_GROUND_CONTACT_TIME",
        runningVerticalOscillation: "RUNNING_VERTICAL_OSCILLATION",
        runningStrideLength: "RUNNING_STRIDE_LENGTH",
        distanceRowing: "ROWING_DISTANCE",
        rowingSpeed: "ROWING_SPEED"
    ]

    /// The wire unit per identifier, as the server's mapping names it.
    static let wireSymbolByIdentifier: [String: String] = [
        insulinDelivery: "IU",
        inhalerUsage: "count",
        forcedExpiratoryVolume1: "L",
        forcedVitalCapacity: "L",
        peakExpiratoryFlowRate: "L/min",
        workoutEffortScore: "count",
        estimatedWorkoutEffortScore: "count",
        physicalEffort: "kcal/(hr*kg)",
        distanceCycling: "m",
        runningSpeed: "m/s",
        runningPower: "W",
        runningGroundContactTime: "ms",
        runningVerticalOscillation: "cm",
        runningStrideLength: "m",
        distanceRowing: "m",
        rowingSpeed: "m/s"
    ]

    #if canImport(HealthKit)
        /// The unit a sample is read in, matching ``wireSymbolByIdentifier``.
        static func hkUnit(for identifier: String) -> HKUnit? {
            let perSecond = HKUnit.meter().unitDivided(by: .second())
            switch identifier {
            case insulinDelivery: return .internationalUnit()
            case inhalerUsage: return .count()
            case forcedExpiratoryVolume1, forcedVitalCapacity: return .liter()
            case peakExpiratoryFlowRate: return HKUnit.liter().unitDivided(by: .minute())
            // HealthKit stores both scores in its own dimensionless unit.
            case workoutEffortScore, estimatedWorkoutEffortScore: return .appleEffortScore()
            case physicalEffort:
                return HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
            case distanceCycling, runningStrideLength, distanceRowing: return .meter()
            case runningSpeed, rowingSpeed: return perSecond
            case runningPower: return .watt()
            case runningGroundContactTime: return .secondUnit(with: .milli)
            case runningVerticalOscillation: return .meterUnit(with: .centi)
            default: return nil
            }
        }

        /// The wire unit of one of these types, or `nil` for any other.
        static func wireUnit(for identifier: String) -> HealthKitWireConverter.WireUnit? {
            guard let unit = hkUnit(for: identifier), let symbol = wireSymbolByIdentifier[identifier] else { return nil }
            return HealthKitWireConverter.WireUnit(hkUnit: unit, wireSymbol: symbol, scale: 1)
        }

        /// The resolved quantity type, `nil` where this system lacks it.
        static func sampleType(for identifier: String) -> HKQuantityType? {
            guard allIdentifiers.contains(identifier) else { return nil }
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        }
    #endif
}
