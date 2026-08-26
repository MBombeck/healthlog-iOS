import Foundation

/// Tiny shared formatter for the labs surface. The wire `takenAt` / `createdAt`
/// are ISO-8601 strings (`LabsDTO` keeps them raw to avoid coupling decode to a
/// `Date` strategy). These helpers parse + present them; a malformed string
/// degrades to the raw value rather than crashing. Parsing reuses the app's
/// shared `ISO8601DateFormatter.fractional` / `.plain` (declared in
/// `APIClient.swift`) so there's exactly one formatter pair.
enum LabsDateFormat {
    /// Parse an ISO-8601 wire string (with or without fractional seconds).
    static func parse(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    /// Medium date (e.g. "17 Jun 2026"). Falls back to the raw string. Routes
    /// through ``HLDateFormat`` so the field order honours the user's
    /// server-backed date-format preference (A360-1 H1).
    static func mediumDate(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    /// Medium date + short time (e.g. "17 Jun 2026, 08:30"). Falls back to raw.
    /// Routes the date through ``HLDateFormat`` (preference-aware field order).
    static func mediumDateTime(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.dateTime(date, style: .abbreviated)
    }
}
