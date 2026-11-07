#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// **1.5 VERDICTS.** `-uitest-verdicts` — a server that judges every
        /// trend itself (v1.47 shape). Only the QA sweep's
        /// `test_19v_verdicts` passes it, together with `-uitest-sweep`.
        static let verdictsOverlayArgument = "-uitest-verdicts"

        static var isVerdictsOverlayActive: Bool {
            isSweepOverlayActive && ProcessInfo.processInfo.arguments.contains(verdictsOverlayArgument)
        }
    }

    /// **1.5 VERDICTS — the trend colours as the server judges them.**
    ///
    /// The dashboard summary carries `trendSentiment` on some cards and not on
    /// others, the snapshot carries `tiles.directions`, the blood pressure
    /// target sits above the person's own band (`direction: up-bad`), the
    /// weight and blood pressure series carry `change`, the pulse series has
    /// a verdict but no change, glucose stays on the older shape, and the mood
    /// summary has no slope (`null`, #151). Everything else falls through
    /// to the sweep and marketing tables. Invented values only.
    enum VerdictFixtures {
        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            switch path {
            case "/api/dashboard/summary": return summary()
            case "/api/dashboard/snapshot": return ok(snapshotJSON)
            case "/api/insights/targets": return ok(targetsJSON)
            case "/api/insights/comprehensive": return ok(comprehensiveJSON)
            case "/api/mood/analytics": return ok(moodAnalyticsJSON)
            case "/api/measurements/series": return series(query: query)
            default: return nil
            }
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        private static func object(_ body: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        private static func encoded(_ object: [String: Any]) -> (Int, Data)? {
            (try? JSONSerialization.data(withJSONObject: object)).map { (200, $0) }
        }

        /// The marketing summary with the v1.43 fields on four cards: weight
        /// and steps carry the server's verdict, blood pressure and resting
        /// pulse only their trend (their colour comes from the target and from
        /// `tiles.directions`), the rest stays on the older shape.
        private static func summary() -> (Int, Data)? {
            guard var summary = object(Data(MarketingFixtures.summaryJSON.utf8)),
                  let metrics = summary["metrics"] as? [[String: Any]] else { return nil }
            let patch: [String: [String: Any]] = [
                "weight": ["trend": "down", "trendSentiment": "positive"],
                "steps": ["trend": "up", "trendSentiment": "positive"],
                "bloodPressure": ["trend": "up"],
                "restingHeartRate": ["trend": "down"],
                "pulse": ["trend": "up"]
            ]
            summary["metrics"] = metrics.map { metric in
                guard let kind = metric["kind"] as? String, let fields = patch[kind] else { return metric }
                return metric.merging(fields) { _, new in new }
            }
            return encoded(summary)
        }

        private static func verdict(_ direction: String, _ position: String?, _ basis: String) -> String {
            let place = position.map { "\"\($0)\"" } ?? "null"
            return #"{"direction":"\#(direction)","targetPosition":\#(place),"basis":"\#(basis)"}"#
        }

        private static var snapshotJSON: String {
            """
            {"briefingState":"no-provider","briefingStale":false,"tiles":{
              "weightTrend":\(verdict("up-bad", "inside", "personal_target")),
              "directions":{
                "WEIGHT":\(verdict("up-bad", "inside", "personal_target")),
                "BLOOD_PRESSURE_SYS":\(verdict("up-bad", "above", "profile_default")),
                "RESTING_HEART_RATE":\(verdict("up-bad", "inside", "metric_default")),
                "PULSE":\(verdict("hold", "inside", "metric_default")),
                "ACTIVITY_STEPS":\(verdict("up-good", "below", "metric_default"))
              }}}
            """
        }

        /// The person's own blood pressure target, the current value above it:
        /// a rise counts against them.
        private static var targetsJSON: String {
            """
            {"targets":[{
              "type":"BLOOD_PRESSURE","label":"Blood pressure","current":126,"average30":124,"trend":"up",
              "unit":"mmHg","range":{"min":100,"max":120},"classification":{"category":"Elevated","color":"var(--warning)"},
              "source":"personal","daysInRange7d":2,"daysLogged7d":7,"daysInRange30d":11,"daysLogged30d":30,
              "lastMetGoalAt":null,"streakDays":0,"insufficientData":false,
              "consistency7d":["in","near","out","out","near","out","in"],
              "direction":\(verdict("up-bad", "above", "personal_target")),"trendSentiment":"negative"
            }],"pageSummary":{"targetsMetThisWeek":0,"totalTargets":1,"streakHighlight":null},
            "bpDiastolic":{"current":82,"average30":80,"range":{"min":60,"max":80}},"profile":null}
            """
        }

        /// #151 — the seven-day slope is `null` (too few days), the 30-day
        /// one is there.
        private static let comprehensiveJSON = """
        {"summaries":{
          "WEIGHT":{"count":30,"latest":72.4,"avg30":72.6,
            "slope7":null,"slope30":{"slope":-0.02,"direction":"down","confidence":0.6}},
          "BLOOD_PRESSURE_SYS":{"count":30,"latest":126,"avg30":124,
            "slope7":{"slope":null,"direction":null,"confidence":null},
            "slope30":{"slope":0.2,"direction":"up","confidence":0.5}}
        }}
        """

        /// #151 — the mood summary without a slope: no trend, no arrow.
        private static let moodAnalyticsJSON = """
        {"entries":[],"summary":{"slope7":null,"slope30":null,"slope90":null,"avg30LastMonth":null,"avg30LastYear":null}}
        """

        /// The sweep's series with the v1.43 verdict fields: weight fell and
        /// that is good, blood pressure rose and that is bad, pulse has a
        /// verdict but no change (the server's "under two days" answer), the
        /// rest keeps the older shape.
        private static func series(query: [URLQueryItem]) -> (Int, Data)? {
            guard let base = SweepFixtures.response(forPath: "/api/measurements/series", method: "GET", query: query),
                  var series = object(base.body),
                  let kind = series["kind"] as? String else { return nil }
            func change(_ from: Double, _ to: Double, _ sentiment: String) -> [String: Any] {
                ["from": from, "to": to, "delta": to - from, "sentiment": sentiment]
            }
            func direction(_ word: String, _ position: String, _ basis: String) -> [String: Any] {
                ["direction": word, "targetPosition": position, "basis": basis]
            }
            switch kind {
            case "weight":
                series["direction"] = direction("up-bad", "inside", "personal_target")
                series["change"] = change(73.0, 72.4, "positive")
                series["referenceLines"] = [Any]()
            case "bloodPressure":
                series["direction"] = direction("up-bad", "above", "personal_target")
                series["change"] = change(118, 126, "negative")
                series["referenceLines"] = [Any]()
            case "pulse":
                series["direction"] = direction("hold", "inside", "metric_default")
                series["change"] = NSNull()
                series["referenceLines"] = [Any]()
            default:
                return base
            }
            return encoded(series)
        }
    }
#endif
