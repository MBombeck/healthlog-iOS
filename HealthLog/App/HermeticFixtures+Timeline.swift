#if DEBUG
    import Foundation

    /// **A 1.47.1 server with the timeline module on.** Under
    /// `-uitest-timeline` the fixture server reports version 1.47.1, switches
    /// the opt-in `timeline` module on in `/api/auth/me` and answers
    /// `/api/timeline` from an invented record of three years: high blood
    /// pressure since the start, a stomach bug six weeks ago with a pause of
    /// the GLP-1 medication, its dose raised in steps and lowered again, a
    /// weight that falls with it, readings with a short gap (dashed) and a
    /// long one (broken), two liver values from the lab with one above its
    /// range, and a headache logged as the person's own symptom. Readings are
    /// day by day and averaged per bucket like the server does, so every zoom
    /// gets its own honest means. Invented values only.
    enum TimelineFixtures {
        static let argument = "-uitest-timeline"

        static func response(
            for request: URLRequest,
            base: () -> (status: Int, body: Data)
        ) -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(argument),
                  (request.httpMethod ?? "GET") == "GET",
                  let url = request.url else { return nil }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                query.first { $0.name == name }?.value
            }
            switch url.path {
            case "/api/version":
                return (200, Data(#"{"data":{"version":"1.47.1"},"error":null}"#.utf8))
            case "/api/auth/me":
                return (200, withTimelineModule(base().body))
            case "/api/timeline":
                let body = timeline(
                    zoom: value("zoom") ?? "quarter",
                    from: value("from"),
                    to: value("to"),
                    values: (value("values") ?? "").split(separator: ",").map(String.init)
                )
                return (200, envelope(body))
            default:
                return nil
            }
        }

        private static func envelope(_ data: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["data": data, "error": NSNull()])) ?? Data()
        }

        private static func withTimelineModule(_ body: Data) -> Data {
            guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
            func patched(_ me: [String: Any]) -> [String: Any] {
                var me = me
                var modules = me["modules"] as? [String: Any] ?? [:]
                modules["timeline"] = true
                me["modules"] = modules
                return me
            }
            if let data = object["data"] as? [String: Any] {
                object["data"] = patched(data)
            } else {
                object = patched(object)
            }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? body
        }

        // MARK: - The record

        static var today: Int {
            TimelineDay.number(TimelineDay.key(of: .now)) ?? 0
        }

        private static func dayKey(_ daysAgo: Int) -> String {
            TimelineDay.key(today - daysAgo)
        }

        /// A deterministic wobble in -0.5 ... 0.5 for a day and a seed.
        static func wobble(_ day: Int, _ seed: Int) -> Double {
            let mixed = (day &* 9301 &+ seed &* 49297 &+ 233_280) % 233_280
            return Double(abs(mixed)) / 233_280 - 0.5
        }

        /// Three years back.
        static let historyDays = 1095

        static func timeline(zoom: String, from: String?, to: String?, values: [String]) -> [String: Any] {
            let toDay = to.flatMap(TimelineDay.number) ?? today
            let dataFrom = today - historyDays
            let fromDay: Int = switch zoom {
            case "quarter": toDay - 90
            case "year": toDay - 364
            case "range": from.flatMap(TimelineDay.number) ?? toDay - 90
            default: dataFrom
            }
            let bucket = bucket(zoom: zoom, from: fromDay, to: toDay)
            let measurementKeys = values.filter { readings(for: $0) != nil }
            return [
                "zoom": zoom,
                "range": ["from": TimelineDay.key(fromDay), "to": TimelineDay.key(toDay), "dataFrom": TimelineDay.key(dataFrom)],
                "lanes": lanes,
                "standing": [],
                "bucket": bucket.rawValue,
                "series": measurementKeys.map { series($0, bucket: bucket, from: fromDay, to: toDay) },
                "availableSeries": ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA", "WEIGHT", "RESTING_HEART_RATE", "SLEEP_DURATION"],
                "labSeries": values.compactMap { labSeries($0, from: fromDay, to: toDay) },
                "availableLabs": labMarkers.map { [
                    "key": "lab:\($0.id)",
                    "biomarkerId": $0.id,
                    "name": $0.name,
                    "panel": "Leber",
                    "unit": $0.unit
                ] },
                "symptomSeries": values.compactMap { symptomSeries($0, bucket: bucket, from: fromDay, to: toDay) },
                "availableSymptoms": [
                    [
                        "key": "symptom:sd_headache",
                        "definitionId": "sd_headache",
                        "label": "Kopfschmerz",
                        "icon": NSNull(),
                        "isActive": true
                    ],
                    ["key": "symptom:sd_nausea", "definitionId": "sd_nausea", "label": "Übelkeit", "icon": NSNull(), "isActive": true]
                ],
                "notable": []
            ]
        }

        static func bucket(zoom: String, from: Int, to: Int) -> TimelineBucket {
            switch zoom {
            case "quarter": return .week
            case "year": return .month
            case "range":
                let days = to - from + 1
                return days >= 730 ? .quarter : days >= 120 ? .month : days >= 42 ? .week : .day
            default:
                return to - from > 730 ? .quarter : .month
            }
        }

        // MARK: - Lanes

        private static func item(
            _ id: String, _ kind: String, start: Int, end: Int? = nil, open: Bool = false,
            label: String, sub: String? = nil, group: String? = nil
        ) -> [String: Any] {
            [
                "id": id, "kind": kind, "start": dayKey(start), "end": end.map { dayKey($0) as Any } ?? NSNull(), "open": open,
                "precision": "DAY", "startKnown": true, "label": label, "sub": sub.map { $0 as Any } ?? NSNull(), "href": NSNull(),
                "group": group.map { $0 as Any } ?? NSNull()
            ]
        }

        private static var lanes: [[String: Any]] {
            [
                ["key": "illness", "items": [
                    item("ep-cold", "episode", start: 212, end: 203, label: "Erkältung"),
                    item("ep-gi", "episode", start: 49, end: 42, label: "Magen-Darm-Infekt"),
                    item("chronic-htn", "chronic", start: historyDays, open: true, label: "Bluthochdruck")
                ]],
                ["key": "medications", "items": medications],
                ["key": "vaccinations", "items": [item("vac-flu", "vaccination", start: 33, label: "Influenza")]],
                ["key": "visits", "items": [
                    item("visit-gp", "visit", start: 45, label: "Hausarzt"),
                    item("visit-diab", "visit", start: 96, label: "Diabetologie")
                ]]
            ]
        }

        private static var medications: [[String: Any]] {
            [
                item("med-trulicity", "medication", start: 270, open: true, label: "Trulicity", sub: "2,5 mg", group: "med-trulicity"),
                item("dose-1", "doseChange", start: 270, label: "Trulicity", sub: "2,5 mg", group: "med-trulicity"),
                item("dose-2", "doseChange", start: 238, label: "Trulicity", sub: "5 mg", group: "med-trulicity"),
                item("dose-3", "doseChange", start: 182, label: "Trulicity", sub: "7,5 mg", group: "med-trulicity"),
                item("dose-4", "doseChange", start: 40, label: "Trulicity", sub: "5 mg", group: "med-trulicity"),
                item("pause-gi", "pause", start: 48, end: 41, label: "Trulicity", group: "med-trulicity"),
                item(
                    "med-lisinopril",
                    "medication",
                    start: historyDays - 20,
                    open: true,
                    label: "Lisinopril",
                    sub: "5 mg",
                    group: "med-lisinopril"
                ),
                item("med-b1", "medication", start: 118, open: true, label: "Vitamin B1", sub: "250 mg", group: "med-b1"),
                item("med-omega", "medication", start: 150, open: true, label: "Omega 3", sub: "2 Kapseln", group: "med-omega"),
                item("course-omega", "course", start: 150, end: 61, label: "Omega 3", group: "med-omega"),
                item("med-ibu", "medication", start: 47, end: 47, label: "Naproxen", sub: "400 mg", group: "med-ibu")
            ]
        }

        // MARK: - Values

        /// The day value of a measurement, or `nil` on a day without one.
        static func readings(for key: String) -> ((Int) -> Double?)? {
            switch key {
            case "WEIGHT": weight
            case "BLOOD_PRESSURE_SYS": { daysAgo in pressure(daysAgo, base: 133, drop: 7, seed: 3) }
            case "BLOOD_PRESSURE_DIA": { daysAgo in pressure(daysAgo, base: 86, drop: 5, seed: 5) }
            case "RESTING_HEART_RATE": { daysAgo in
                    let sick = (42 ... 49).contains(daysAgo) ? 9.0 : 0
                    return 66 + sick + wobble(daysAgo, 7) * 6 - Double(min(270, max(0, 270 - daysAgo))) / 90
                }
            case "SLEEP_DURATION": { daysAgo in
                    daysAgo % 11 == 4 ? nil : 405 + wobble(daysAgo, 9) * 70
                }
            default: nil
            }
        }

        /// Weighed four mornings a week; falls from 96 kg once the GLP-1
        /// medication starts nine months ago, no scale on a three-week trip.
        private static func weight(_ daysAgo: Int) -> Double? {
            guard daysAgo % 7 < 4, !(150 ... 170).contains(daysAgo) else { return nil }
            let since = Double(max(0, 270 - daysAgo))
            return 96.4 - min(since, 240) * 0.034 + Double(min(0, daysAgo - 40)) * -0.004 + wobble(daysAgo, 1) * 0.8
        }

        /// Measured most days; a two-week break (bridged) and a six-week one
        /// (broken) where the cuff stayed in a drawer.
        private static func pressure(_ daysAgo: Int, base: Double, drop: Double, seed: Int) -> Double? {
            guard !(64 ... 75).contains(daysAgo), !(300 ... 345).contains(daysAgo), daysAgo % 5 != 2 else { return nil }
            let treated = Double(min(270, max(0, 270 - daysAgo))) / 270
            return base - drop * treated + wobble(daysAgo, seed) * 9
        }

        private static func series(_ key: String, bucket: TimelineBucket, from: Int, to: Int) -> [String: Any] {
            let unit = switch key {
            case "WEIGHT": "kg"
            case "RESTING_HEART_RATE": "bpm"
            case "SLEEP_DURATION": "min"
            default: "mmHg"
            }
            let value = readings(for: key) ?? { _ in nil }
            return ["key": key, "unit": unit, "points": means(bucket: bucket, from: from, to: to) { value(today - $0) }]
        }

        /// The server's bucket means: every bucket that touches the window
        /// with at least one day value, each day weighing one.
        static func means(bucket: TimelineBucket, from: Int, to: Int, value: (Int) -> Double?) -> [[String: Any]] {
            var out: [[String: Any]] = []
            var start = TimelineDay.bucketStart(from, bucket)
            while start <= to {
                let after = TimelineDay.bucketAfter(start, bucket)
                let days = (max(start, from) ... min(after - 1, to)).compactMap { value($0) }
                if !days.isEmpty {
                    let mean = (days.reduce(0, +) / Double(days.count) * 10).rounded() / 10
                    out.append(["t": TimelineDay.key(start), "mean": mean, "count": days.count])
                }
                start = after
            }
            return out
        }

        // MARK: - Labs and symptoms

        private struct Marker {
            let id: String
            let name: String
            let unit: String
            let high: Double
            let readings: [(daysAgo: Int, value: Double)]
        }

        private static let labMarkers = [
            Marker(id: "bm_ggt", name: "GGT", unit: "U/L", high: 60, readings: [(400, 81), (250, 72), (96, 54), (12, 41)]),
            Marker(id: "bm_got", name: "GOT (AST)", unit: "U/L", high: 50, readings: [(400, 44), (250, 39), (96, 33), (12, 29)]),
            Marker(id: "bm_hba1c", name: "HbA1c", unit: "%", high: 5.6, readings: [(250, 6.4), (96, 5.9)])
        ]

        private static func labSeries(_ key: String, from: Int, to: Int) -> [String: Any]? {
            guard key.hasPrefix("lab:"), let marker = labMarkers.first(where: { key == "lab:\($0.id)" }) else { return nil }
            let points = marker.readings.filter { (from ... to).contains(today - $0.daysAgo) }.map { reading -> [String: Any] in
                [
                    "id": "\(marker.id)-\(reading.daysAgo)", "date": dayKey(reading.daysAgo), "value": reading.value,
                    "sourceValue": NSNull(), "rangeStatus": reading.value > marker.high ? "above" : "in-range",
                    "referenceLow": NSNull(), "referenceHigh": marker.high, "report": NSNull()
                ]
            }
            return [
                "key": key, "biomarkerId": marker.id, "name": marker.name, "panel": "Leber", "unit": marker.unit,
                "band": ["low": NSNull(), "high": marker.high], "points": points, "excluded": 0
            ]
        }

        private static func symptomSeries(_ key: String, bucket: TimelineBucket, from: Int, to: Int) -> [String: Any]? {
            guard key == "symptom:sd_headache" else { return nil }
            let points = means(bucket: bucket, from: from, to: to) { day in
                let daysAgo = today - day
                if (42 ... 49).contains(daysAgo) { return 5 + wobble(daysAgo, 11) * 4 }
                return daysAgo % 17 == 3 ? 3 + wobble(daysAgo, 13) * 2 : nil
            }
            return [
                "key": key, "definitionId": "sd_headache", "label": "Kopfschmerz", "icon": NSNull(), "isActive": true,
                "scale": ["min": 0, "max": 10], "points": points
            ]
        }
    }
#endif
