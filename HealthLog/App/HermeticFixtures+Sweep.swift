#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// **H2 (1.1.0).** `-uitest-sweep` — the QA-sweep overlay. Only
        /// `QASweepScreenshotsTest` passes it.
        static let sweepOverlayArgument = "-uitest-sweep"

        static var isSweepOverlayActive: Bool {
            ProcessInfo.processInfo.arguments.contains(sweepOverlayArgument)
        }
    }

    /// **H2 (1.1.0) — readings for the six metric pages of the QA sweep.**
    ///
    /// The shared hermetic world serves no measurements at all, so every metric
    /// page of a sweep would photograph the same empty state. This overlay
    /// answers the three read routes those pages use — the availability slice,
    /// the per-type list and the series — with thirty days of invented,
    /// deliberately unremarkable readings for weight, blood pressure, pulse,
    /// glucose, SpO₂ and sleep. No health value of any real person appears here.
    ///
    /// Dates are computed against the simulator clock so "today" on the pages
    /// is the capture day. `nil` for every other route, so the marketing and
    /// shared tables below it answer unchanged.
    enum SweepFixtures {
        private struct Series {
            let serverType: String
            let seriesKind: String
            let unit: String
            let base: Double
            let swing: Double
            let secondary: Double?
        }

        private static let series: [Series] = [
            Series(serverType: "WEIGHT", seriesKind: "weight", unit: "kg", base: 72.4, swing: 0.6, secondary: nil),
            Series(
                serverType: "BLOOD_PRESSURE_SYS", seriesKind: "bloodPressure", unit: "mmHg",
                base: 122, swing: 4, secondary: 78
            ),
            Series(serverType: "PULSE", seriesKind: "pulse", unit: "bpm", base: 64, swing: 3, secondary: nil),
            Series(serverType: "BLOOD_GLUCOSE", seriesKind: "glucose", unit: "mg/dL", base: 96, swing: 6, secondary: nil),
            Series(
                serverType: "OXYGEN_SATURATION", seriesKind: "oxygenSaturation", unit: "%",
                base: 97, swing: 1, secondary: nil
            ),
            Series(serverType: "SLEEP_DURATION", seriesKind: "sleep", unit: "minutes", base: 432, swing: 25, secondary: nil)
        ]

        private static let days = 30

        /// Two refused SpO₂ readings (the 1.0.4 `value_out_of_range` case), so
        /// Sync Diagnostics shows its rejection list instead of "none". The real
        /// register answers only under an admitted HealthKit lease, which a
        /// simulator boot never gets, so the sweep swaps the read seam for a
        /// fixed snapshot once the composition root has installed its own.
        @MainActor
        static func seedSkippedRows(ownerID: String) {
            guard HermeticUITestSupport.isSweepOverlayActive else { return }
            let rows = [0, 1].map { offset in
                HealthKitSkippedRow(
                    ownerID: ownerID,
                    entry: HealthKitBatchEntryDTO(
                        hkIdentifier: "HKQuantityTypeIdentifierOxygenSaturation",
                        value: 0.97 - Double(offset) * 0.01,
                        unit: "%",
                        startDate: day(offset + 1),
                        endDate: day(offset + 1),
                        externalId: "sweep-skipped-spo2-\(offset)"
                    ),
                    nutrient: nil,
                    mood: nil,
                    reason: "value_out_of_range",
                    firstSkippedAt: day(offset + 1),
                    lastAttemptAt: day(0),
                    attempts: 2,
                    lastOfferedBuild: "sweep"
                )
            }
            let snapshot = HealthKitSkippedRowSnapshot(rows: rows, overflow: 0)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                HealthKitSkippedRowAccess.install(snapshot: { snapshot }, resend: { nil })
            }
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            if let records = SweepRecordFixtures.response(forPath: path, query: query) { return records }
            func value(_ name: String) -> String? {
                query.first { $0.name == name }?.value
            }
            if path == "/api/analytics", value("slice") == "summaries" { return ok(summariesJSON) }
            if path == "/api/insights/layout" { return ok(layoutJSON) }
            if path == "/api/measurement-reminders" { return ok("[]") }
            if path == "/api/measurements/series" {
                guard let kind = value("kind"), let entry = series.first(where: { $0.seriesKind == kind }) else {
                    return nil
                }
                return ok(seriesJSON(entry))
            }
            if path == "/api/measurements" {
                let type = value("type")
                let wanted = series.filter { type == nil || $0.serverType == type }
                return ok(listJSON(wanted))
            }
            return nil
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The strip the sweep walks: every page this overlay has readings for,
        /// plus the special pages. The bootstrap layout keeps glucose, SpO₂ and
        /// sleep off the strip, so without this their deep links park.
        private static let layoutJSON: String = {
            let ids = [
                "overview", "weight", "blood-pressure", "pulse", "blood-glucose", "oxygen", "sleep",
                "resting-pulse", "hrv", "mood", "medications", "workouts"
            ]
            let tiles = ids.enumerated().map { "{\"id\":\"\($1)\",\"visible\":true,\"order\":\($0)}" }
            return "{\"version\":2,\"tiles\":[\(tiles.joined(separator: ","))]}"
        }()

        private static var summariesJSON: String {
            var keys = series.map { "\"\($0.serverType)\":{\"count\":\(days)}" }
            keys.append("\"BLOOD_PRESSURE_DIA\":{\"count\":\(days)}")
            return "{\"summaries\":{\(keys.joined(separator: ","))}}"
        }

        /// Day `offset` back from today, at 07:30 local.
        private static func day(_ offset: Int) -> Date {
            let morning = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: .now) ?? .now
            return Calendar.current.date(byAdding: .day, value: -offset, to: morning) ?? morning
        }

        /// A gentle deterministic wave, never random: the same capture day
        /// always draws the same chart.
        private static func reading(_ entry: Series, _ offset: Int) -> Double {
            let wave = sin(Double(offset) * 0.7) * entry.swing
            let value = entry.base + wave
            return entry.unit == "kg" ? (value * 10).rounded() / 10 : value.rounded()
        }

        private static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static func listJSON(_ wanted: [Series]) -> String {
            var rows: [String] = []
            for offset in 0 ..< days {
                for entry in wanted {
                    let at = iso(day(offset))
                    let context = entry.serverType == "BLOOD_GLUCOSE" ? "\"FASTING\"" : "null"
                    rows.append(row(
                        id: "sweep-\(entry.seriesKind)-\(offset)", type: entry.serverType,
                        value: reading(entry, offset), unit: entry.unit, at: at, context: context
                    ))
                    if let diastolic = entry.secondary {
                        rows.append(row(
                            id: "sweep-dia-\(offset)", type: "BLOOD_PRESSURE_DIA",
                            value: diastolic + (sin(Double(offset)) * 3).rounded(), unit: "mmHg", at: at, context: "null"
                        ))
                    }
                }
            }
            return "{\"measurements\":[\(rows.joined(separator: ","))]}"
        }

        private static func row(id: String, type: String, value: Double, unit: String, at: String, context: String) -> String {
            """
            {"id":"\(id)","userId":"hermetic-user","type":"\(type)","value":\(value),"unit":"\(unit)",\
            "measuredAt":"\(at)","notes":null,"source":"MANUAL","glucoseContext":\(context),\
            "externalId":null,"createdAt":"\(at)","updatedAt":"\(at)"}
            """
        }

        private static func seriesJSON(_ entry: Series) -> String {
            // The series route answers sleep in hours, everything else as listed.
            let scale = entry.unit == "minutes" ? 1.0 / 60.0 : 1.0
            let unit = entry.unit == "minutes" ? "h" : entry.unit
            let values = (0 ..< days).reversed().map { reading(entry, $0) * scale }
            let points = (0 ..< days).reversed().enumerated().map { index, offset in
                let secondary = entry.secondary.map { String($0 + (sin(Double(offset)) * 3).rounded()) } ?? "null"
                return """
                {"id":"sweep-pt-\(entry.seriesKind)-\(offset)","at":"\(iso(day(offset)))",\
                "value":\(values[index]),"secondary":\(secondary)}
                """
            }
            let mean = values.reduce(0, +) / Double(values.count)
            let spread = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return """
            {"kind":"\(entry.seriesKind)","unit":"\(unit)","points":[\(points.joined(separator: ","))],\
            "stats":{"mean":\(mean),"min":\(values.min() ?? 0),"max":\(values.max() ?? 0),\
            "stdDev":\(spread.squareRoot()),"count":\(values.count)}}
            """
        }
    }
#endif
