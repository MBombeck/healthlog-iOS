import Foundation

/// **1.5 LAB-LINES, from BP-TOD (#161, server #1331, v1.47.0)** — the
/// blood pressure chart narrowed to one part of the day.
///
/// `GET /api/measurements?type=…&aggregate=daily&source=rollup&from=…&to=…&partOfDay=…`
/// once for systolic and once for diastolic: one row per local day (a week
/// per row past a year), each the mean of that day's readings in the part, in
/// the record's own zone. The server decides which part a reading belongs to;
/// the app pairs the two rows of a day and draws them, nothing else.
///
/// A server that ignores `partOfDay` would answer the whole day under the
/// label of a part. The reply echoes `meta.partOfDay` when it narrowed, so a
/// reply without the echo is refused here (``PartOfDayNotNarrowed``) instead
/// of being drawn under the wrong name.
public extension MeasurementsRepository {
    func bloodPressureDailySeries(
        part: BloodPressureTimeOfDay.Part,
        from: Date,
        to: Date
    ) async throws -> [SeriesPoint]? {
        if isStandalone { return nil }
        async let systolic = partOfDayRows(type: "BLOOD_PRESSURE_SYS", part: part, from: from, to: to)
        async let diastolic = partOfDayRows(type: "BLOOD_PRESSURE_DIA", part: part, from: from, to: to)
        let (sys, dia) = try await (systolic, diastolic)
        guard sys.partOfDay == part.rawValue, dia.partOfDay == part.rawValue else {
            throw PartOfDayNotNarrowed()
        }
        return Self.pairedPoints(systolic: sys.rows, diastolic: dia.rows)
    }

    private func partOfDayRows(
        type: String,
        part: BloodPressureTimeOfDay.Part,
        from: Date,
        to: Date
    ) async throws -> PartOfDayRowsWire {
        let request: APIRequest<PartOfDayRowsWire> = .get(
            "/api/measurements",
            query: [
                ("type", type),
                ("aggregate", "daily"),
                ("source", "rollup"),
                ("from", ISO8601DateFormatter.plain.string(from: from)),
                ("to", ISO8601DateFormatter.plain.string(from: to)),
                ("partOfDay", part.rawValue),
                // The day cap; the default page of 100 would cut a half year.
                ("limit", "365")
            ]
        )
        return try await api.send(request)
    }

    /// Systolic and diastolic rows of the same bucket become one point. A
    /// bucket with only one of the two is not drawn: half a pair is not a
    /// blood pressure.
    nonisolated static func pairedPoints(systolic: [PartOfDayRowsWire.Row], diastolic: [PartOfDayRowsWire.Row]) -> [SeriesPoint] {
        let diastolicByBucket = Dictionary(diastolic.map { ($0.measuredAt, $0) }, uniquingKeysWith: { first, _ in first })
        return systolic.compactMap { row -> SeriesPoint? in
            guard let partner = diastolicByBucket[row.measuredAt] else { return nil }
            return SeriesPoint(
                id: "partOfDay-\(row.measuredAt.timeIntervalSince1970)",
                at: row.measuredAt,
                value: row.value,
                secondary: partner.value
            )
        }
        .sorted { $0.at < $1.at }
    }
}

/// The server answered the whole day where a part was asked for.
public struct PartOfDayNotNarrowed: Error, Equatable {}

/// The rows of one narrowed daily series and the echoed part.
public struct PartOfDayRowsWire: Decodable, Sendable {
    public struct Row: Decodable, Sendable, Equatable {
        public let value: Double
        public let measuredAt: Date
    }

    public let rows: [Row]
    /// `meta.partOfDay`, present only when the series was narrowed.
    public let partOfDay: String?

    public init(rows: [Row], partOfDay: String?) {
        self.rows = rows
        self.partOfDay = partOfDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = (try? container.decodeIfPresent([LossyRow].self, forKey: .measurements))?
            .compactMap(\.row)
            .filter(\.value.isFinite) ?? []
        let meta = try? container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        partOfDay = try? meta?.decodeIfPresent(String.self, forKey: .partOfDay)
    }

    private enum CodingKeys: String, CodingKey {
        case measurements, meta
    }

    private enum MetaKeys: String, CodingKey {
        case partOfDay
    }

    private struct LossyRow: Decodable {
        let row: Row?

        init(from decoder: Decoder) throws {
            row = try? Row(from: decoder)
        }
    }
}
