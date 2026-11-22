import Foundation

/// #181 (server 1.49.0, `measurement.reading-timezone`) — the reading's own
/// IANA zone on a stored measurement row.
///
/// The column is `null` for every reading read in the profile zone (every row
/// written before 1.49.0, every writer that sends none), and an older server
/// has no key at all. Both read as `nil`; so does a malformed value, which
/// never costs the row.
extension MeasurementWireDTO {
    private enum ReadingZoneKey: String, CodingKey {
        case timeZone
    }

    /// `timeZone` when the row carries a non-empty string, else `nil`.
    static func decodeReadingZone(from decoder: Decoder) -> String? {
        guard let row = try? decoder.container(keyedBy: ReadingZoneKey.self) else { return nil }
        // `try?` flattens `String??`: `null` or a non-string both land on `nil`.
        guard let zone = try? row.decodeIfPresent(String.self, forKey: .timeZone), !zone.isEmpty else {
            return nil
        }
        return zone
    }
}
