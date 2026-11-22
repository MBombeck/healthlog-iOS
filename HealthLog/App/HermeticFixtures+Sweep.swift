#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// `-uitest-sweep` — the QA-sweep overlay. Only
        /// `QASweepScreenshotsTest` passes it.
        static let sweepOverlayArgument = "-uitest-sweep"

        static var isSweepOverlayActive: Bool {
            ProcessInfo.processInfo.arguments.contains(sweepOverlayArgument)
        }

        /// `-uitest-sweep-nomeds` — an account with nothing scheduled today, so
        /// Today's adherence card has nothing to count.
        static var isSweepNoMedicationsActive: Bool {
            ProcessInfo.processInfo.arguments.contains("-uitest-sweep-nomeds")
        }
    }

    /// **Readings for the six metric pages of the QA sweep.**
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
            /// Per day back, up to ``driftDays``: a slow trend under the wave.
            var drift: Double = 0
        }

        private static let series: [Series] = [
            // Weight falls over the last weeks, the way the summary's "down"
            // tile says; the page's comparison reads the same direction.
            Series(serverType: "WEIGHT", seriesKind: "weight", unit: "kg", base: 72.4, swing: 0.6, secondary: nil, drift: 0.02),
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
            Series(serverType: "SLEEP_DURATION", seriesKind: "sleep", unit: "minutes", base: 432, swing: 25, secondary: nil),
            // The two vitals the marketing summary names (58 bpm, 46 ms). With
            // no readings behind them their tiles stayed at "—" while Insights
            // showed the summary's values.
            Series(serverType: "RESTING_HEART_RATE", seriesKind: "restingHeartRate", unit: "bpm", base: 58, swing: 2, secondary: nil),
            Series(serverType: "HEART_RATE_VARIABILITY", seriesKind: "heartRateVariability", unit: "ms", base: 46, swing: 4, secondary: nil)
        ]

        /// The window the usual range and a read without `days` cover.
        private static let days = 30

        /// How far back the account's readings reach: past six months, so the
        /// 6M range has its own points and "All" ends where the history does.
        private static let historyDays = 200

        /// The days a falling or rising trend runs before the line levels off.
        private static let driftDays = 45

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
            // Writes reach only the Today hero overlay (dismissing a hint),
            // the connector mint of the step-up walk and, under
            // `-uitest-capture-receipt`, a saved reading for the receipt.
            // Server 1.49 part B (`-uitest-catchup-b`) answers its refused
            // target and its reads first.
            guard method == "GET" else {
                return CatchupBFixtures.response(forPath: path, method: method)
                    ?? TodayHeroFixtures.response(forPath: path, method: method)
                    ?? SecFixtures.mintResponse(forPath: path, method: method)
                    ?? CaptureReceiptFixtures.response(forPath: path, method: method)
            }
            // A 1.47 server with blood pressure by time of day (`-uitest-bp-tod`).
            // 1.5 MOVE — a connected Dawarich under Environment (`-uitest-move`), same branch.
            // 1.5 VISIT — a booked visit with its window (`-uitest-visit`).
            // A check-up that targets blood ketones (`-uitest-ketone-reminder`).
            // 1.5 SEC — the account's proof methods (`-uitest-sec`).
            // Server 1.48 on the app side (`-uitest-server148`).
            if let overlay = CatchupBFixtures.response(forPath: path, method: method)
                ?? Server148Fixtures.response(forPath: path, method: method, query: query)
                ?? BloodPressureTimeOfDayFixtures.response(forPath: path, query: query)
                ?? MovementFixtures.response(forPath: path)
                ?? VisitFixtures.response(forPath: path)
                ?? KetoneReminderFixtures.response(forPath: path, query: query)
                ?? SecFixtures.response(forPath: path)
                ?? TodayHeroFixtures.response(forPath: path, method: method) { return overlay }
            if let records = SweepRecordFixtures.response(forPath: path, query: query)
                ?? noMedicationsResponse(forPath: path) { return records }
            func value(_ name: String) -> String? {
                query.first { $0.name == name }?.value
            }
            if path == "/api/analytics", value("slice") == "summaries" { return ok(summariesJSON) }
            // The tile layout is the one a server resolves for an account that
            // never changed it. The shared `{}` is no layout, and "Kacheln
            // anpassen" wore the read error over its list.
            let fixed = [
                "/api/insights/layout": layoutJSON,
                "/api/dashboard/widgets": widgetLayoutJSON,
                // A health score, so the Insights score grid shows its card.
                "/api/dashboard/snapshot": snapshotJSON
            ]
            if let answer = fixed[path] { return ok(answer) }
            // An account that never logged a mood or uploaded an ECG.
            // The shared table's `{}` decodes as neither, so both reads failed
            // and the Insights pages could not show their empty states. The
            // `-uitest-area-meds` overlay still outranks this with mood data.
            if path == "/api/mood-entries" { return ok(#"{"entries":[],"meta":{"total":0}}"#) }
            if path == "/api/insights/ecg" {
                return ok(#"{"data":{"recordings":[],"hasRecordings":false},"error":null}"#)
            }
            // The server version, so Konto → Sicherheit and Server
            // show their real states instead of "could not be read". Only in
            // the sweep: the auth journeys keep the version-less server their
            // login tests are about (`HermeticUITestSupport.webLoginRoutesArgument`).
            // 1.5 KONTO — `-uitest-konto` photographs a 1.46 server (`KontoFixtures`).
            if path ==
                "/api/version"
            {
                return KontoFixtures.response(forPath: path) ?? ok(#"{ "data": { "version": "1.43.10" }, "error": null }"#)
            }
            if path == "/api/measurements/series" {
                guard let kind = value("kind"), let entry = series.first(where: { $0.seriesKind == kind }) else {
                    return nil
                }
                return ok(seriesJSON(entry, days: value("days").flatMap(Int.init) ?? days))
            }
            if path == "/api/measurements" {
                let type = value("type")
                let known = series.contains { $0.serverType == type } || type == "BLOOD_PRESSURE_DIA"
                if let type, !known, let wearable = RecoveryFixtures.sweepListResponse(type: type) { return wearable }
                return ok(listJSON(type: type, limit: value("limit").flatMap(Int.init)))
            }
            return SweepWorldFixtures.response(forPath: path, method: method, query: query)
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// Under `-uitest-sweep-nomeds`, the summary of an account with nothing
        /// scheduled today; `nil` otherwise.
        private static func noMedicationsResponse(forPath path: String) -> (status: Int, body: Data)? {
            guard HermeticUITestSupport.isSweepNoMedicationsActive,
                  path.hasPrefix("/api/dashboard/summary") else { return nil }
            return ok(nothingScheduledSummaryJSON)
        }

        /// The sweep's own summary (today's date, the sweep's greeting) with
        /// nothing scheduled and nothing taken today. The shared row is pinned
        /// to 16 June and greets "Hermetic Tester", which the page then showed.
        static var nothingScheduledSummaryJSON: String {
            let base = MarketingFixtures.summaryJSON
            guard var summary = (try? JSONSerialization.jsonObject(with: Data(base.utf8))) as? [String: Any] else { return base }
            summary["compliance"] = ["scheduledToday": 0, "takenToday": 0]
            guard let data = try? JSONSerialization.data(withJSONObject: summary) else { return base }
            return String(bytes: data, encoding: .utf8) ?? base
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

        /// The snapshot carries only the health score: four pillars, a
        /// week-over-week rise, high confidence.
        private static let snapshotJSON = #"""
        {"healthScore":{"score":74,"band":"green","delta":3,"confidence":{"score":82,"band":"high"},
        "composition":["BLOOD_PRESSURE","ACTIVITY","SLEEP","WELLBEING"],
        "scoreBasis":{"domains":4,"recommended":4,"tier":"full","physiological":true}}}
        """#

        private static let widgetLayoutJSON: String = {
            guard let data = try? JSONEncoder().encode(DashboardWidgetLayout.default),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
            object["updatedAt"] = "2026-01-01T00:00:00.000Z"
            guard let body = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
            return String(bytes: body, encoding: .utf8) ?? "{}"
        }()

        /// The usual range `coach-read` reports for one server type, read off
        /// the same thirty readings the metric page charts: mean ± one spread,
        /// with today's reading as the latest. `nil` for a type without readings.
        struct UsualRange {
            let low: Double
            let high: Double
            let latest: Double
        }

        static func usualRange(serverType: String) -> UsualRange? {
            guard let entry = series.first(where: { $0.serverType == serverType }) else { return nil }
            let values = (0 ..< days).map { reading(entry, $0) }
            let mean = values.reduce(0, +) / Double(values.count)
            let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            func rounded(_ value: Double) -> Double {
                entry.unit == "kg" ? (value * 10).rounded() / 10 : value.rounded()
            }
            return UsualRange(low: rounded(mean - spread), high: rounded(mean + spread), latest: reading(entry, 0))
        }

        /// The sweep's types plus the wearable ones of ``RecoveryFixtures``, so
        /// the recovery page has the readings behind the overview's rings.
        private static var summariesJSON: String {
            var keys = series.map { "\"\($0.serverType)\":{\"count\":\(historyDays)}" }
            keys.append("\"BLOOD_PRESSURE_DIA\":{\"count\":\(historyDays)}")
            keys += RecoveryFixtures.sweepSummaryEntries(excluding: Set(series.map(\.serverType)))
            return "{\"summaries\":{\(keys.joined(separator: ","))}}"
        }

        /// Day `offset` back from today, at 07:30 local. Today's reading never
        /// lies ahead of the clock: a run before half past seven gets it a
        /// quarter of an hour ago (at the earliest just after midnight).
        private static func day(_ offset: Int) -> Date {
            let calendar = Calendar.current
            let now = Date.now
            let morning = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now) ?? now
            let today = min(morning, max(calendar.startOfDay(for: now).addingTimeInterval(60), now.addingTimeInterval(-900)))
            return calendar.date(byAdding: .day, value: -offset, to: offset == 0 ? today : morning) ?? morning
        }

        /// A gentle deterministic wave, never random: the same capture day
        /// always draws the same chart.
        private static func reading(_ entry: Series, _ offset: Int) -> Double {
            let wave = sin(Double(offset) * 0.7) * entry.swing
            let value = entry.base + wave + entry.drift * Double(min(offset, driftDays))
            return entry.unit == "kg" ? (value * 10).rounded() / 10 : value.rounded()
        }

        private static func iso(_ date: Date) -> String {
            date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }

        /// Newest first, as the route answers: only rows of `type` (every type
        /// without one), the diastolic half on its own page as the server
        /// keeps it, cut to `limit` rows.
        private static func listJSON(type: String?, limit: Int?) -> String {
            var rows: [String] = []
            for offset in 0 ..< historyDays {
                for entry in series {
                    let at = iso(day(offset))
                    let context = entry.serverType == "BLOOD_GLUCOSE" ? "\"FASTING\"" : "null"
                    if type == nil || type == entry.serverType {
                        rows.append(row(
                            id: "sweep-\(entry.seriesKind)-\(offset)", type: entry.serverType,
                            value: reading(entry, offset), unit: entry.unit, at: at, context: context
                        ))
                    }
                    if let diastolic = entry.secondary, type == nil || type == "BLOOD_PRESSURE_DIA" {
                        rows.append(row(
                            id: "sweep-dia-\(offset)", type: "BLOOD_PRESSURE_DIA",
                            value: diastolic + (sin(Double(offset)) * 3).rounded(), unit: "mmHg", at: at, context: "null"
                        ))
                    }
                }
            }
            return "{\"measurements\":[\(rows.prefix(limit ?? rows.count).joined(separator: ","))]}"
        }

        private static func row(id: String, type: String, value: Double, unit: String, at: String, context: String) -> String {
            """
            {"id":"\(id)","userId":"hermetic-user","type":"\(type)","value":\(value),"unit":"\(unit)",\
            "measuredAt":"\(at)","notes":null,"source":"MANUAL","glucoseContext":\(context),\
            "externalId":null,"createdAt":"\(at)","updatedAt":"\(at)"}
            """
        }

        /// The points inside the requested window, oldest first: one a day,
        /// at most as far back as the history reaches.
        private static func seriesJSON(_ entry: Series, days requested: Int) -> String {
            // The series route answers sleep in hours, everything else as listed.
            let scale = entry.unit == "minutes" ? 1.0 / 60.0 : 1.0
            let unit = entry.unit == "minutes" ? "h" : entry.unit
            let window = max(1, min(requested, historyDays))
            let values = (0 ..< window).reversed().map { reading(entry, $0) * scale }
            let points = (0 ..< window).reversed().enumerated().map { index, offset in
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
