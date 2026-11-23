import Foundation

/// The server's daily pulse for the doctor report.
public extension MeasurementsRepository {
    /// `GET /api/measurements/series-batch?types=PULSE&from=…&to=…`: one row
    /// per local day (server v1.40.1: the mean of the day's hour means; count,
    /// min and max over every reading). Network-direct, user-initiated (the
    /// report is generated on a tap).
    func dailyPulse(from: Date, to: Date) async throws -> [DailyPulseValue]? {
        let req: APIRequest<SeriesBatchPulseWire> = .get(
            "/api/measurements/series-batch",
            query: [
                ("types", "PULSE"),
                ("from", ISO8601DateFormatter.plain.string(from: from)),
                ("to", ISO8601DateFormatter.plain.string(from: to))
            ]
        )
        return try await api.send(req).days
    }
}

/// Wire shape of `MeasurementsSeriesBatchResponse`, PULSE only. Lossy per row:
/// a row this build cannot read is dropped, never guessed.
struct SeriesBatchPulseWire: Decodable, Sendable {
    let days: [DailyPulseValue]

    private enum CodingKeys: String, CodingKey {
        case series
    }

    private enum SeriesKeys: String, CodingKey {
        case pulse = "PULSE"
    }

    private struct Row: Decodable {
        let value: DailyPulseValue?

        private enum CodingKeys: String, CodingKey {
            case value, measuredAt, count, minValue, maxValue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let mean = try? c.decode(Double.self, forKey: .value),
                  let day = try? c.decode(Date.self, forKey: .measuredAt) else
            {
                value = nil
                return
            }
            value = DailyPulseValue(
                day: day,
                mean: mean,
                count: (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0,
                min: try? c.decodeIfPresent(Double.self, forKey: .minValue),
                max: try? c.decodeIfPresent(Double.self, forKey: .maxValue)
            )
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let series = try c.nestedContainer(keyedBy: SeriesKeys.self, forKey: .series)
        let rows = (try? series.decodeIfPresent([Row].self, forKey: .pulse)) ?? []
        days = rows.compactMap(\.value)
    }
}
