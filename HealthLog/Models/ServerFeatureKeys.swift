import Foundation

/// #191 — the capability keys of `GET /api/version` `features` that are not
/// part of the medication contract (``MedicationCapability`` keeps those in
/// the App Group for the extensions). These are read by the app alone.
///
/// A key is present or absent; an answer without `features` is a server
/// before 1.49.0 and opens nothing. Unknown (never probed) is closed.
public enum ServerFeatureKey: String, CaseIterable, Sendable {
    /// `doseOffset` on `GET /api/symptoms/events` and on day events.
    case dayDoseOffset = "day.dose-offset"
}

/// Where the app keeps the non-medication keys of the last `/api/version`
/// answer: one newline-joined string in the standard defaults, so a view can
/// observe it with `@AppStorage(ServerFeatureKeys.defaultsKey)`.
public enum ServerFeatureKeys {
    public static let defaultsKey = "hl.server.featureKeys"

    /// Replaces the remembered keys with the known ones among `features`.
    public static func record(_ features: [String], defaults: UserDefaults = .standard) {
        defaults.set(joined(features), forKey: defaultsKey)
    }

    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    public static func isOpen(_ key: ServerFeatureKey, defaults: UserDefaults = .standard) -> Bool {
        isOpen(key, in: defaults.string(forKey: defaultsKey))
    }

    /// Whether `key` is in a stored list (the `@AppStorage` value).
    public static func isOpen(_ key: ServerFeatureKey, in stored: String?) -> Bool {
        guard let stored else { return false }
        return stored.split(separator: "\n").contains { $0 == key.rawValue }
    }

    /// The known keys among `features`, sorted and newline-joined.
    static func joined(_ features: [String]) -> String {
        let known = Set(features.compactMap(ServerFeatureKey.init(rawValue:))).map(\.rawValue)
        return known.sorted().joined(separator: "\n")
    }
}
