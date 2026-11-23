import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// The time zone a reading was taken in, for `timeZone` on a measurement
/// batch row (#181).
///
/// HealthKit keeps the zone in `HKMetadataKeyTimeZone` when the writing app
/// recorded one (the Watch and the Health app do for sleep and workouts). A
/// sample without it gets the device's zone at read time only while it is
/// young (``deviceFallbackWindow``): where the person is now is, for the live
/// window, almost always where they were. An older sample without a zone (a
/// first import, a backfill of years) carries none, and the server uses the
/// profile zone, rather than every past reading moving to today's zone.
///
/// Sent only while `GET /api/version` lists the capability
/// `measurement.reading-timezone` (server 1.49.0, #191): an older server
/// validates the row strictly and would refuse the unknown key. The server
/// takes an IANA name of 1 to 64 characters and refuses an abbreviation or
/// an offset, so only a name from the system's IANA list goes out; anything
/// else leaves the field off and the server uses the profile zone. A `stats:`
/// day total carries the zone its day was summed in.
enum HealthKitReadingTimeZone {
    static let capability = "measurement.reading-timezone"

    /// `raw` when it is a full IANA name the server takes, else `nil`.
    static func validated(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), (1 ... 64).contains(raw.count),
              raw.contains("/") || raw == "UTC",
              TimeZone.knownTimeZoneIdentifiers.contains(raw) else { return nil }
        return raw
    }

    /// How old a reading may be and still take the device's zone.
    static let deviceFallbackWindow: TimeInterval = 48 * 3600

    /// The zone `metadata` names when it is a valid IANA name, otherwise
    /// `fallback`'s when that is one, otherwise `nil`.
    static func identifier(metadataValue: Any?, fallback: TimeZone = .current) -> String? {
        validated(metadataValue as? String) ?? validated(fallback.identifier)
    }

    /// The same, but the device's zone stands in only for a reading that
    /// ended within ``deviceFallbackWindow`` of `now`.
    static func identifier(metadataValue: Any?, readingEnd: Date, now: Date, fallback: TimeZone = .current) -> String? {
        if let named = validated(metadataValue as? String) { return named }
        guard now.timeIntervalSince(readingEnd) <= deviceFallbackWindow else { return nil }
        return validated(fallback.identifier)
    }

    /// Whether rows carry the zone now.
    static func isSent(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.hasCapability(capability, defaults: defaults)
    }

    /// A `stats:` day-total row with the zone its day was summed in.
    static func stamp(_ entry: HealthKitBatchEntryDTO, dayZone: String?, defaults: UserDefaults = .standard) -> HealthKitBatchEntryDTO {
        guard isSent(defaults: defaults), let zone = validated(dayZone) else { return entry }
        return entry.withTimeZone(zone)
    }

    #if canImport(HealthKit)
        /// `entries`, each with the zone of `sample`, or unchanged while the
        /// server does not take the field.
        static func stamp(
            _ entries: [HealthKitBatchEntryDTO],
            from sample: HKSample,
            defaults: UserDefaults = .standard,
            fallback: TimeZone = .current,
            now: Date = .now
        ) -> [HealthKitBatchEntryDTO] {
            guard !entries.isEmpty, isSent(defaults: defaults) else { return entries }
            guard let zone = identifier(
                metadataValue: sample.metadata?[HKMetadataKeyTimeZone],
                readingEnd: sample.endDate,
                now: now,
                fallback: fallback
            ) else {
                return entries
            }
            return entries.map { $0.withTimeZone(zone) }
        }

        static func stamp(
            _ entry: HealthKitBatchEntryDTO?,
            from sample: HKSample,
            defaults: UserDefaults = .standard
        ) -> HealthKitBatchEntryDTO? {
            guard let entry else { return nil }
            return stamp([entry], from: sample, defaults: defaults).first
        }
    #endif
}
