#if DEBUG
    import Foundation

    /// **1.5 BP-TOD — a 1.47 server with blood pressure by time of day.**
    /// Under `-uitest-bp-tod` the fixture server reports version 1.47.0 and
    /// answers `GET /api/measurements/blood-pressure/time-of-day` per range:
    /// 30 days with all three parts and a difference, 7 days with midday and
    /// evening below the floor (no difference), 180 days with a zero
    /// difference, 1 day without any reading. `nil` everywhere else and
    /// without the argument. Invented values only.
    enum BloodPressureTimeOfDayFixtures {
        static let argument = "-uitest-bp-tod"

        static func response(forPath path: String, query: [URLQueryItem]) -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
            switch path {
            case "/api/version":
                return (200, Data(#"{"data":{"version":"1.47.0"},"error":null}"#.utf8))
            case "/api/measurements/blood-pressure/time-of-day":
                let days = query.first { $0.name == "days" }?.value.flatMap(Int.init) ?? 30
                return (200, Data(body(days: days).utf8))
            default:
                return nil
            }
        }

        private static func part(
            _ name: String,
            _ start: Int,
            _ end: Int,
            _ count: Int,
            _ sys: Int?,
            _ dia: Int?,
            _ pulse: Int?
        ) -> String {
            func value(_ number: Int?) -> String {
                number.map(String.init) ?? "null"
            }
            return #"{"part":"\#(name)","startHour":\#(start),"endHour":\#(end),"readingCount":\#(count),"#
                + #""systolic":\#(value(sys)),"diastolic":\#(value(dia)),"pulseReadingCount":\#(pulse == nil ? 0 : count),"pulse":\#(value(pulse))}"#
        }

        private static func body(days: Int) -> String {
            let parts: [String]
            let difference: String
            switch days {
            case 1:
                parts = [
                    part("morning", 4, 12, 0, nil, nil, nil),
                    part("midday", 12, 18, 0, nil, nil, nil),
                    part("evening", 18, 4, 0, nil, nil, nil)
                ]
                difference = "null"
            case 7:
                parts = [
                    part("morning", 4, 12, 6, 136, 87, 67),
                    part("midday", 12, 18, 2, nil, nil, nil),
                    part("evening", 18, 4, 1, nil, nil, nil)
                ]
                difference = "null"
            case 180:
                parts = [
                    part("morning", 4, 12, 140, 131, 84, 65),
                    part("midday", 12, 18, 31, 127, 81, 72),
                    part("evening", 18, 4, 122, 131, 84, 69)
                ]
                difference = #"{"systolic":0,"diastolic":0}"#
            default:
                parts = [
                    part("morning", 4, 12, 24, 134, 86, 66),
                    part("midday", 12, 18, 5, 126, 80, 74),
                    part("evening", 18, 4, 19, 128, 83, 70)
                ]
                difference = #"{"systolic":6,"diastolic":3}"#
            }
            return #"{"data":{"days":\#(days),"from":"2026-10-06T02:00:00.000Z","to":"2026-11-04T22:59:59.999Z","#
                + #""timeZone":"Europe/Berlin","minReadings":3,"readingCount":\#(readingCount(days)),"#
                + #""parts":[\#(parts.joined(separator: ","))],"morningEveningDifference":\#(difference)},"error":null}"#
        }

        private static func readingCount(_ days: Int) -> Int {
            switch days {
            case 1: 0
            case 7: 9
            case 180: 293
            default: 48
            }
        }
    }
#endif
