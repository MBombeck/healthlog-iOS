#if DEBUG
    import Foundation

    /// **The app side of server 1.48, photographed** (#176, #182 A2/A8).
    ///
    /// Under `-uitest-server148` (with `-uitest-sweep`) the sweep account gains
    /// what a 1.48 server sends: `trendWindowDays` on the dashboard cards (30
    /// on weight and blood pressure, `null` on steps, so its arrow goes), the
    /// day's dose slots on the snapshot (`medsToday.scheduledTodayAt`, two of
    /// them still ahead), a digest whose reaction lead is in English under the
    /// German account (`languages`), the month comparison of the weight page
    /// (`/api/analytics/range`) and a personal magnesium target. Invented
    /// values only. `nil` for every other route.
    enum Server148Fixtures {
        static let argument = "-uitest-server148"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard isActive, method == "GET" else { return nil }
            switch path {
            case "/api/dashboard/summary": return summary()
            case "/api/dashboard/snapshot": return ok(snapshotJSON)
            case "/api/daily/digest": return ok(digestJSON)
            case "/api/analytics/range": return range(query: query)
            case "/api/nutrients/targets": return envelope(#"{"targets":{"magnesium":{"value":400,"direction":"target"}}}"#)
            case "/api/nutrients/daily": return daily(query: query)
            default: return nil
            }
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func iso(hoursFromNow hours: Double) -> String {
            Date.now.addingTimeInterval(hours * 3600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }

        /// The marketing summary, one of three doses taken, with the window
        /// each card's arrow follows.
        private static func summary() -> (Int, Data)? {
            guard var summary = (try? JSONSerialization.jsonObject(with: Data(MarketingFixtures.summaryJSON.utf8))) as? [String: Any],
                  let metrics = summary["metrics"] as? [[String: Any]] else { return nil }
            summary["compliance"] = ["scheduledToday": 3, "takenToday": 1]
            summary["metrics"] = metrics.map { metric in
                var metric = metric
                let kind = metric["kind"] as? String ?? ""
                metric["trendWindowDays"] = ["steps", "mood", "bmi"].contains(kind) ? NSNull() : 30
                return metric
            }
            return (try? JSONSerialization.data(withJSONObject: summary)).map { (200, $0) }
        }

        /// A dose taken this morning and two still ahead today.
        private static var snapshotJSON: String {
            """
            {"briefingState":"no-provider","briefingStale":false,
             "medsToday":{"activeCount":2,"scheduledToday":3,"takenToday":1,"skippedToday":0,
              "scheduledTodayAt":["\(iso(hoursFromNow: -3))","\(iso(hoursFromNow: 2))","\(iso(hoursFromNow: 6))"],
              "nextDueAt":"\(iso(hoursFromNow: 2))","nextDueOverdue":false,
              "nextDueMedicationName":null,"nextDueMedicationId":null,"dueCandidates":[]}}
            """
        }

        /// A reaction lead written in English for a German reader: the app
        /// passes it over for the server's German line. No medication fact,
        /// so the medication card stands under the hero.
        private static let digestJSON = #"""
        {"generatedAt":"2026-11-21T06:00:00.000Z","phase":"final","sleepPending":false,
         "lead":{"text":"A calm day: your resting pulse sits two beats below your usual.","source":"reaction","language":"en"},
         "signalLine":{"headline":"Resting pulse lower","delta":"-2 bpm","language":"en"},
         "languages":{"response":"de","briefing":null,"reaction":"en"},
         "score":{"value":78,"band":"green","delta":null,"steadyWeeks":5},
         "line":"Dein Ruhepuls liegt heute im gewohnten Bereich.","briefingLead":null,
         "today":[{"kind":"sleep","label":"Letzte Nacht","value":"7 Std. 12 Min., so lang wie sonst","href":null},
                  {"kind":"vitals","label":"Vitalwerte","value":"4 geprüft, alle im Bereich","href":null}],
         "worthALook":[]}
        """#

        /// Weight this month 0.6 kg under last month's mean.
        private static func range(query: [URLQueryItem]) -> (Int, Data)? {
            guard query.first(where: { $0.name == "type" })?.value == "WEIGHT" else { return nil }
            let window = query.first { $0.name == "range" }?.value ?? "30d"
            let days = ["7d": 7, "30d": 30, "1y": 365][window] ?? 30
            return envelope("""
            {"range":"\(window)","windowDays":\(days),"granularity":"DAY",
             "current":{"count":24,"min":71.8,"max":73.1,"mean":72.4,"sum":1737.6},
             "previous":{"count":22,"min":72.4,"max":73.6,"mean":73.0,"sum":1606.0},
             "delta":-0.6,"deltaPct":-0.0082,"trend":"down"}
            """)
        }

        /// The sweep's magnesium series with the personal target on it.
        private static func daily(query: [URLQueryItem]) -> (Int, Data)? {
            guard query.first(where: { $0.name == "nutrient" })?.value == "magnesium",
                  let base = SweepWorldFixtures.response(forPath: "/api/nutrients/daily", method: "GET", query: query),
                  var body = (try? JSONSerialization.jsonObject(with: base.body)) as? [String: Any],
                  var data = body["data"] as? [String: Any] else { return nil }
            data["personalTarget"] = ["value": 400, "direction": "target"]
            body["data"] = data
            return (try? JSONSerialization.data(withJSONObject: body)).map { (200, $0) }
        }
    }
#endif
