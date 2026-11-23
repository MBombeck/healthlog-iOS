import Foundation

/// The whole answer of `GET /api/timeline` (server v1.42, `Timeline` in the
/// OpenAPI): the lanes of conditions, medications and the other dated
/// records, the value series by bucket, the lab markers and the person's own
/// symptoms, all over one window.
///
/// Every list is read row by row, so a row this build cannot read costs that
/// row and never the page. Every figure is the server's: a value point is the
/// server's bucket mean, a lab point one reading, nothing is recomputed here.
public struct TimelineRead: Decodable, Sendable, Equatable {
    public let zoom: TimelineZoom
    public let range: TimelineRange
    public let lanes: [TimelineLane]
    public let bucket: TimelineBucket
    public let series: [TimelineValueSeries]
    /// Every value series the record can show, whatever the window.
    public let availableSeries: [String]
    public let labSeries: [TimelineLabSeries]
    public let availableLabs: [TimelineLabMarker]
    public let symptomSeries: [TimelineSymptomSeries]
    public let availableSymptoms: [TimelineSymptomOption]

    public init(
        zoom: TimelineZoom,
        range: TimelineRange,
        lanes: [TimelineLane],
        bucket: TimelineBucket,
        series: [TimelineValueSeries],
        availableSeries: [String] = [],
        labSeries: [TimelineLabSeries] = [],
        availableLabs: [TimelineLabMarker] = [],
        symptomSeries: [TimelineSymptomSeries] = [],
        availableSymptoms: [TimelineSymptomOption] = []
    ) {
        self.zoom = zoom
        self.range = range
        self.lanes = lanes
        self.bucket = bucket
        self.series = series
        self.availableSeries = availableSeries
        self.labSeries = labSeries
        self.availableLabs = availableLabs
        self.symptomSeries = symptomSeries
        self.availableSymptoms = availableSymptoms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawZoom = try? container.decodeIfPresent(String.self, forKey: .zoom)
        zoom = rawZoom.flatMap(TimelineZoom.init(rawValue:)) ?? .range
        range = try container.decode(TimelineRange.self, forKey: .range)
        lanes = Self.list(container, .lanes)
        let rawBucket = try? container.decodeIfPresent(String.self, forKey: .bucket)
        bucket = rawBucket.flatMap(TimelineBucket.init(rawValue:)) ?? .month
        series = Self.list(container, .series)
        availableSeries = (try? container.decodeIfPresent([String].self, forKey: .availableSeries)) ?? []
        labSeries = Self.list(container, .labSeries)
        availableLabs = Self.list(container, .availableLabs)
        symptomSeries = Self.list(container, .symptomSeries)
        availableSymptoms = Self.list(container, .availableSymptoms)
    }

