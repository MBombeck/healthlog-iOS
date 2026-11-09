#if DEBUG
    import Foundation

    /// **iOS 1.4 B4-c — what the medication screens read beyond the list.**
    ///
    /// The B2-b overlay answered the list. Every per-medication route the detail
    /// then reads (`/intake`, `/compliance`, `/glp1`) fell through to the shared
    /// default `[]`, which no detail DTO decodes: the detail wore a red "could not
    /// be read" banner, its adherence said "not available", and the cards had no
    /// adherence bars. These answers are what a server sends for the same
    /// invented medications: thirty days of intakes on the marketing schedules
    /// (two late evenings and one skipped morning, so nothing reads perfect), the
    /// adherence counted from exactly those intakes, an empty GLP-1 journal, and
    /// a blood-pressure comparison around Lisinopril's start.
    ///
    /// Every instant is relative to now and lies in the past. A dose is "taken"
    /// only once its time has passed, so a capture at night no longer shows this
    /// morning's dose as taken before it is due.
    enum AreaMedsDetailFixtures {
        static let lisinoprilID = "mkshot-med-lisinopril"
        static let naproxenID = "mkshot-med-naproxen"
        static let trulicityID = "mkshot-med-trulicity"

        /// One scheduled slot of one medication.
        struct Slot: Equatable {
            let medicationID: String
            let scheduledFor: Date
            /// `nil` when the dose was not taken.
            let takenAt: Date?
            let skipped: Bool
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            if path == "/api/medications/compliance" { return json(batchedCompliance()) }
            if path == "/api/medications/intake" { return json(todayIntakes()) }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "api", parts[1] == "medications" else { return nil }
            let id = parts[2]
            switch parts[3] {
            case "intake":
                let offset = query.first { $0.name == "offset" }.flatMap { Int($0.value ?? "") } ?? 0
                let limit = query.first { $0.name == "limit" }.flatMap { Int($0.value ?? "") } ?? 30
                return json(intakePage(medicationID: id, offset: offset, limit: limit))
            case "compliance":
                return json(compliance(medicationID: id))
            case "glp1" where id == trulicityID:
                return (200, Data(#"{"doseChanges":[],"recentIntakes":[]}"#.utf8))
            case "efficacy" where id == lisinoprilID:
                return (200, Data(efficacyJSON.utf8))
            default:
                return nil
            }
        }

        // MARK: - The invented intake history

        /// Thirty days of slots, newest first, only those already due.
        static func slots(medicationID: String, now: Date = .now, calendar: Calendar = .current) -> [Slot] {
            let today = calendar.startOfDay(for: now)
            var rows: [Slot] = []
            for offset in 0 ..< 30 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                for dose in plan(medicationID: medicationID, day: day, offset: offset, calendar: calendar) {
                    guard let slot = calendar.date(bySettingHour: dose.hour, minute: 0, second: 0, of: day),
                          slot <= now else { continue }
                    let takenAt = slot.addingTimeInterval(300)
                    let taken = !dose.missed && !dose.skipped && takenAt <= now
                    rows.append(Slot(
                        medicationID: medicationID,
                        scheduledFor: slot,
                        takenAt: taken ? takenAt : nil,
                        skipped: dose.skipped
                    ))
                }
            }
            return rows.sorted { $0.scheduledFor > $1.scheduledFor }
        }

        /// One dose of a day's plan.
        private struct Dose {
            let hour: Int
            var missed = false
            var skipped = false
        }

        /// The marketing schedules: Lisinopril daily at 8, Naproxen at 8 and 20,
        /// Trulicity on Mondays at 9. One skipped morning, two missed evenings.
        private static func plan(medicationID: String, day: Date, offset: Int, calendar: Calendar) -> [Dose] {
            switch medicationID {
            case lisinoprilID:
                [Dose(hour: 8, skipped: offset == 12)]
            case naproxenID:
                [Dose(hour: 8), Dose(hour: 20, missed: offset == 3 || offset == 17)]
            case trulicityID:
                calendar.component(.weekday, from: day) == 2 ? [Dose(hour: 9)] : []
            default:
                []
            }
        }

        /// The newest dose actually taken, for the list's "Letzte Einnahme".
        static func lastTakenAt(medicationID: String, now: Date = .now) -> Date? {
            slots(medicationID: medicationID, now: now).first { $0.takenAt != nil }?.takenAt
        }

        /// Doses taken today, the list's `todayEventCount`.
        static func todayEventCount(medicationID: String, now: Date = .now) -> Int {
            let calendar = Calendar.current
            return slots(medicationID: medicationID, now: now).count {
                $0.takenAt != nil && calendar.isDate($0.scheduledFor, inSameDayAs: now)
            }
        }

        // MARK: - Routes

        private static var iso: ISO8601DateFormatter {
            ISO8601DateFormatter()
        }

        private static func json(_ object: Any) -> (Int, Data)? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return (200, data)
        }

        private static func stamp(_ date: Date?) -> Any {
            date.map { iso.string(from: $0) } ?? NSNull()
        }

        /// `GET /api/medications/{id}/intake?limit&offset` — `PaginatedIntakeEnvelope`.
        private static func intakePage(medicationID: String, offset: Int, limit: Int) -> [String: Any] {
            let all = slots(medicationID: medicationID)
            let page = all.dropFirst(offset).prefix(limit)
            let events = page.enumerated().map { index, slot -> [String: Any] in
                [
                    "id": "area-intake-\(medicationID)-\(offset + index)",
                    "takenAt": stamp(slot.takenAt),
                    "skipped": slot.skipped,
                    "scheduledFor": iso.string(from: slot.scheduledFor),
                    "injectionSite": NSNull()
                ]
            }
            return ["events": events, "meta": ["total": all.count, "limit": limit, "offset": offset]]
        }

        /// `GET /api/medications/intake?scope=today` — today's rows, taken only
        /// once their time has passed.
        private static func todayIntakes() -> [[String: Any]] {
            let calendar = Calendar.current
            let now = Date.now
            return [lisinoprilID, naproxenID, trulicityID].flatMap { id -> [[String: Any]] in
                let today = calendar.startOfDay(for: now)
                return plan(medicationID: id, day: today, offset: 0, calendar: calendar).compactMap { dose in
                    guard let slot = calendar.date(bySettingHour: dose.hour, minute: 0, second: 0, of: today) else { return nil }
                    let takenAt = slot.addingTimeInterval(300)
                    let taken = takenAt <= now
                    return [
                        "id": "area-today-\(id)-\(dose.hour)",
                        "medicationId": id,
                        "scheduledAt": iso.string(from: slot),
                        "takenAt": taken ? iso.string(from: takenAt) : NSNull(),
                        "status": taken ? "taken" : "pending",
                        "snoozedUntil": NSNull()
                    ]
                }
            }
        }

        /// One adherence window counted from the slots of the last `days` days.
        private static func window(_ slots: [Slot], days: Int, now: Date) -> [String: Any] {
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
            let inWindow = slots.filter { $0.scheduledFor >= start }
            let taken = inWindow.count { $0.takenAt != nil }
            let skipped = inWindow.count(where: \.skipped)
            let missed = inWindow.count - taken - skipped
            // Like the server: a skipped dose leaves the denominator, the rate
            // is taken over taken plus missed.
            let rate = taken + missed == 0 ? 0 : Int((Double(taken) / Double(taken + missed) * 100).rounded())
            return [
                "totalExpected": inWindow.count, "taken": taken, "skipped": skipped,
                "missed": missed, "rate": rate, "streak": streak(slots, now: now)
            ]
        }

        /// Whole days, counted back from today, on which every due dose was taken.
        private static func streak(_ slots: [Slot], now: Date) -> Int {
            let calendar = Calendar.current
            let byDay = Dictionary(grouping: slots) { calendar.startOfDay(for: $0.scheduledFor) }
            var count = 0
            for day in byDay.keys.sorted(by: >) {
                guard byDay[day]?.allSatisfy({ $0.takenAt != nil }) == true else { break }
                count += 1
            }
            return count
        }

        private static func windows(medicationID: String) -> [String: Any] {
            let now = Date.now
            let all = slots(medicationID: medicationID, now: now)
            let weekly = medicationID == trulicityID
            let short = window(all, days: weekly ? 30 : 7, now: now)
            let long = window(all, days: weekly ? 90 : 30, now: now)
            func display(_ window: [String: Any]) -> [String: Any] {
                let taken = window["taken"] as? Int ?? 0
                let missed = window["missed"] as? Int ?? 0
                return ["rate": window["rate"] ?? 0, "taken": taken, "expected": taken + missed]
            }
            return [
                "compliance7": window(all, days: 7, now: now),
                "compliance30": window(all, days: 30, now: now),
                "complianceDisplay": [
                    "shortDays": weekly ? 30 : 7, "longDays": weekly ? 90 : 30,
                    "short": display(short), "long": display(long)
                ],
                "applicable": true
            ]
        }

        /// `GET /api/medications/{id}/compliance` — `MedicationCompliancePayload`.
        private static func compliance(medicationID: String) -> [String: Any] {
            guard [lisinoprilID, naproxenID, trulicityID].contains(medicationID) else {
                return notTracked()
            }
            return windows(medicationID: medicationID).merging(["dailyCompliance": [String: Any]()]) { _, new in new }
        }

        /// The medication kept as a record: the server's `INTAKE_NOT_TRACKED`.
        private static func notTracked() -> [String: Any] {
            let zero: [String: Any] = ["totalExpected": 0, "taken": 0, "skipped": 0, "missed": 0, "rate": 0, "streak": 0]
            return [
                "compliance7": zero, "compliance30": zero, "dailyCompliance": [String: Any](),
                "applicable": false, "notApplicableReason": "INTAKE_NOT_TRACKED"
            ]
        }

        /// `GET /api/medications/compliance` — the batched card read, `{ data }`.
        private static func batchedCompliance() -> [String: Any] {
            var rows = [lisinoprilID, naproxenID, trulicityID].map { id in
                windows(medicationID: id).merging(["medicationId": id]) { _, new in new }
            }
            rows.append(notTracked().merging(["medicationId": AreaMedsFixtures.recordOnlyMedicationID]) { _, new in new })
            return ["data": rows]
        }

        // MARK: - Efficacy

        /// `GET /api/medications/{id}/efficacy` for Lisinopril: systolic pressure
        /// a little lower in the weeks after the start than before it.
        static var efficacyJSON: String {
            let label = AppLanguage.current.pick(
                de: "Systolischer Blutdruck", en: "Systolic blood pressure", nl: "Systolische bloeddruk",
                ko: "수축기 혈압"
            )
            let before = [141, 139, 140, 138, 137, 139]
            let after = [135, 133, 131, 132, 130, 129, 130, 128]
            func week(_ index: Int) -> String {
                let base = iso.date(from: "2026-01-19T08:00:00Z") ?? .distantPast
                return iso.string(from: base.addingTimeInterval(Double(index) * 7 * 86400))
            }
            let points = (before + after).enumerated().map { index, value in
                #"{"t":"\#(week(index))","value":\#(value),"status":null}"#
            }
            let adherence = (6 ..< 14).map { index in
                #"{"date":"\#(week(index))","rate":\#(index == 9 ? 0.86 : 1.0),"taken":\#(index == 9 ? 6 : 7),"missed":\#(index == 9 ? 1 : 0)}"#
            }
            return """
            {
              "medicationId": "\(lisinoprilID)", "medicationName": "Lisinopril", "eligible": true,
              "reason": null, "startsOn": "2026-03-02T00:00:00Z",
              "resolution": { "tier": "class", "cls": "ACE_INHIBITOR" },
              "windowDays": 90, "minWeeksPerSide": 2,
              "markers": { "start": "2026-03-02T00:00:00Z", "startSource": "startsOn",
                           "doseChanges": [], "pauses": [] },
              "targets": [ {
                "kind": "metric", "key": "BLOOD_PRESSURE", "label": "\(label)", "unit": "mmHg",
                "primary": true, "referenceBand": null,
                "series": [\(points.joined(separator: ","))],
                "beforeAfter": {
                  "present": true, "reason": null,
                  "before": { "mean": 139, "count": 12, "from": "\(week(0))", "to": "\(week(5))" },
                  "after": { "mean": 131, "count": 16, "from": "\(week(6))", "to": "\(week(13))" },
                  "delta": { "mean": -8, "pct": -5.8 }
                },
                "levelShift": null
              } ],
              "adherence": [\(adherence.joined(separator: ","))],
              "overrideOptions": { "metrics": [], "biomarkers": [] }
            }
            """
        }
    }
#endif
