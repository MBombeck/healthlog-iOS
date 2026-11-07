import Foundation

/// HK-NEW (1.5) — the server's own list of HealthKit types its batch route
/// maps, as `acceptedTypes: string[]` on `GET /api/integrations/healthkit`
/// (requested in HealthLog#1340, not in any release yet).
///
/// Rule 10: the field is optional. While a server does not send it, the app's
/// own table decides (``HealthKitServerTypeGate``: a minimum version per
/// type, every other type accepted, the deferred ones below never). Once a
/// server sends it, a type is collected and asked for only when it is in the
/// list **and** the app can read it, so the server can close a type again
/// without a new build, and a deferred type it opens is still left alone
/// until a build knows its wire form.
///
/// The last answer is a capability fact about the configured host, not health
/// data, so it lives in `UserDefaults` beside the server version and is
/// forgotten with it when the app is pointed at another server.
enum HealthKitAcceptedTypes {
    static let defaultsKey = "hl.healthkit.acceptedTypes"

    /// Records the field as the last GET carried it: `nil` (absent) removes
    /// the record, so an older server falls back to the table.
    static func record(_ types: [String]?, defaults: UserDefaults = .standard) {
        if let types {
            defaults.set(types.sorted(), forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The recorded list, or `nil` when the server never sent one.
    static func recorded(defaults: UserDefaults = .standard) -> Set<String>? {
        defaults.stringArray(forKey: defaultsKey).map(Set.init)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Records the field of a config **the server just sent** and hands the
    /// config on. Only for a network answer: the SWR cache keeps the encoded
    /// form, which never carries the field, so a cached config says nothing.
    static func recording(_ config: HealthKitSyncConfig, defaults: UserDefaults = .standard) -> HealthKitSyncConfig {
        record(config.acceptedTypes, defaults: defaults)
        return config
    }

    /// The types the server holds back (`HK_QUANTITY_TYPE_DEFERRED`, v1.47.0)
    /// that the app would otherwise have a reason to read. They stay in this
    /// table as "not accepted": never asked for, never collected, whatever the
    /// version. Height belongs to the profile, dietary energy, macros and
    /// sodium stay closed, water and caffeine go through
    /// `POST /api/nutrients/batch` (the nutrient sync, not this path). Basal
    /// energy is the one without a decision (HealthLog#1340).
    static let deferredIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierHeight",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "HKQuantityTypeIdentifierDietaryProtein",
        "HKQuantityTypeIdentifierDietaryCarbohydrates",
        "HKQuantityTypeIdentifierDietaryFatTotal",
        "HKQuantityTypeIdentifierDietarySodium",
        "HKQuantityTypeIdentifierDietaryWater",
        "HKQuantityTypeIdentifierDietaryCaffeine"
    ]
}
