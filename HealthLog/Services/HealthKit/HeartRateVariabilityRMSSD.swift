import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// 1.2 / V4 (healthlog-iOS#14, HealthLog#1110, ios-dev#123 point 2): heart-rate
/// variability as RMSSD, which iOS and watchOS 27 add to HealthKit.
///
/// **Why a runtime identifier.** The app builds with Xcode 26.6 against the
/// iOS 26 SDK, which has no `HKQuantityTypeIdentifier.heartRateVariabilityRMSSD`
/// symbol. Apple documents the property as
/// `HKQuantityTypeIdentifier.heartRateVariabilityRMSSD`, precise symbol
/// `c:@HKQuantityTypeIdentifierHeartRateVariabilityRMSSD`, introduced in iOS,
/// iPadOS, Mac Catalyst, macOS, visionOS and watchOS 27.0
/// (developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd).
/// Like every HealthKit identifier constant, its raw value is the constant's
/// own name, which is also the string the server maps
/// (`apple-health-mapping.ts` on `release/v1.42.0`). The type is resolved at
/// run time and only on iOS 27 or later, so on older systems nothing changes:
/// no read request, no registry entry, no collection.
///
/// SDNN (`heartRateVariabilitySDNN`, server `HEART_RATE_VARIABILITY`) is a
/// different statistic and stays exactly as it is. RMSSD lands on the server's
/// `HRV_RMSSD`, the type WHOOP, Oura and Polar already write.
enum HeartRateVariabilityRMSSD {
    /// The raw HealthKit identifier the device reports and the batch carries.
    static let identifier = "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"

    /// The server measurement type the batch route stores it as (ms, 1 to
    /// 300, mean, privacy-sensitive). The client posts the HealthKit
    /// identifier; the server mapping turns it into this type.
    static let serverMeasurementType = "HRV_RMSSD"

    /// Wire unit, the same as SDNN.
    static let wireUnitSymbol = "ms"

    /// The first server release whose batch route maps the identifier. Older
    /// servers answer `skipped(unmappable_identifier)`.
    static let minimumServerVersion = "1.42.0"

    /// Whether the running system can know the type at all.
    static var isOSSupported: Bool {
        if #available(iOS 27, *) {
            return true
        }
        return false
    }

    #if canImport(HealthKit)
        /// The resolved quantity type, or `nil` before iOS 27 and wherever
        /// HealthKit does not know the identifier.
        static var sampleType: HKQuantityType? {
            resolve(osSupported: isOSSupported)
        }

        /// The resolution rule, split out so a test can pin both branches.
        static func resolve(
            osSupported: Bool,
            lookup: (HKQuantityTypeIdentifier) -> HKQuantityType? = { HKObjectType.quantityType(forIdentifier: $0) }
        ) -> HKQuantityType? {
            guard osSupported else { return nil }
            return lookup(HKQuantityTypeIdentifier(rawValue: identifier))
        }
    #endif
}

/// Which server-bound sample types the configured server can store yet.
///
/// A type the server does not map would be answered with
/// `skipped(unmappable_identifier)`. Nothing would be lost (the collector parks
/// such rows in the outbox), but every page would grow the queue and show up
/// as "waiting" in Sync Diagnostics for a server that simply predates the type.
/// So a type with a minimum server version is not collected at all until the
/// last answer of `GET /api/version` says the server is new enough. Its cursor
/// does not move meanwhile, so the first pass after the server upgrade walks
/// the same backfill window every other type started from.
///
/// The last-known version is a capability fact about a host, not health data,
/// and lives in `UserDefaults` like `MedicationSlotMaterializationGate`.
/// Unknown (never probed) counts as "not yet": fail closed, nothing is lost.
enum HealthKitServerTypeGate {
    /// The one stored server version (INT-N), shared with `syncTrigger: manual`.
    static let defaultsKey = KnownServerVersion.defaultsKey

    /// Identifier to the first server version that maps it.
    static let minimumServerVersionByIdentifier: [String: String] = [
        HeartRateVariabilityRMSSD.identifier: HeartRateVariabilityRMSSD.minimumServerVersion
    ]

    /// `true` when the configured server is known to store `identifier`.
    static func serverAccepts(_ identifier: String, defaults: UserDefaults = .standard) -> Bool {
        guard let minimum = minimumServerVersionByIdentifier[identifier] else { return true }
        return KnownServerVersion.isAtLeast(minimum, defaults: defaults)
    }

    /// Records the version a `GET /api/version` probe answered. INT-N: this is
    /// the app's only write of the server version; `SyncTriggerContext` reads
    /// the same record for `syncTrigger: manual`.
    static func record(_ info: ServerVersionInfo, defaults: UserDefaults = .standard) {
        KnownServerVersion.record(info, defaults: defaults)
    }

    /// The app was pointed at another server; the old answer says nothing.
    static func forget(defaults: UserDefaults = .standard) {
        KnownServerVersion.forget(defaults: defaults)
    }
}
