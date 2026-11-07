import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// HK-NEW (1.5, #149, #126 3.10, public #13) — the six Apple Health
/// types the server maps since v1.44.0 (`apple-health-mapping.ts`, block
/// "v1.44 — activity rings, mindfulness, State of Mind, AFib burden") and
/// that HealthLog did not read before 1.5.
///
/// | HealthKit | server type | path | wire |
/// |---|---|---|---|
/// | `AppleExerciseTime` | `EXERCISE_MINUTES` | day total (`stats:`), like daylight | minutes |
/// | `AppleStandTime` | `STAND_MINUTES` | day total (`stats:`), like daylight | minutes |
/// | `AppleStandHour` | `STAND_HOURS` | sample, `1` per stood hour, idle hours never | count |
/// | `MindfulSession` | `MINDFUL_MINUTES` | sample, minutes from start and end | min |
/// | State of Mind | `STATE_OF_MIND_VALENCE` | sample, valence −1…1, see ``StateOfMindValencePolicy`` | valence |
/// | `AtrialFibrillationBurden` | `AFIB_BURDEN` | sample, raw fraction 0…1 (the server scales ×100) | % |
///
/// Every one of them is older than the iOS 18.0 deployment target (State of
/// Mind is iOS 18.0, the rest iOS 9 to 16), so none needs an availability
/// gate or a shipped switch (rule 16 is about APIs newer than 18.0).
///
/// Nothing is asked for or sent before the configured server is known to
/// map them (``HealthKitServerTypeGate``: v1.44.0, or the server's own
/// `acceptedTypes` once it publishes one).
enum HealthKitServer144Types {
    /// The first server release whose batch route maps all six.
    static let minimumServerVersion = "1.44.0"

    static let exerciseTime = "HKQuantityTypeIdentifierAppleExerciseTime"
    static let standTime = "HKQuantityTypeIdentifierAppleStandTime"
    static let standHour = "HKCategoryTypeIdentifierAppleStandHour"
    static let mindfulSession = "HKCategoryTypeIdentifierMindfulSession"
    static let afibBurden = "HKQuantityTypeIdentifierAtrialFibrillationBurden"

    /// State of Mind as HealthKit names it at run time
    /// (`HKObjectType.stateOfMindType().identifier`). It is the registry and
    /// cursor key, and it differs from the header constant's name.
    static let stateOfMindRuntimeIdentifier = "HKDataTypeStateOfMind"

    /// State of Mind as the server maps it (`HKDataTypeIdentifierStateOfMind`,
    /// the header constant's name). The batch row must carry this spelling:
    /// the run-time identifier would come back as `unmappable_identifier`.
    static let stateOfMindWireIdentifier = "HKDataTypeIdentifierStateOfMind"

    /// The six, by their registry (run-time) identifier.
    static let registryIdentifiers: Set<String> = [
        exerciseTime, standTime, standHour, mindfulSession, stateOfMindRuntimeIdentifier, afibBurden
    ]

    /// The two summed quantity types that go the day-total way like steps.
    /// The server's hourly rows take only steps, energy, distance and floors
    /// (`intraday-hour-buckets.ts`), so these two have a day row and no hour row.
    static let cumulativeIdentifiers: Set<String> = [exerciseTime, standTime]

    /// The types a 1.4.1 installation has never been asked to read. State of
    /// Mind is not one: it has been in the first sheet since 16-03 (E2).
    static let lateReadIdentifiers: [String] = [exerciseTime, standTime, standHour, mindfulSession, afibBurden]

    /// REG (1.5, public #13) — the one table of types whose run-time
    /// identifier is not the name the server maps them under. The server
    /// keys `APPLE_HEALTH_TYPE_MAP` by the SDK constant's NAME and looks a row
    /// up by exactly that string (v1.47.0); any other spelling comes back as
    /// `unmappable_identifier`. The environmental audio exposure event kept
    /// the string of its pre-iOS-14 name, `…AudioExposureEvent`.
    /// POLISH-B B6: the table itself lives in `Models`
    /// (``HealthKitBatchEntryDTO/serverWireNames``), so the outbox replay and
    /// the skip register's re-offer translate parked rows with it too.
    static let wireNames: [String: String] = HealthKitBatchEntryDTO.serverWireNames

    /// The identifier a batch row carries for a registry (run-time)
    /// identifier: the same string except for the types in ``wireNames``.
    static func wireIdentifier(forRegistry identifier: String) -> String {
        wireNames[identifier] ?? identifier
    }

    /// The registry identifier for a batch row's identifier: the inverse of
    /// ``wireIdentifier(forRegistry:)``.
    static func registryIdentifier(forWire identifier: String) -> String {
        wireNames.first { $0.value == identifier }?.key ?? identifier
    }

    /// The six on their `MetricKind`, by registry identifier, for Sync
    /// Diagnostics (`HKSyncDiagnostics.identifierToKind`).
    static let metricKinds: [String: MetricKind] = [
        exerciseTime: .exerciseMinutes,
        standTime: .standMinutes,
        standHour: .standHours,
        mindfulSession: .mindfulMinutes,
        stateOfMindRuntimeIdentifier: .stateOfMindValence,
        afibBurden: .afibBurden
    ]

    #if canImport(HealthKit)
        /// The read type of a late-read identifier.
        static func readType(for identifier: String) -> HKObjectType? {
            if let quantity = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
                return quantity
            }
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        }

        /// The sample type for a registry identifier that is neither a quantity
        /// nor a category type: State of Mind. `nil` for anything else, so the
        /// resolver keeps refusing what it does not know.
        static func otherSampleType(for identifier: String) -> HKSampleType? {
            identifier == stateOfMindRuntimeIdentifier ? HKObjectType.stateOfMindType() : nil
        }
    #endif
}
