#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// **1.4 B3** `-uitest-recovery` — the recovery overlay. Only
        /// `MarketingScreenshotsTest.test_capture_recovery_pages` passes it,
        /// together with `-uitest-marketing`, so the App Store motifs keep the
        /// world they were captured in.
        static let recoveryOverlayArgument = "-uitest-recovery"

        static var isRecoveryOverlayActive: Bool {
            ProcessInfo.processInfo.arguments.contains(recoveryOverlayArgument)
        }

        /// #162 `-uitest-garmin` — adds Garmin's four types to the recovery
        /// overlay. Only `MarketingScreenshotsTest.test_capture_garmin_recovery`
        /// passes it, so the App Store motifs stay as they were captured.
        static let garminOverlayArgument = "-uitest-garmin"

        static var isGarminOverlayActive: Bool {
            ProcessInfo.processInfo.arguments.contains(garminOverlayArgument)
        }
    }

    /// **1.4 B3 — a wearable account for the recovery and HRV pages.**
    ///
    /// The shared hermetic world serves no measurements, so the recovery page
    /// could only ever photograph its empty note. This overlay answers the
    /// three reads those pages make (the summaries slice, the per-type list,
    /// the series) with the shape of a WHOOP account: daily recovery, day
    /// strain, heart rate and energy for the last 45 days, RMSSD daily, an SDNN
    /// series that stopped about four and a half months ago, and four cardio
    /// recovery readings from 2024. Values are invented and deliberately
    /// unremarkable; no health value of any real person appears here.
    ///
    /// Dates follow the simulator clock, so "today" is the capture day. The
    /// summaries are worked out here the way the server would report them
    /// (`latest`, `mean`, `avg30` over the last 30 days, `null` without a
    /// reading in that window), since this table stands in for the server.
    /// `nil` for every other route, so the marketing and shared tables answer
    /// unchanged.
    enum RecoveryFixtures {
        private struct Series: Sendable {
            let type: String
            let unit: String
            /// Apple Health for the watch's own readings, WHOOP for the rest.
            var source = "WHOOP"
            /// Day offsets back from today that carry a reading.
            let offsets: [Int]
            let value: @Sendable (Int) -> Double
            /// Fixed dates instead of offsets (the 2024 cardio recovery).
            var dates: [Date]?
        }

        private static let recent = Array(0 ..< 45)

        private static var series: [Series] {
            HermeticUITestSupport.isGarminOverlayActive ? baseSeries + garminSeries : baseSeries
        }

        /// #162 — Body Battery and stress level as Garmin writes them, the
        /// readiness and the acute load as a bridge writes them (`EXTERNAL`).
        private static let garminSeries: [Series] = [
            Series(type: "BODY_BATTERY", unit: "score", source: "GARMIN", offsets: recent) { offset in
                offset == 0 ? 78 : (70 + wave(offset, 12, 0.57, 6, 1.9)).rounded()
            },
            Series(type: "STRESS_LEVEL", unit: "score", source: "GARMIN", offsets: recent) { offset in
                offset == 0 ? 29 : (31 + wave(offset, 7, 0.71, 4, 2.2)).rounded()
            },
            Series(type: "TRAINING_READINESS", unit: "score", source: "EXTERNAL", offsets: recent) { offset in
                offset == 0 ? 71 : (64 + wave(offset, 13, 0.49, 6, 1.7)).rounded()
            },
            Series(type: "ACUTE_TRAINING_LOAD", unit: "load", source: "EXTERNAL", offsets: recent) { offset in
                offset == 0 ? 412 : (420 + wave(offset, 60, 0.33, 25, 1.4)).rounded()
            }
        ]

        private static let baseSeries: [Series] = [
            Series(type: "RECOVERY_SCORE", unit: "score", offsets: recent) { offset in
                // Ends on the derived batch's RECOVERY_SCORE (83), so the card
                // and the score detail behind it agree.
                offset == 0 ? 83 : (68 + wave(offset, 11, 0.61, 6, 1.73)).rounded()
            },
            Series(type: "DAY_STRAIN", unit: "score", offsets: recent) { offset in
                offset == 0 ? 12.4 : ((11.5 + wave(offset, 2.8, 0.83, 1.6, 2.1)) * 10).rounded() / 10
            },
            Series(type: "AVERAGE_HEART_RATE", unit: "bpm", offsets: recent) { offset in
                offset == 0 ? 64 : (64 + wave(offset, 2, 0.6, 1.5, 1.9)).rounded()
            },
            Series(type: "MAX_HEART_RATE", unit: "bpm", offsets: recent) { offset in
                offset == 0 ? 152 : (152 + wave(offset, 10, 0.9, 7, 2.3)).rounded()
            },
            Series(type: "ENERGY_EXPENDITURE_KJ", unit: "kJ", offsets: recent) { offset in
                offset == 0 ? 10200 : ((10200 + wave(offset, 900, 0.7, 600, 1.9)) / 10).rounded() * 10
            },
            Series(type: "HRV_RMSSD", unit: "ms", offsets: recent) { offset in
                offset == 0 ? 52 : ((52 + wave(offset, 5, 0.5, 3, 1.6)) * 10).rounded() / 10
            },
            Series(type: "HEART_RATE_VARIABILITY", unit: "ms", source: "APPLE_HEALTH", offsets: Array(138 ..< 200)) { offset in
                ((47 + 6 * sin(Double(offset) * 0.4)) * 10).rounded() / 10
            },
            Series(
                type: "CARDIO_RECOVERY", unit: "bpm", source: "APPLE_HEALTH", offsets: [],
                value: { index in [27, 31, 29, 28][index % 4] },
                dates: ["2024-08-02", "2024-08-07", "2024-08-14", "2024-08-20"].compactMap(fixedDate)
            )
        ]

        /// Two overlaid waves, so a line reads like a person's month rather
        /// than a test signal. Deterministic: the same day draws the same chart.
        private static func wave(_ offset: Int, _ slow: Double, _ slowRate: Double, _ fast: Double, _ fastRate: Double) -> Double {
            slow * sin(Double(offset) * slowRate) + fast * sin(Double(offset) * fastRate + 0.6)
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            func value(_ name: String) -> String? {
                query.first { $0.name == name }?.value
            }
            if path == "/api/analytics", value("slice") == "summaries" { return ok(summariesJSON) }
            if path == "/api/insights/layout" { return ok(layoutJSON) }
            if path == "/api/measurements", let type = value("type"),
               let entry = series.first(where: { $0.type == type })
            {
                return ok(listJSON(entry))
            }
            if path == "/api/measurements/series", value("kind") == "heartRateVariability",
               let entry = series.first(where: { $0.type == "HEART_RATE_VARIABILITY" })
            {
                return ok(seriesJSON(entry, days: Int(value("days") ?? "") ?? 30))
            }
            return nil
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The strip for these pages: the recovery page and the HRV page, which
        /// the bootstrap layout keeps hidden.
        private static let layoutJSON: String = {
            let ids = ["overview", "recovery", "hrv", "cardio-recovery", "medications", "mood", "workouts"]
            let tiles = ids.enumerated().map { "{\"id\":\"\($1)\",\"visible\":true,\"order\":\($0)}" }
            return "{\"version\":2,\"tiles\":[\(tiles.joined(separator: ","))]}"
        }()

        // MARK: - Readings

        private struct Reading {
            let at: Date
            let value: Double
        }

        /// Newest first, the order the list route answers in.
        private static func readings(_ entry: Series) -> [Reading] {
            if let dates = entry.dates {
                return dates.enumerated().map { Reading(at: $1, value: entry.value($0)) }.reversed()
            }
            return entry.offsets.map { Reading(at: day($0), value: entry.value($0)) }
        }

        /// Day `offset` back from today, at 07:30 local.
        private static func day(_ offset: Int) -> Date {
            let morning = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: .now) ?? .now
            return Calendar.current.date(byAdding: .day, value: -offset, to: morning) ?? morning
        }

        private static func fixedDate(_ day: String) -> Date? {
            ISO8601DateFormatter().date(from: "\(day)T07:30:00Z")
        }

        private static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        // MARK: - Summaries slice

        private static var summariesJSON: String {
            let windowStart = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
            let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
            let entries = series.map { entry -> String in
                let rows = readings(entry)
                let values = rows.map(\.value)
                let month = rows.filter { $0.at >= windowStart }.map(\.value)
                let week = rows.filter { $0.at >= weekStart }.map(\.value)
                return """
                "\(entry.type)":{"count":\(rows.count),"latest":\(number(rows.first?.value)),\
                "min":\(number(values.min())),"max":\(number(values.max())),"mean":\(number(mean(values))),\
                "median":null,"avg7":\(number(mean(week))),"avg30":\(number(mean(month))),\
                "slope7":null,"slope30":null}
                """
            }
            return "{\"summaries\":{\(entries.joined(separator: ","))},\"recoveryEmpty\":null}"
        }

        private static func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        private static func number(_ value: Double?) -> String {
            value.map { "\($0)" } ?? "null"
        }

        // MARK: - List and series

        private static func listJSON(_ entry: Series) -> String {
            let rows = readings(entry).enumerated().map { index, reading in
                let at = iso(reading.at)
                return """
                {"id":"recovery-\(entry.type.lowercased())-\(index)","userId":"hermetic-user","type":"\(entry.type)",\
                "value":\(reading.value),"unit":"\(entry.unit)","measuredAt":"\(at)","notes":null,"source":"\(entry.source)",\
                "glucoseContext":null,"externalId":null,"createdAt":"\(at)","updatedAt":"\(at)"}
                """
            }
            return "{\"measurements\":[\(rows.joined(separator: ","))]}"
        }

        /// The SDNN series as the series route answers it: only the points
        /// inside the requested window, oldest first.
        private static func seriesJSON(_ entry: Series, days: Int) -> String {
            let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
            let rows = readings(entry).filter { $0.at >= start }.reversed()
            let values = rows.map(\.value)
            let points = rows.enumerated().map { index, reading in
                "{\"id\":\"recovery-sdnn-pt-\(index)\",\"at\":\"\(iso(reading.at))\",\"value\":\(reading.value),\"secondary\":null}"
            }
            let average = mean(values) ?? 0
            let spread = values.isEmpty ? 0 : values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(values.count)
            return """
            {"kind":"hrv","unit":"ms","points":[\(points.joined(separator: ","))],\
            "stats":{"mean":\(average),"min":\(values.min() ?? 0),"max":\(values.max() ?? 0),\
            "stdDev":\(spread.squareRoot()),"count":\(values.count)}}
            """
        }
    }
#endif
