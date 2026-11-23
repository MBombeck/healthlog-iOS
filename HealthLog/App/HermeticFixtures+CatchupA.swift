#if DEBUG
    import Foundation

    /// **#191 catch-up A — a night and readings abroad, a watch's figures.**
    ///
    /// Under `-uitest-catchup-a` the fixture server answers three reads the
    /// sweep's world leaves bare, all in the 1.49.0 shapes:
    /// - `GET /api/sleep/night`: last night slept in New York
    ///   (`main.timeZone`), with a measured hypnogram and one nap there too;
    /// - `GET /api/measurements?type=WEIGHT`: a week of weight, the two
    ///   newest readings taken in New York (`timeZone`), the rest at home;
    /// - `GET /api/workouts` and `GET /api/workouts/{id}`: one run whose detail
    ///   carries the `performance` object (one figure left `null`).
    /// Everything is invented; no value of any real person appears here. `nil`
    /// for every other route.
    enum CatchupAFixtures {
        static let argument = "-uitest-catchup-a"
        static let workoutID = "catchup-run-1"

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET", ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
            switch path {
            case "/api/sleep/night":
                return envelope(sleepNightJSON)
            case "/api/measurements" where query.contains { $0.name == "type" && $0.value == "WEIGHT" }:
                return (200, Data(#"{"measurements":[\#(weightRows.joined(separator: ","))]}"#.utf8))
            case "/api/workouts":
                return envelope(#"{"workouts":[\#(workoutJSON(detail: false))],"#
                    + #""meta":{"total":1,"limit":50,"offset":0,"droppedDuplicates":0}}"#)
            case "/api/workouts/\(workoutID)":
                return envelope(workoutJSON(detail: true))
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        // MARK: - Sleep

        /// 04:10 to 11:40 on a Berlin device clock, 22:10 to 05:40 in New York:
        /// the screen must show the New York times.
        private static var sleepNightJSON: String {
            let wake = dayKey(daysAgo: 0)
            let start = stamp(daysAgo: 0, hour: 4, minute: 10)
            let end = stamp(daysAgo: 0, hour: 11, minute: 40)
            let segments = [
                ("CORE", 0, 70), ("DEEP", 70, 55), ("CORE", 125, 80), ("REM", 205, 35),
                ("AWAKE", 240, 6), ("CORE", 246, 110), ("REM", 356, 40), ("CORE", 396, 54)
            ].map { stage, from, minutes in
                #"{"stage":"\#(stage)","start":"\#(offset(start, from))","end":"\#(offset(start, from + minutes))","minutes":\#(minutes)}"#
            }
            let napStart = stamp(daysAgo: 0, hour: 19, minute: 0)
            let napEnd = stamp(daysAgo: 0, hour: 19, minute: 30)
            return #"{"main":{"night":"\#(wake)","timeZone":"America/New_York","source":"APPLE_HEALTH","#
                + #""start":"\#(start)","end":"\#(end)","asleepMinutes":444,"inBedMinutes":450,"awakeMinutes":6,"#
                + #""awakenings":1,"reconstructed":false,"stages":{"CORE":314,"DEEP":55,"REM":75,"AWAKE":6},"#
                + #""segments":[\#(segments.joined(separator: ","))]},"#
                + #""naps":[{"night":"\#(wake)","timeZone":"America/New_York","source":"APPLE_HEALTH","#
                + #""start":"\#(napStart)","end":"\#(napEnd)","asleepMinutes":30,"inBedMinutes":30,"awakeMinutes":0,"#
                + #""awakenings":0,"stages":{"ASLEEP":30},"segments":[{"stage":"ASLEEP","start":"\#(napStart)","#
                + #""end":"\#(napEnd)","minutes":30}]}]}"#
        }

        // MARK: - Weight

        private static var weightRows: [String] {
            (0 ..< 7).map { daysAgo in
                let at = stamp(daysAgo: daysAgo, hour: 13, minute: 15)
                let zone = daysAgo < 2 ? #""America/New_York""# : "null"
                let value = 78.4 - Double(daysAgo) * 0.1
                return #"{"id":"catchup-w-\#(daysAgo)","userId":"hermetic-user","type":"WEIGHT","value":\#(value),"#
                    + #""unit":"kg","measuredAt":"\#(at)","notes":null,"source":"APPLE_HEALTH","glucoseContext":null,"#
                    + #""externalId":null,"createdAt":"\#(at)","updatedAt":"\#(at)","timeZone":\#(zone)}"#
            }
        }

        // MARK: - Workout

        private static func workoutJSON(detail: Bool) -> String {
            let start = stamp(daysAgo: 1, hour: 7, minute: 0)
            let end = stamp(daysAgo: 1, hour: 7, minute: 48)
            let performance = detail
                ? #","performance":{"aerobicTrainingEffect":3.4,"anaerobicTrainingEffect":1.2,"trainingLoad":148,"#
                + #""recoveryTimeMin":1260,"sweatLossMl":720,"avgPowerW":284,"avgVerticalOscillationMm":86,"#
                + #""avgGroundContactTimeMs":242,"avgGroundContactBalancePct":null}"#
                : ""
            return #"{"id":"\#(workoutID)","sportType":"running","startedAt":"\#(start)","endedAt":"\#(end)","#
                + #""durationSec":2880,"distanceM":9200,"activeEnergyKcal":610,"avgHr":151,"maxHr":176,"#
                + #""source":"GARMIN","externalId":"fit:catchup-1"\#(performance)}"#
        }

        // MARK: - Time

        private static var calendar: Calendar {
            Calendar(identifier: .gregorian)
        }

        private static func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day) ?? day
        }

        private static func stamp(daysAgo: Int, hour: Int, minute: Int) -> String {
            iso(date(daysAgo: daysAgo, hour: hour, minute: minute))
        }

        private static func offset(_ stamp: String, _ minutes: Int) -> String {
            let formatter = ISO8601DateFormatter()
            let base = formatter.date(from: stamp) ?? .now
            return iso(base.addingTimeInterval(TimeInterval(minutes * 60)))
        }

        private static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }

        private static func dayKey(daysAgo: Int) -> String {
            MovementDay.today(now: date(daysAgo: daysAgo, hour: 12, minute: 0))
        }
    }
#endif
