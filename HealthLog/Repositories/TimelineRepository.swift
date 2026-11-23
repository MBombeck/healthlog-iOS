import Foundation

/// The lab markers of
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
    /// The first server that ships `labSeries` and `availableLabs`.
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

    /// The first server with the timeline route (lanes and value series).
    public static let minimumTimelineServerVersion = "1.42.0"

    /// Whether the timeline page is offered: unless the server is known to
    /// be older than the route. An unknown version offers it: right after a
    /// sign-in the remembered version is gone (``KnownServerVersion`` forgets
    /// it with the server address) and the next probe only comes with the
    /// next foreground, so a fail-closed gate hid the sidebar entry, the More
    /// row and the Insights row of a freshly signed-in device (build 312 on
    /// the iPad). A server without the route answers 404, which the page
    /// shows as refused. The opt-in module is the page's own question, so
    /// the page can offer to switch it on.
    public nonisolated static func isTimelineAvailable(serverVersion: String?) -> Bool {
        guard let serverVersion else { return true }
        return ServerVersionInfo(version: serverVersion).isAtLeast(minimumTimelineServerVersion)
    }

    /// Reads the whole timeline over `zoom` (and, for `.range`, `from` and
    /// `to`) with the value lines named in `values`: measurement names,
    /// `MOOD`, `lab:<id>` and `symptom:<id>`. A malformed key is never sent.
    public func fetchTimeline(
        zoom: TimelineZoom,
        from: String? = nil,
        to: String? = nil,
        values: [String]
    ) async throws -> TimelineRead {
        var query: [(String, String)] = [("zoom", zoom.rawValue)]
        if zoom == .range, let from, let to {
            query.append(("from", from))
            query.append(("to", to))
        }
        let keys = Self.sendableValueKeys(values)
        query.append(("values", keys.joined(separator: ",")))
        let request: APIRequest<TimelineRead> = .get("/api/timeline", query: query)
        return try await api.send(request)
    }

    /// The keys a request may carry: a measurement name in capitals, `MOOD`,
    /// or a well-formed marker or symptom key, each once, in order.
    nonisolated static func sendableValueKeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { key in
            guard isMarkerKey(key) || isSymptomKey(key) || isMeasurementName(key) else { return false }
            return seen.insert(key).inserted
        }
    }

    nonisolated static func isSymptomKey(_ key: String) -> Bool {
        guard key.hasPrefix("symptom:") else { return false }
        return isWireId(key.dropFirst("symptom:".count))
    }

    nonisolated static func isMeasurementName(_ key: String) -> Bool {
        (1 ... 64).contains(key.count) && key.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 65 && scalar.value <= 90) || scalar == "_" || (scalar.value >= 48 && scalar.value <= 57)
        }
    }

    nonisolated static func isWireId(_ id: Substring) -> Bool {
        (1 ... 64).contains(id.count) && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
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
