import Foundation

/// User/profile-timezone calendar-day discriminator for the medication
/// today-intakes cache key (v0.14.1 INV-med-cadence-phantom, BUG 2).
///
/// The medication "today" window — `derivedTodayIntakes`'
/// `[startOfToday, endOfToday)` and the compliance "today" bucket — is computed
/// in the **server-profile IANA timezone** (`MedicationsStore.profileTimeZone`,
/// NOT the device TZ; see `MedicationsStore+DerivedIntakes`). The today-intakes
/// SWR cache key must roll over on the SAME boundary, otherwise a `.taken`
/// snapshot persisted on day N can be SWR-served (via the `.cached` arm) on day
/// N+1 and render a phantom "taken today" the server no longer agrees with.
///
/// This mirrors the Insights `BerlinDayKey` pattern (a `yyyy-MM-dd` string baked
/// into the cache key so the previous day's row structurally misses on the next
/// read) but anchors on the *medication-consistent* zone rather than a hardcoded
/// Europe/Berlin, so the rollover lines up with the medication "today" the rest
/// of the store already computes.
///
/// Pure value, no actor isolation — computed on the call-site thread from a
/// deterministic `Date` + the passed `TimeZone`, trivially `Sendable`.
public enum MedicationDayKey {
    private static func formatter(for timeZone: TimeZone) -> DateFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// `yyyy-MM-dd` for `date` in `timeZone`. Stable for any instant within the
    /// same calendar day in that zone; flips at local midnight of that zone.
    public static func string(for date: Date = .now, timeZone: TimeZone) -> String {
        formatter(for: timeZone).string(from: date)
    }
}
