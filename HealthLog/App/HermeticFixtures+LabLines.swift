#if DEBUG
    import Foundation

    /// **1.5 LAB-LINES — a 1.47 server with the timeline module on.** Under
    /// `-uitest-lab-lines` the fixture server reports version 1.47.0, switches
    /// the opt-in `timeline` module on in `/api/auth/me`, answers
    /// `/api/timeline` with four lab markers and the HbA1c readings of the
    /// last three months (two on one day, one above, one below, one in
    /// another unit), `coach-read` with a latest reading from two days ago,
    /// and the narrowed blood pressure series for each part of the day.
    /// `nil` everywhere else and without the argument. Invented values only.
    enum LabLinesFixtures {
        static let argument = "-uitest-lab-lines"

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
                return (200, Data(#"{"data":{"version":"1.47.0"},"error":null}"#.utf8))
            case "/api/auth/me":
                return (200, withTimelineModule(base().body))
            case "/api/timeline":
                return (200, Data(timelineJSON(marker: value("values"), from: value("from") ?? "").utf8))
            case "/api/insights/coach-read":
                return (200, Data(coachReadJSON(metric: value("metric") ?? "").utf8))
            case "/api/measurements":
                guard let part = value("partOfDay"), let type = value("type") else { return nil }
                return (200, Data(partJSON(type: type, part: part).utf8))
            default:
                return nil
            }
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

        private static func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) ?? .now
            return TimelineRepository.dayKey(date)
        }

        private static func timelineJSON(marker: String?, from: String) -> String {
            let labs = """
            [{"key":"lab:bm_hba1c","biomarkerId":"bm_hba1c","name":"HbA1c","panel":"Diabetes","unit":"%"},
             {"key":"lab:bm_glucose","biomarkerId":"bm_glucose","name":"Nüchternglukose","panel":"Diabetes","unit":"mg/dL"},
             {"key":"lab:bm_tsh","biomarkerId":"bm_tsh","name":"TSH","panel":"Schilddrüse","unit":"mU/L"},
             {"key":"lab:bm_crp","biomarkerId":"bm_crp","name":"CRP","panel":null,"unit":"mg/L"}]
            """
            var series = "[]"
            if marker == "lab:bm_hba1c" {
                func point(_ id: String, _ offset: Int, _ value: Double, _ status: String, report: Bool = false) -> String {
                    let link = report ? #"{"id":"doc-lab","title":"Laborbefund Hausarzt","href":"/documents/doc-lab"}"# : "null"
                    return #"{"id":"\#(id)","date":"\#(day(offset))","value":\#(value),"sourceValue":null,"rangeStatus":"\#(status)","#
                        + #""referenceLow":4.0,"referenceHigh":5.6,"report":\#(link)}"#
                }
                // Only the readings in the asked window, like the server.
                let points = [
                    (160, point("r1", 160, 5.9, "above")),
                    (26, point("r2", 26, 5.5, "in-range")),
                    (17, point("r3", 17, 5.8, "above", report: true)),
                    (17, point("r4", 17, 5.6, "in-range")),
                    (6, point("r5", 6, 3.9, "below"))
                ].filter { day($0.0) >= from }.map(\.1)
                series = #"[{"key":"lab:bm_hba1c","biomarkerId":"bm_hba1c","name":"HbA1c","panel":"Diabetes","unit":"%","#
                    + #""band":{"low":4.0,"high":5.6},"points":[\#(points.joined(separator: ","))],"excluded":1}]"#
            }
            return #"{"data":{"zoom":"range","range":{"from":"\#(day(90))","to":"\#(day(0))","dataFrom":"2019-01-01"},"#
                + #""lanes":[],"standing":[],"bucket":"week","series":[],"availableSeries":[],"#
                + #""labSeries":\#(series),"availableLabs":\#(labs),"notable":[]},"error":null}"#
        }

        private static func coachReadJSON(metric: String) -> String {
            let band: [Double] = switch metric {
            case "WEIGHT": [78.4, 80.2, 79.6]
            case "BLOOD_PRESSURE_SYS": [124, 136, 131]
            default: [58, 66, 63]
            }
            return #"{"data":{"baseline":{"low":\#(band[0]),"high":\#(band[1]),"latest":\#(band[2]),"#
                + #""latestDate":"\#(day(2))","latestIsToday":false,"placement":"within","sampleDays":60},"#
                + #""learning":false,"driver":null},"error":null}"#
        }

        private static func partJSON(type: String, part: String) -> String {
            let base: Double = switch (type, part) {
            case ("BLOOD_PRESSURE_SYS", "morning"): 136
            case ("BLOOD_PRESSURE_SYS", _): 127
            case (_, "morning"): 87
            default: 81
            }
            let rows = (0 ..< 28).map { offset -> String in
                let date = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -offset, to: .now) ?? .now)
                let wobble = Double((offset * 7) % 9) - 4
                return #"{"type":"\#(type)","value":\#(base + wobble),"measuredAt":"\#(ISO8601DateFormatter().string(from: date))","count":2}"#
            }
            return #"{"data":{"measurements":[\#(rows.reversed().joined(separator: ","))],"#
                + #""meta":{"total":28,"limit":365,"offset":0,"aggregate":"daily","partOfDay":"\#(part)"}},"error":null}"#
        }
    }
#endif
