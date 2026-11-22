#if DEBUG
    import Foundation

    /// **The rest of the sweep account, so its pages agree with each other.**
    ///
    /// Under `-uitest-sweep`, after ``SweepFixtures`` has answered the
    /// readings: the Health Score composition a server resolves for an account
    /// that never chose (every pillar counts), the one overdue check-up the
    /// Today hint names, and a fortnight of nutrients from Apple Health, so
    /// the nutrient list (the reference page for lists) has rows. Before, the
    /// first fell through to the `/me` row and read as "all pillars off", the
    /// second answered an empty list beside a hint about an open check-up,
    /// and the third answered nothing. Dates follow the simulator clock.
    /// Invented values only. `nil` for every other route.
    enum SweepWorldFixtures {
        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            switch path {
            case "/api/auth/me/health-score-config":
                return envelope(healthScoreConfigJSON)
            case "/api/measurement-reminders":
                return (200, Data(remindersJSON.utf8))
            case "/api/nutrients":
                return envelope(nutrientOverviewJSON)
            case "/api/nutrients/daily":
                let code = query.first { $0.name == "nutrient" }?.value ?? ""
                return dailyJSON(code).map(envelope)
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        // MARK: - Health Score

        /// No selection yet: the server counts all eight pillars.
        static let healthScoreConfigJSON = """
        {"pillars":["BLOOD_PRESSURE","GLYCAEMIA","ACTIVITY","SLEEP","ADIPOSITY","WELLBEING","FITNESS","LIPIDS"],\
        "excludedPillars":[],"hasSelection":false,"version":1}
        """

        // MARK: - Check-up

        static let reminderID = "sweep-waist-checkup"

        private static func iso(dayOffset: Int, hour: Int) -> String {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: .now)) ?? .now
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }

        /// A quarterly waist measurement, due two weeks ago (the hint's
        /// wording), last met about three and a half months back. A type the
        /// sweep has no readings for, so nothing on the measurement pages
        /// contradicts "overdue".
        private static var remindersJSON: String {
            """
            [{"id":"\(reminderID)","label":"Taillenumfang","measurementType":"WAIST_CIRCUMFERENCE",\
            "intervalDays":90,"rrule":null,"anchorDate":null,"endsOn":null,"origin":"VORSORGE","notifyHour":8,\
            "location":null,"nextDueAt":"\(iso(dayOffset: -14, hour: 8))","lastSatisfiedAt":"\(iso(dayOffset: -104, hour: 8))",\
            "snoozedUntil":null,"lastSkippedAt":null,"skipCount":0,"enabled":true}]
            """
        }

        // MARK: - Nutrients

        private struct Nutrient {
            let code: String
            let unit: String
            let today: Double
            /// The everyday reference (EFSA adequate intake or average requirement).
            let reference: Double
        }

        private static let nutrients = [
            Nutrient(code: "magnesium", unit: "mg", today: 310, reference: 350),
            Nutrient(code: "calcium", unit: "mg", today: 860, reference: 950),
            Nutrient(code: "vitamin_c", unit: "mg", today: 95, reference: 95),
            Nutrient(code: "iron", unit: "mg", today: 11, reference: 11),
            Nutrient(code: "zinc", unit: "mg", today: 9.4, reference: 8.9)
        ]

        private static let days = 14

        private static func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) ?? .now
            return ProfileDay.key(for: date, timeZone: .current)
        }

        /// A calm day-to-day wobble around today's amount, never random.
        private static func amount(_ nutrient: Nutrient, _ offset: Int) -> Double {
            let value = nutrient.today * (1 + 0.12 * sin(Double(offset) * 0.9))
            return (value * 10).rounded() / 10
        }

        private static var nutrientOverviewJSON: String {
            let rows = nutrients.map { nutrient in
                """
                {"nutrient":"\(nutrient.code)","unit":"\(nutrient.unit)","latestDay":"\(day(0))",\
                "latestAmount":\(nutrient.today),"daysWithData":\(days),\
                "latestBySource":{"APPLE_HEALTH":\(nutrient.today)},"upperLimit":null,"latestAboveUpperLimit":null}
                """
            }
            return #"{"windowDays":90,"lastAttempt":null,"nutrients":[\#(rows.joined(separator: ","))]}"#
        }

        private static func dailyJSON(_ code: String) -> String? {
            guard let nutrient = nutrients.first(where: { $0.code == code }) else { return nil }
            let rows = (0 ..< days).reversed().map { offset in
                let value = amount(nutrient, offset)
                return #"{"day":"\#(day(offset))","amount":\#(value),"bySource":{"APPLE_HEALTH":\#(value)},"aboveUpperLimit":null}"#
            }
            let reference = #"{"kind":"AI","direction":"target","value":\#(nutrient.reference),"source":"EFSA DRV"}"#
            return """
            {"nutrient":"\(nutrient.code)","unit":"\(nutrient.unit)","windowDays":30,"days":[\(rows.joined(separator: ","))],
             "reference":\(reference),"upperLimit":null}
            """
        }
    }
#endif
