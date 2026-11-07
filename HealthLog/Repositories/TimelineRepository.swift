import Foundation

/// **1.5 LAB-LINES (#158, server #1299)** — the lab markers of
/// `GET /api/timeline` for the metric chart.
///
/// A thin read-only `actor` like ``BloodPressureTimeOfDayRepository``: no
/// outbox, no disk cache. The route needs the opt-in `timeline` module and
/// answers `403 module.disabled` without it; a shared record whose grant does
/// not reach the timeline is refused locally by `APIClient` (the path is not
/// mapped to a section), so a delegate never sends the read.
///
/// The window is always `zoom=range` with the chart's own dates: lab points
/// are single readings whatever the zoom, and `range` is the one zoom that
/// takes the chart's window as it is.
public actor TimelineRepository {
    /// The first server that ships `labSeries` and `availableLabs` (#1299).
    public static let minimumServerVersion = "1.46.3"
    /// The server keeps `from` and `to` at most 15 years apart.
    public static let maximumWindowDays = 15 * 365

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Reads the markers the record has and, when `markerKey` is given, that
    /// marker's readings between `from` and `to` (local calendar days,
    /// `YYYY-MM-DD`, both inclusive).
    public func fetchLabs(from: String, to: String, markerKey: String?) async throws -> TimelineLabRead {
        var query: [(String, String)] = [("zoom", "range"), ("from", from), ("to", to)]
        if let markerKey, Self.isMarkerKey(markerKey) {
            query.append(("values", markerKey))
        }
        let request: APIRequest<TimelineLabRead> = .get("/api/timeline", query: query)
        return try await api.send(request)
    }

    /// `lab:<id>` with an id of `[A-Za-z0-9_-]{1,64}`. Anything else would
    /// answer 422 (`timeline.invalid`), so it is never sent.
    nonisolated static func isMarkerKey(_ key: String) -> Bool {
        guard key.hasPrefix("lab:") else { return false }
        let id = key.dropFirst(4)
        return (1 ... 64).contains(id.count) && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    /// `YYYY-MM-DD` of `date` in `calendar` (the device's, like the chart).
    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Midday of a `YYYY-MM-DD` day in `calendar`, or `nil` for anything else.
    /// Midday keeps a day key on its own day in every zone the chart draws in.
    nonisolated static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
