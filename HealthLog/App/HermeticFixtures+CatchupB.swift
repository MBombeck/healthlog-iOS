#if DEBUG
    import Foundation

    /// **Server 1.49.0 on the app side, part B, photographed** (#191).
    ///
    /// Under `-uitest-catchup-b` (with `-uitest-sweep`) the sweep account
    /// gains what a 1.49 server sends: the energy balance under Ernährung
    /// (seven closed days, one of them on an estimated resting figure, one
    /// without a balance, today still running), the notable-value row in the
    /// notification matrix (off, as the server's default) and a nutrient
    /// target refused with its allowed range. Invented values only. `nil` for
    /// every other route.
    enum CatchupBFixtures {
        static let argument = "-uitest-catchup-b"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive else { return nil }
            switch (method, path) {
            case ("GET", "/api/nutrients/energy-balance"): return envelope(energyBalanceJSON())
            case ("GET", "/api/notifications/preferences"): return (200, Data(preferencesJSON.utf8))
            case ("PATCH", "/api/nutrients/targets"): return (422, Data(refusedTargetJSON.utf8))
            default: return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func dayKey(_ offset: Int) -> String {
            let calendar = Calendar.current
            let date = calendar.date(byAdding: .day, value: offset, to: Date.now) ?? Date.now
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        }

        /// Seven closed days and today, oldest first.
        static func energyBalanceJSON() -> String {
            // swiftlint:disable:next large_tuple
            let rows: [(Int, String, String, String, String, String, String, String)] = [
                (-7, "2100", "1650", "false", "500", "2150", "-50", "null"),
                (-6, "2400", "1600", "true", "400", "2000", "400", "null"),
                (-5, "null", "1650", "false", "300", "1950", "null", "null"),
                (-4, "1900", "1650", "false", "450", "2100", "-200", "null"),
                (-3, "2000", "1650", "false", "250", "1900", "100", "63"),
                (-2, "2150", "1650", "false", "350", "2000", "150", "100"),
                (-1, "2050", "1650", "false", "500", "2150", "-100", "60")
            ]
            var days = rows.map { offset, intake, resting, estimated, active, used, balance, trend in
                """
                {"day":"\(dayKey(offset))","intakeKcal":\(intake),"restingKcal":\(resting),"restingEstimated":\(estimated),\
                "activeKcal":\(active),"expenditureKcal":\(used),"balanceKcal":\(balance),"trendKcal":\(trend),"partial":false}
                """
            }
            days.append("""
            {"day":"\(dayKey(0))","intakeKcal":900,"restingKcal":1650,"restingEstimated":false,\
            "activeKcal":120,"expenditureKcal":1770,"balanceKcal":-870,"trendKcal":null,"partial":true}
            """)
            return """
            {"windowDays":30,"days":[\(days.joined(separator: ","))],
             "summary":{"daysWithBalance":6,"meanIntakeKcal":2100,"meanExpenditureKcal":2050,"meanBalanceKcal":50},
             "estimateGaps":[]}
            """
        }

        static let channelID = "catchup-b-apns"

        static let eventTypes = ["DAILY_BRIEFING", "MEDICATION_REMINDER", "INSIGHT_READY", "MEASUREMENT_ANOMALY", "SYSTEM_ALERT"]

        static var preferencesJSON: String {
            let preferences = eventTypes.map {
                #"{"channelId":"\#(channelID)","eventType":"\#($0)","enabled":\#($0 != "MEASUREMENT_ANOMALY")}"#
            }
            return """
            {
              "channels": [
                { "id": "\(channelID)", "type": "APNS", "label": "iPhone", "enabled": true, "globallyEnabled": true }
              ],
              "preferences": [\(preferences.joined(separator: ","))],
              "eventTypes": [\(eventTypes.map { "\"\($0)\"" }.joined(separator: ","))],
              "mood": { "reminderHour": 20 }
            }
            """
        }

        static let refusedTargetJSON = """
        {"data":null,"error":"Validation failed",
         "details":{"issues":[{"path":"targets.magnesium.value","code":"too_big","message":"Too big",
          "maximum":5000,"inclusive":true,"origin":"number"}]},
         "meta":{"requestId":"req-catchup-b","errorCode":"validation_failed"}}
        """
    }
#endif