    /// A list read element by element; an element this build cannot read is left out.
    private static func list<Element: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [Element] {
        ((try? container.decodeIfPresent([TimelineLossy<Element>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    /// The items of `key`, or none when the lane was not sent (an empty lane never is).
    public func items(of key: TimelineLaneKey) -> [TimelineItem] {
        lanes.first { $0.key == key }?.items ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case zoom, range, lanes, bucket, series, availableSeries, labSeries, availableLabs
        case symptomSeries, availableSymptoms
    }
}

/// The zooms the server answers. `range` names its own window.
public enum TimelineZoom: String, Sendable, Equatable, CaseIterable {
    case all
    case year
    case quarter
    case range
}

/// The span one value point averages.
public enum TimelineBucket: String, Sendable, Equatable, CaseIterable {
    case quarter
    case month
    case week
    case day
}

/// The window the answer covers, local day keys (`YYYY-MM-DD`), both inclusive.
public struct TimelineRange: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    /// The earliest day anything in the record carries; `nil` for an empty record.
    public let dataFrom: String?

    public init(from: String, to: String, dataFrom: String?) {
        self.from = from
        self.to = to
        self.dataFrom = dataFrom
    }
}

/// The lanes, top to bottom, in the server's order.
public enum TimelineLaneKey: String, Sendable, Equatable, Hashable, CaseIterable {
    case life
    case illness
    /// The seizure diary (server v1.48.0): one point per day with seizures,
    /// shared under `illness`. Sent only while the `seizures` module is on.
    case seizures
    case allergies
    case medications
    case vaccinations
    case visits
    case labs
    case documents
    case cycle
}

/// One lane with the items that touch the window. A medication sends all of
/// its items when one of them touches it.
public struct TimelineLane: Decodable, Sendable, Equatable {
    public let key: TimelineLaneKey
    public let items: [TimelineItem]

    public init(key: TimelineLaneKey, items: [TimelineItem]) {
        self.key = key
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(TimelineLaneKey.self, forKey: .key)
        items = ((try? container.decodeIfPresent([TimelineLossy<TimelineItem>].self, forKey: .items)) ?? [])
            .compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case key, items
    }
}

extension TimelineLaneKey: Decodable {}

/// What one lane item is. A word this build does not know reads `.other`.
public enum TimelineItemKind: String, Sendable, Equatable {
    case lifeEvent
    case travel
    case episode
    case chronic
    case allergy
    case medication
    case course
    case doseChange
    case pause
    case vaccination
    case visit
    case procedure
    case labDay
    case document
    case cycle
    /// A day with seizures; `label` names its types, `sub` the count.
    case seizureDay
    case other
}

/// One entry of a lane (`TimelineItem`).
public struct TimelineItem: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: TimelineItemKind
    /// First day, `YYYY-MM-DD`.
    public let start: String
    /// Last day; `nil` for a point or an open span.
    public let end: String?
    /// A span that has not ended.
    public let open: Bool
    /// `false` when the start is a stand-in (a medication without a start date).
    public let startKnown: Bool
    public let label: String
    /// The dose for a medication or a dose change, a count for a lab day.
    public let sub: String?
    /// Items of one medication share it; `nil` for an item that stands alone.
    public let group: String?

    public init(
        id: String,
        kind: TimelineItemKind,
        start: String,
        end: String? = nil,
        open: Bool = false,
        startKnown: Bool = true,
        label: String,
        sub: String? = nil,
        group: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.open = open
        self.startKnown = startKnown
        self.label = label
        self.sub = sub
        self.group = group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawKind = try container.decode(String.self, forKey: .kind)
        kind = TimelineItemKind(rawValue: rawKind) ?? .other
        start = try container.decode(String.self, forKey: .start)
        end = try? container.decodeIfPresent(String.self, forKey: .end)
        open = (try? container.decodeIfPresent(Bool.self, forKey: .open)) ?? false
        startKnown = (try? container.decodeIfPresent(Bool.self, forKey: .startKnown)) ?? true
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? ""
        sub = try? container.decodeIfPresent(String.self, forKey: .sub)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
    }

    /// A span has an end or is still open; everything else is a point.
    public var isSpan: Bool {
        open || (end != nil && end != start)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, start, end, open, startKnown, label, sub, group
    }
}

/// One value series: a `MeasurementType` name or `MOOD` (`TimelineSeries`).
public struct TimelineValueSeries: Decodable, Sendable, Equatable {
    public let key: String
    public let unit: String?
    /// Buckets with at least one reading, oldest first. A missing bucket is absent.
    public let points: [TimelineValuePoint]

    public init(key: String, unit: String?, points: [TimelineValuePoint]) {
        self.key = key
        self.unit = unit
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        unit = try? container.decodeIfPresent(String.self, forKey: .unit)
        points = ((try? container.decodeIfPresent([TimelineLossy<TimelineValuePoint>].self, forKey: .points)) ?? [])
            .compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case key, unit, points
    }
}

/// One bucket mean.
public struct TimelineValuePoint: Codable, Sendable, Equatable {
    /// The bucket's first day.
    public let t: String
    public let mean: Double
    /// Readings (or logged days) behind the mean.
    public let count: Int
    /// ``t`` as a day number, read once: a zoom lays the points out many
    /// times a second and must not parse dates every time.
    public let day: Int?

    public init(t: String, mean: Double, count: Int) {
        self.t = t
        self.mean = mean
        self.count = count
        day = TimelineDay.number(t)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            t: container.decode(String.self, forKey: .t),
            mean: container.decode(Double.self, forKey: .mean),
            count: container.decode(Int.self, forKey: .count)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(mean, forKey: .mean)
        try container.encode(count, forKey: .count)
    }

    private enum CodingKeys: String, CodingKey {
        case t, mean, count
    }
}

/// A person-defined symptom's line on the intensity scale 0 to 10 (server 1.47.1).
public struct TimelineSymptomSeries: Decodable, Sendable, Equatable {
    /// `symptom:<definitionId>`.
    public let key: String
    public let definitionId: String
    /// The person's own name; `nil` when it cannot be read.
    public let label: String?
    public let isActive: Bool
    public let points: [TimelineValuePoint]

    public init(key: String, definitionId: String, label: String?, isActive: Bool = true, points: [TimelineValuePoint]) {
        self.key = key
        self.definitionId = definitionId
        self.label = label
        self.isActive = isActive
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        definitionId = try container.decode(String.self, forKey: .definitionId)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        isActive = (try? container.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true
        points = ((try? container.decodeIfPresent([TimelineLossy<TimelineValuePoint>].self, forKey: .points)) ?? [])
            .compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case key, definitionId, label, isActive, points
    }
}

/// A symptom the record has logged at least once, to choose as a line.
public struct TimelineSymptomOption: Codable, Sendable, Equatable, Hashable {
    public let key: String
    public let definitionId: String
    public let label: String?
    public let isActive: Bool

    public init(key: String, definitionId: String, label: String?, isActive: Bool) {
        self.key = key
        self.definitionId = definitionId
        self.label = label
        self.isActive = isActive
    }
}

/// Decodes one element of a list and keeps going when it cannot.
private struct TimelineLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
