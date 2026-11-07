import Foundation

/// **1.5 LAB-LINES (#158, server #1299, v1.46.3)** — the lab part of
/// `GET /api/timeline`: the markers the record can draw (`availableLabs`) and
/// the readings of the one marker the metric page shows (`labSeries`).
///
/// The rest of the timeline (lanes, standing items, value series) is not read:
/// the app does not rebuild the timeline, it hangs one marker under a metric
/// chart. Both lists are read row by row, so one row this build cannot read
/// costs that row and never the chart. Every figure is the server's: a point
/// is one reading, never averaged, and its verdict is `rangeStatus` as sent.
public struct TimelineLabRead: Decodable, Sendable, Equatable {
    public let availableLabs: [TimelineLabMarker]
    public let labSeries: [TimelineLabSeries]

    public init(availableLabs: [TimelineLabMarker], labSeries: [TimelineLabSeries]) {
        self.availableLabs = availableLabs
        self.labSeries = labSeries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableLabs = (try? container.decodeIfPresent([Lossy<TimelineLabMarker>].self, forKey: .availableLabs))?
            .compactMap(\.value) ?? []
        labSeries = (try? container.decodeIfPresent([Lossy<TimelineLabSeries>].self, forKey: .labSeries))?
            .compactMap(\.value) ?? []
    }

    /// The series of `key`, or `nil` when the record does not have it (a
    /// deleted marker, another record's id): the page then shows nothing.
    public func series(for key: String) -> TimelineLabSeries? {
        labSeries.first { $0.key == key }
    }

    private enum CodingKeys: String, CodingKey {
        case availableLabs, labSeries
    }
}

/// One marker the record has a numeric reading for (`TimelineLabMarker`).
public struct TimelineLabMarker: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// `lab:<biomarkerId>`, the name the marker goes by in `values`.
    public let key: String
    public let biomarkerId: String
    public let name: String
    /// The marker's group as the labs list shows it; `nil` sorts under "Other".
    public let panel: String?
    public let unit: String

    public var id: String {
        key
    }

    public init(key: String, biomarkerId: String, name: String, panel: String?, unit: String) {
        self.key = key
        self.biomarkerId = biomarkerId
        self.name = name
        self.panel = panel
        self.unit = unit
    }
}

/// The readings of one marker in the window (`TimelineLabSeries`).
public struct TimelineLabSeries: Decodable, Sendable, Equatable {
    public let key: String
    public let biomarkerId: String
    public let name: String
    public let panel: String?
    /// Every point is in this unit.
    public let unit: String
    /// The reference range drawn behind the points; `nil` when none is known.
    public let band: TimelineLabBand?
    /// Oldest first, one point per reading. Two readings on one day are two points.
    public let points: [TimelineLabPoint]
    /// Readings in a unit that does not convert into ``unit``: left out of
    /// ``points`` by the server and named in one line under the chart.
    public let excluded: Int

    public init(
        key: String,
        biomarkerId: String,
        name: String,
        panel: String?,
        unit: String,
        band: TimelineLabBand?,
        points: [TimelineLabPoint],
        excluded: Int
    ) {
        self.key = key
        self.biomarkerId = biomarkerId
        self.name = name
        self.panel = panel
        self.unit = unit
        self.band = band
        self.points = points
        self.excluded = excluded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        biomarkerId = try container.decode(String.self, forKey: .biomarkerId)
        name = try container.decode(String.self, forKey: .name)
        panel = try container.decodeIfPresent(String.self, forKey: .panel)
        unit = try container.decode(String.self, forKey: .unit)
        band = try? container.decodeIfPresent(TimelineLabBand.self, forKey: .band)
        points = (try? container.decodeIfPresent([Lossy<TimelineLabPoint>].self, forKey: .points))?
            .compactMap(\.value) ?? []
        excluded = (try? container.decodeIfPresent(Int.self, forKey: .excluded)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case key, biomarkerId, name, panel, unit, band, points, excluded
    }
}

/// The reference range behind a marker's points. Either edge may be open.
public struct TimelineLabBand: Codable, Sendable, Equatable {
    public let low: Double?
    public let high: Double?

    public init(low: Double?, high: Double?) {
        self.low = low
        self.high = high
    }

    /// A band with neither edge draws nothing.
    public var isEmpty: Bool {
        low == nil && high == nil
    }
}

/// One reading of a marker (`TimelineLabPoint`).
public struct TimelineLabPoint: Decodable, Sendable, Equatable, Identifiable {
    /// The lab result's id.
    public let id: String
    /// The record's local day of the draw, `YYYY-MM-DD`.
    public let date: String
    /// In the series' unit.
    public let value: Double
    /// The figure the report printed when ``value`` was converted; it sets the
    /// precision ``value`` is shown with.
    public let sourceValue: Double?
    /// The server's verdict against the reading's own range, read and never
    /// derived; a word this build does not know is `.unknown`.
    public let rangeStatus: LabRangeStatus
    public let referenceLow: Double?
    public let referenceHigh: Double?
    /// The document the reading was read from; `nil` without one or without
    /// the right to see documents (then no link).
    public let report: TimelineLabReport?

    public init(
        id: String,
        date: String,
        value: Double,
        sourceValue: Double? = nil,
        rangeStatus: LabRangeStatus,
        referenceLow: Double? = nil,
        referenceHigh: Double? = nil,
        report: TimelineLabReport? = nil
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.sourceValue = sourceValue
        self.rangeStatus = rangeStatus
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.report = report
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(String.self, forKey: .date)
        value = try container.decode(Double.self, forKey: .value)
        sourceValue = try? container.decodeIfPresent(Double.self, forKey: .sourceValue)
        let status = try? container.decodeIfPresent(String.self, forKey: .rangeStatus)
        rangeStatus = status.flatMap(LabRangeStatus.init(rawValue:)) ?? .unknown
        referenceLow = try? container.decodeIfPresent(Double.self, forKey: .referenceLow)
        referenceHigh = try? container.decodeIfPresent(Double.self, forKey: .referenceHigh)
        report = try? container.decodeIfPresent(TimelineLabReport.self, forKey: .report)
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, value, sourceValue, rangeStatus, referenceLow, referenceHigh, report
    }
}

/// The document a reading came from.
public struct TimelineLabReport: Codable, Sendable, Equatable {
    public let id: String
    /// The document's title, else its file name; may be `nil`.
    public let title: String?

    public init(id: String, title: String?) {
        self.id = id
        self.title = title
    }
}

/// Decodes one element of a list and keeps going when it cannot: the cursor
/// always moves on, an unreadable element is `nil`.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
