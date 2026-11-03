#if DEBUG
    import Foundation

    /// **iOS 1.4 B2-b — an illness journal to photograph.**
    ///
    /// The marketing world answers no illness route, so the journal, an
    /// episode and the retrospective only ever showed their empty states.
    /// Under `-uitest-area-meds` this table serves four infections: Bronchitis,
    /// open since three days with three logged days, and three resolved ones;
    /// the resolved Influenza carries the server's vitals reading (resting
    /// heart rate above baseline before onset, back three days after the
    /// patient felt better). Dates are relative to now, so the screens read
    /// the same on any day. Everything is invented; no value of any real
    /// person appears here.
    enum AreaIllnessFixtures {
        static let influenzaID = "area-illness-influenza"
        static let bronchitisID = "area-illness-bronchitis"

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET", path.hasPrefix("/api/illness/") else { return nil }
            if path == "/api/illness/episodes" {
                return envelope("[\(episodes.map(\.json).joined(separator: ","))]")
            }
            if path == "/api/illness/insights" {
                return envelope(insights)
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 4, let episode = episodes.first(where: { $0.id == parts[3] }) else { return nil }
            switch parts.dropFirst(4).first {
            case nil:
                return envelope(episode.json)
            case "day-logs"?:
                if query.contains(where: { $0.name == "date" }) { return envelope("null") }
                let logs = episode.id == bronchitisID ? bronchitisLogs : []
                return envelope("""
                {"dayLogs":[\(logs.joined(separator: ","))],"meta":{"total":\(logs.count),"limit":200,"offset":0}}
                """)
            case "correlation"?:
                return envelope(episode.id == influenzaID ? influenzaCorrelation : insufficient(episode.id))
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        // MARK: - Dates

        private static func stamp(daysAgo: Int, hour: Int = 8) -> String {
            let calendar = Calendar(identifier: .gregorian)
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
            let date = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static func day(daysAgo: Int) -> String {
            String(stamp(daysAgo: daysAgo, hour: 12).prefix(10))
        }

        // MARK: - Episodes

        private struct Episode {
            let id: String
            let label: String
            let onset: Int
            let resolved: Int?

            var json: String {
                """
                {"id":"\(id)","label":"\(label)","type":"INFECTION","lifecycle":"ACUTE",\
                "onsetAt":"\(stamp(daysAgo: onset))","resolvedAt":\(resolved.map { "\"\(stamp(daysAgo: $0))\"" } ?? "null"),\
                "parentConditionId":null,"note":null,"createdAt":"\(stamp(daysAgo: onset))",\
                "updatedAt":"\(stamp(daysAgo: resolved ?? onset))"}
                """
            }
        }

        private static let episodes = [
            Episode(id: bronchitisID, label: "Bronchitis", onset: 3, resolved: nil),
            Episode(id: influenzaID, label: "Influenza", onset: 44, resolved: 36),
            Episode(id: "area-illness-sinusitis", label: "Sinusitis", onset: 150, resolved: 143),
            Episode(id: "area-illness-gastro", label: "Gastroenteritis", onset: 270, resolved: 266)
        ]

        private static let bronchitisLogs = [(3, 2, "38.4"), (2, 2, "38.1"), (1, 1, "null")].map { ago, impact, fever in
            """
            {"id":"area-illness-log-\(ago)","episodeId":"\(bronchitisID)","date":"\(day(daysAgo: ago))",\
            "functionalImpact":\(impact),"feverC":\(fever),"symptoms":[{"key":"cough","severity":2},\
            {"key":"fatigue","severity":null}],"note":null,"updatedAt":"\(stamp(daysAgo: ago, hour: 20))"}
            """
        }

        // MARK: - Derived

        private static let influenzaCorrelation = """
        {"episodeId":"\(influenzaID)","status":"ok","value":{"episodeId":"\(influenzaID)",\
        "preOnset":[{"type":"RESTING_HEART_RATE","day":"\(day(daysAgo: 45))","value":63,"baselineCenter":56,\
        "deviationSd":2.2,"direction":"above","adverse":true}],"nadir":[],\
        "returns":[{"type":"RESTING_HEART_RATE","returnedDay":"\(day(daysAgo: 35))","gapDays":3}],\
        "recoveryGapDays":3.0,"feltBetterDay":"\(day(daysAgo: 38))","gapDriverType":"RESTING_HEART_RATE",\
        "redFlags":[],"sleepContext":null},\
        "coverage":{"requiredInputs":4,"presentInputs":3,"historyDays":90,"missing":["SPO2"]},\
        "confidence":{"score":0.7,"band":"medium"},\
        "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"server","windowDays":90,\
        "computedAt":"\(stamp(daysAgo: 1))"},"reason":null}
        """

        private static func insufficient(_ id: String) -> String {
            """
            {"episodeId":"\(id)","status":"insufficient","value":null,\
            "coverage":{"requiredInputs":4,"presentInputs":1,"historyDays":12,"missing":["HRV","SPO2"]},\
            "confidence":null,"provenance":{"inputs":[],"source":"server","windowDays":90,\
            "computedAt":"\(stamp(daysAgo: 1))"},"reason":"not enough history"}
            """
        }

        private static var insights: String {
            let months = episodes.map { String(stamp(daysAgo: $0.onset).prefix(7)) }
            let byMonth = Dictionary(months.map { ($0, 1) }, uniquingKeysWith: +)
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\($0.value)" }
                .joined(separator: ",")
            return """
            {"windowDays":365,"episodeCount":4,"resolvedCount":3,"typicalRecoveryGapDays":3.0,\
            "gapSampleSize":3,"byMonth":{\(byMonth)},"byType":{"INFECTION":4},"gapDriverType":"RESTING_HEART_RATE"}
            """
        }
    }
#endif
