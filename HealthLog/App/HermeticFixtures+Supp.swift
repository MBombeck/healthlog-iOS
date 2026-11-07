#if DEBUG
    import Foundation

    /// **SUPP (1.5.0, #131) — a supplement's composition and the nutrient
    /// split by source.**
    ///
    /// Under `-uitest-supp` (with `-uitest-area-meds`) the medication list
    /// gains one supplement ("Vitamin D3", two capsules a dose, 25 µg vitamin D
    /// entered as 1000 IU, plus DHA and magnesium per capsule), its single read
    /// carries `ingredients`, and the nutrient routes answer with the server's
    /// split: vitamin D 50 µg all from the supplement (the #131 acceptance
    /// day), magnesium from Apple Health and the supplement with the supplement
    /// share above its upper limit, and DHA. Everything is invented; no value
    /// of any real person appears here. `nil` for every other route.
    enum SuppFixtures {
        static let argument = "-uitest-supp"
        static let medicationID = "supp-med-d3"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        /// The supplement's list row, appended to the area list.
        static var listRows: [[String: Any]] {
            guard isActive,
                  let row = (try? JSONSerialization.jsonObject(with: Data(listRowJSON.utf8))) as? [String: Any] else { return [] }
            return [row]
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard isActive, method == "GET" else { return nil }
            switch path {
            case "/api/medications/\(medicationID)":
                return envelope(detailJSON)
            case "/api/nutrients":
                return envelope(overviewJSON)
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

        // MARK: - Medication

        private static let base = """
        "id": "\(medicationID)", "name": "Vitamin D3", "dose": "2 Kapseln", "unitsPerDose": 2,
        "category": "SUPPLEMENT", "active": true, "notificationsEnabled": false, "deliveryForm": "ORAL",
        "trackIntake": true, "createdAt": "2026-09-01T08:00:00.000Z",
        "schedules": [ { "windowStart": "08:00", "timesOfDay": ["08:00"], "scheduleType": "SCHEDULED" } ],
        "hasIngredients": true
        """

        private static var listRowJSON: String {
            "{ \(base) }"
        }

        private static func ingredient(
            _ code: String, _ amount: Double, _ unit: String, _ label: String,
            entered: (Double, String)? = nil
        ) -> String {
            let enteredAmount = entered.map { "\($0.0)" } ?? "null"
            let enteredUnit = entered.map { "\"\($0.1)\"" } ?? "null"
            return #"{"nutrient":"\#(code)","amountPerUnit":\#(amount),"unit":"\#(unit)","enteredAmount":\#(enteredAmount),"#
                + #""enteredUnit":\#(enteredUnit),"labelKey":"nutrients.names.\#(code)","label":"\#(label)"}"#
        }

        private static var detailJSON: String {
            // The server labels in the account language; this world's account
            // speaks German.
            let lines = [
                ingredient("vitamin_d", 25, "ug", "Vitamin D", entered: (1000, "IU")),
                ingredient("magnesium", 175, "mg", "Magnesium"),
                ingredient("dha", 125, "mg", "DHA (Omega-3)")
            ]
            return "{ \(base), \"ingredients\": [\(lines.joined(separator: ","))] }"
        }

        // MARK: - Nutrients

        private static func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) ?? .now
            return ProfileDay.key(for: date, timeZone: .current)
        }

        private static let magnesiumLimit =
            #"{"value":250,"unit":"mg","scope":"supplemental","form":"magnesium_salts","source":"EFSA 2006"}"#
        private static let vitaminDLimit =
            #"{"value":100,"unit":"ug","scope":"total","form":null,"source":"EFSA 2023"}"#

        private static var overviewJSON: String {
            """
            {"windowDays":90,"lastAttempt":null,"nutrients":[
             {"nutrient":"vitamin_d","unit":"ug","latestDay":"\(day(0))","latestAmount":50,"daysWithData":14,
              "latestBySource":{"SUPPLEMENT":50},"upperLimit":\(vitaminDLimit),"latestAboveUpperLimit":false},
             {"nutrient":"magnesium","unit":"mg","latestDay":"\(day(0))","latestAmount":520,"daysWithData":14,
              "latestBySource":{"APPLE_HEALTH":170,"SUPPLEMENT":350},"upperLimit":\(magnesiumLimit),
              "latestAboveUpperLimit":true},
             {"nutrient":"dha","unit":"mg","latestDay":"\(day(0))","latestAmount":250,"daysWithData":14,
              "latestBySource":{"SUPPLEMENT":250},"upperLimit":null,"latestAboveUpperLimit":null}
            ]}
            """
        }

        /// One nutrient's daily answer: unit, today's split, limit, reference.
        private struct DailySpec {
            let unit: String
            let today: String
            let limit: String
            let reference: String
        }

        private static func dailySpec(_ code: String) -> DailySpec? {
            switch code {
            case "vitamin_d":
                DailySpec(
                    unit: "ug",
                    today: #"{"SUPPLEMENT":50}"#,
                    limit: vitaminDLimit,
                    reference: #"{"kind":"AI","direction":"target","value":15,"source":"EFSA DRV 2016"}"#
                )
            case "magnesium":
                DailySpec(
                    unit: "mg",
                    today: #"{"APPLE_HEALTH":170,"SUPPLEMENT":350}"#,
                    limit: magnesiumLimit,
                    reference: #"{"kind":"AI","direction":"target","value":350,"source":"EFSA DRV 2015"}"#
                )
            case "dha":
                DailySpec(unit: "mg", today: #"{"SUPPLEMENT":250}"#, limit: "null", reference: "null")
            default:
                nil
            }
        }

        private static func dailyJSON(_ code: String) -> String? {
            guard let spec = dailySpec(code) else { return nil }
            let today = code == "vitamin_d" ? 50 : code == "magnesium" ? 520 : 250
            let above = code == "magnesium" ? "true" : code == "dha" ? "null" : "false"
            let days = (0 ..< 14).reversed().map { offset -> String in
                offset == 0
                    ? #"{"day":"\#(day(0))","amount":\#(today),"bySource":\#(spec.today),"aboveUpperLimit":\#(above)}"#
                    : #"{"day":"\#(day(offset))","amount":\#(offset % 2 == 0 ? today : 0)}"#
            }
            return """
            {"nutrient":"\(code)","unit":"\(spec.unit)","windowDays":30,"days":[\(days.joined(separator: ","))],
             "reference":\(spec.reference),"upperLimit":\(spec.limit)}
            """
        }
    }
#endif
