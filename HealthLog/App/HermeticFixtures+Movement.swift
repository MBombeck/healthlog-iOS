#if DEBUG
    import Foundation

    /// **1.5 MOVE — a Dawarich connection for the screenshot sweep.** Under
    /// `-uitest-move` the fixture server has a home and weather coverage
    /// (`GET /api/environment`), a connected Dawarich (`latestDay`
    /// 2026-11-03, `oldestDay` 2026-10-30) and a `movement` block per day:
    /// 3 November with every row and a travel day in the Netherlands,
    /// 2 November without coverage (no "time away"), 1 November without any
    /// value, 31 October with a train leg, so stepping back crosses a month.
    /// `-uitest-move-disconnected` answers "not connected" instead. The
    /// integrations status lists Dawarich with its health. `nil` everywhere
    /// else; without the argument the status route answers 404 like a server
    /// before v1.43. Invented values only.
    enum MovementFixtures {
        static let argument = "-uitest-move"
        static let disconnectedArgument = "-uitest-move-disconnected"

        static func response(forPath path: String) -> (status: Int, body: Data)? {
            let args = ProcessInfo.processInfo.arguments
            let disconnected = args.contains(disconnectedArgument)
            guard args.contains(argument) || disconnected else {
                // The sweep's own server is older than Dawarich (before v1.43):
                // the status route does not exist, so the section stays away.
                return path == "/api/dawarich/status" ? (404, Data(#"{"data":null,"error":"Not found"}"#.utf8)) : nil
            }
            let body: String? = switch path {
            case "/api/environment": environmentJSON
            case "/api/dawarich/status": disconnected ? disconnectedStatusJSON : statusJSON
            case "/api/integrations/status": integrationsJSON(connected: !disconnected)
            default: path.hasPrefix("/api/day/") ? dayJSON(String(path.dropFirst("/api/day/".count))) : nil
            }
            return body.map { (200, Data($0.utf8)) }
        }

        private static let environmentJSON = #"{"data":{"home":{"label":"Bochum","lat":51.48,"lon":7.22,"since":"2025-03-01"},"#
            + #""travel":[],"context":{"days":412,"latestDate":"2026-11-04","latestFetchedAt":null},"#
            + #""attribution":"Weather data by Open-Meteo.com"},"error":null}"#

        private static let statusJSON = #"{"data":{"connected":true,"configured":true,"homePlaceSet":true,"homeCountry":"DE","#
            + #""daysStored":5,"oldestDay":"2026-10-30","latestDay":"2026-11-03","#
            + #""health":{"state":"ok","reason":"data_arriving","since":null,"action":null,"unavailable":[]}},"error":null}"#

        private static let disconnectedStatusJSON = #"{"data":{"connected":false,"configured":false,"homePlaceSet":false,"#
            + #""homeCountry":null,"daysStored":0,"oldestDay":null,"latestDay":null,"health":null},"error":null}"#

        private static func integrationsJSON(connected: Bool) -> String {
            let health = connected
                ? #"{"state":"ok","reason":"data_arriving","since":null,"action":null,"unavailable":[]}"#
                : "null"
            return #"{"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":["#
                + #"{"integration":"withings","connected":false,"health":null},"#
                + #"{"integration":"dawarich","connected":\#(connected),"health":\#(health)}]},"error":null}"#
        }

        private static func dayJSON(_ day: String) -> String {
            let movement = switch day {
            case "2026-11-03":
                movementJSON(
                    total: "42.7",
                    driving: "31.2",
                    train: "null",
                    places: "6",
                    away: "412",
                    travel: #"{"isTravelDay":true,"countryCode":"NL"}"#
                )
            case "2026-11-02":
                movementJSON(total: "8.4", driving: "null", train: "null", places: "3", away: "null", travel: "null")
            case "2026-10-31":
                movementJSON(
                    total: "126.3",
                    driving: "4.1",
                    train: "118.9",
                    places: "4",
                    away: "655",
                    travel: #"{"isTravelDay":false,"countryCode":null}"#
                )
            default:
                movementJSON(total: "null", driving: "null", train: "null", places: "null", away: "null", travel: "null")
            }
            return #"{"data":{"date":"\#(day)","tz":"Europe/Berlin","movement":\#(movement)},"error":null}"#
        }

        // swiftlint:disable:next function_parameter_count
        private static func movementJSON(
            total: String,
            driving: String,
            train: String,
            places: String,
            away: String,
            travel: String
        ) -> String {
            #"{"source":"dawarich","distance":{"unit":"km","total":\#(total),"driving":\#(driving),"train":\#(train)},"#
                + #""placesVisited":\#(places),"awayFromHomeMinutes":\#(away),"travel":\#(travel),"#
                + #""fetchedAt":"2026-11-04T05:00:00.000Z"}"#
        }
    }
#endif
