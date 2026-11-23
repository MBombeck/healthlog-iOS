import Foundation

/// #181 (server 1.49.0, `measurement.reading-timezone`) — the IANA zone a
/// reading or a night was taken in, as the server hands it back: `timeZone` on
/// a measurement row, `main.timeZone` and `naps[].timeZone` on
/// `GET /api/sleep/night`.
///
/// The field is `null` (or absent on an older server) for every row read in
/// the profile zone, so its presence is the whole signal: the app shows a time
/// in that zone only when the server names one, and says so only when the zone
/// sits away from the device's own at that instant. A name the device does not
/// know reads as no zone at all.
public enum ReadingTimeZone {
    /// The zone `identifier` names, `nil` for `nil`, an empty string or a name
    /// this device cannot resolve.
    public static func zone(_ identifier: String?) -> TimeZone? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// Whether `zone` shows another clock than `device` at `date`. Two names
    /// with the same offset at that instant (Paris and Berlin) are not away.
    public static func isAway(_ zone: TimeZone, at date: Date, device: TimeZone = .current) -> Bool {
        zone.secondsFromGMT(for: date) != device.secondsFromGMT(for: date)
    }

    /// The zone to show `date` in, or `nil` when the device's own clock says
    /// the same: the named zone only when it sits away from the device's.
    public static func awayZone(_ identifier: String?, at date: Date, device: TimeZone = .current) -> TimeZone? {
        guard let zone = zone(identifier), isAway(zone, at: date, device: device) else { return nil }
        return zone
    }

    /// The place a zone is named after: "New York" for `America/New_York`,
    /// "Kolkata" for `Asia/Kolkata`. A name without a place (`UTC`) stays as
    /// it is.
    public static func placeName(_ zone: TimeZone) -> String {
        let last = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }
}
