#if DEBUG
    import Foundation

    /// **L1 (1.1.0) — Personal Records for the QA sweep.**
    ///
    /// The hermetic world answers no `GET /api/personal-records`, so a sweep of
    /// the records screen photographed an empty state — and the English-copy
    /// defects on that screen (German segments, metric names, streak and
    /// best-day labels, `de_DE` numbers) stayed invisible. Under
    /// `-uitest-sweep` this answers the records route with a handful of
    /// invented records, and the steps series with a month of daily totals so
    /// the client derives its best-day and streak records. No health value of
    /// any real person appears here. `nil` for every other route.
    enum SweepRecordFixtures {
        static func response(forPath path: String, query: [URLQueryItem]) -> (status: Int, body: Data)? {
            if path == "/api/personal-records" {
                return (200, Data(recordsJSON.utf8))
            }
            if path == "/api/measurements/series", query.first(where: { $0.name == "kind" })?.value == "steps" {
                return (200, Data(stepsSeriesJSON.utf8))
            }
            return nil
        }

        /// Day `offset` back from today, at 18:00 local.
        private static func day(_ offset: Int) -> Date {
            let evening = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
            return Calendar.current.date(byAdding: .day, value: -offset, to: evening) ?? evening
        }

        private static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private struct Record {
            let type: String
            let direction: String
            let value: Double
            let unit: String
            let daysAgo: Int
        }

        private static let records: [Record] = [
            Record(type: "WEIGHT", direction: "MIN", value: 71.8, unit: "kg", daysAgo: 3),
            Record(type: "RESTING_HR", direction: "MIN", value: 52, unit: "bpm", daysAgo: 12),
            Record(type: "HRV", direction: "MAX", value: 68, unit: "ms", daysAgo: 40),
            Record(type: "FLIGHTS_CLIMBED", direction: "MAX", value: 27, unit: "floors", daysAgo: 5),
            Record(type: "BODY_TEMPERATURE", direction: "MIN", value: 36.2, unit: "°C", daysAgo: 90),
            Record(type: "TIME_IN_DAYLIGHT", direction: "MAX", value: 184, unit: "min", daysAgo: 20)
        ]

        private static var recordsJSON: String {
            let rows = records.enumerated().map { index, record in
                let at = iso(day(record.daysAgo))
                return """
                {"id":"sweep-record-\(index)","userId":"hermetic-user","metricType":"\(record.type)",\
                "metricSlot":null,"direction":"\(record.direction)","value":\(record.value),"unit":"\(record.unit)",\
                "achievedAt":"\(at)","sourceMeasurementId":null,"source":"APPLE_HEALTH",\
                "externalId":null,"createdAt":"\(at)"}
                """
            }
            return "{\"data\":[\(rows.joined(separator: ","))],\"error\":null}"
        }

        /// Thirty daily step totals; the last twelve days clear 10,000 (a streak).
        private static var stepsSeriesJSON: String {
            let totals: [Double] = (0 ..< 30).map { offset in
                let wobble = Double((offset * 733) % 2400)
                return offset < 12 ? 10800 + wobble : 6200 + wobble
            }
            let points = (0 ..< 30).reversed().map { offset in
                """
                {"id":"sweep-steps-\(offset)","at":"\(iso(day(offset)))","value":\(totals[offset]),"secondary":null}
                """
            }
            let mean = totals.reduce(0, +) / Double(totals.count)
            return """
            {"kind":"steps","unit":"steps","points":[\(points.joined(separator: ","))],\
            "stats":{"mean":\(mean),"min":\(totals.min() ?? 0),"max":\(totals.max() ?? 0),\
            "stdDev":0,"count":\(totals.count)}}
            """
        }
    }
#endif
