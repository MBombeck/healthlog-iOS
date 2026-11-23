#if DEBUG
    import Foundation

    /// **A check-up whose target is blood ketones.**
    /// Under `-uitest-ketone-reminder` the fixture server answers
    /// `GET /api/measurement-reminders` with one weekly Vorsorge that targets
    /// `BLOOD_KETONES` under its own title, and the type-scoped
    /// `GET /api/measurements?type=BLOOD_KETONES` with a week of readings for its
    /// detail. Dates are relative to today. Invented values only.
    enum KetoneReminderFixtures {
        static let argument = "-uitest-ketone-reminder"
        static let reminderID = "sweep-ketone-reminder"

        static func response(forPath path: String, query: [URLQueryItem]) -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
            switch path {
            case "/api/measurement-reminders":
                return (200, Data(reminders.utf8))
            case "/api/measurements" where query.first(where: { $0.name == "type" })?.value == "BLOOD_KETONES":
                return (200, Data(readings.utf8))
            default:
                return nil
            }
        }

        private static func iso(dayOffset: Int, hour: Int) -> String {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: .now)) ?? .now
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static var reminders: String {
            """
            [{"id":"\(reminderID)","label":"Ketone vor dem Frühstück","measurementType":"BLOOD_KETONES",\
            "intervalDays":7,"rrule":null,"anchorDate":null,"endsOn":null,"origin":"VORSORGE","notifyHour":8,\
            "location":null,"nextDueAt":"\(iso(dayOffset: 2, hour: 8))","lastSatisfiedAt":"\(iso(dayOffset: -5, hour: 8))",\
            "snoozedUntil":null,"lastSkippedAt":null,"skipCount":0,"enabled":true}]
            """
        }

        private static let values: [Double] = [0.4, 0.6, 0.5, 0.8, 0.7, 0.5, 0.6]

        private static var readings: String {
            let rows = values.enumerated().map { offset, value in
                let at = iso(dayOffset: -offset, hour: 7)
                return """
                {"id":"sweep-ketone-\(offset)","userId":"hermetic-user","type":"BLOOD_KETONES","value":\(value),\
                "unit":"mmol/L","measuredAt":"\(at)","notes":null,"source":"MANUAL","glucoseContext":null,\
                "externalId":null,"createdAt":"\(at)","updatedAt":"\(at)"}
                """
            }
            return "{\"measurements\":[\(rows.joined(separator: ","))]}"
        }
    }
#endif
