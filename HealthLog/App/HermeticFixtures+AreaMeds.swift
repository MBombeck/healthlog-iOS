#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// **iOS 1.4 B2-b.** `-uitest-area-meds` — the medications-and-mood
        /// overlay of the QA sweep. Only `QASweepScreenshotsTest` passes it, and
        /// only together with `-uitest-marketing`, whose table consults it first.
        static let areaMedsOverlayArgument = "-uitest-area-meds"

        static var isAreaMedsOverlayActive: Bool {
            ProcessInfo.processInfo.arguments.contains(areaMedsOverlayArgument)
        }
    }

    /// **iOS 1.4 B2-b — data for the screens the marketing world leaves empty.**
    ///
    /// The marketing overlay serves three medications and nothing about mood or
    /// mental health, so the mood cards and the check-in history never render
    /// and no medication is kept as a record. This overlay adds exactly that: a
    /// fourth medication with intake tracking off, thirty days of mood entries
    /// with a few tags, the server's mood relations (influence, better days,
    /// factor crosstab, stability, patterns) and two PHQ-9 results. Everything
    /// is invented and deliberately unremarkable; no value of any real person
    /// appears here. The cycle and illness routes come from
    /// ``AreaCycleFixtures`` and ``AreaIllnessFixtures``. `nil` for every other
    /// route, so the marketing and shared tables answer unchanged.
    enum AreaMedsFixtures {
        static let recordOnlyMedicationID = "area-med-metformin"

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem] = []
        ) -> (status: Int, body: Data)? {
            // RELATED (1.5.0) — single reads with `related`, only under `-uitest-related`;
            // MED-PLUS (1.5.0) — the course routes, only under `-uitest-med-plus`.
            if let related = RelatedFixtures.response(forPath: path, method: method)
                ?? MedPlusFixtures.response(forPath: path, method: method) { return related }
            // SUPP (1.5.0) — a supplement and the nutrient split, only under `-uitest-supp`;
            // SUPP-EDIT — the catalogue, the composition PUT and a label read, only under `-uitest-supp-edit`.
            if let supp = SuppEditFixtures.response(forPath: path, method: method)
                ?? SuppFixtures.response(forPath: path, method: method, query: query) { return supp }
            // SYMPTOM (1.5.0) — symptoms filed against the episodes, only under `-uitest-symptom`.
            if let cycleOrSymptom = SymptomFixtures.response(forPath: path, method: method, query: query)
                ?? AreaCycleFixtures.response(forPath: path, method: method) { return cycleOrSymptom }
            if let illness = AreaIllnessFixtures.response(forPath: path, method: method, query: query) { return illness }
            // 1.4 B4-c — the per-medication routes and the notification settings.
            if let detail = AreaMedsDetailFixtures.response(forPath: path, method: method, query: query) { return detail }
            // POLISH-C (F-REL-1) — and the single read behind "Related": the list's row.
            if let other = AreaNotificationsFixtures.response(forPath: path, method: method)
                ?? (method == "GET" ? singleMedication(forPath: path) : nil) { return other }
            return switch (method, path) {
            case ("GET", "/api/medications"):
                medications()
            case ("GET", "/api/mood-entries"):
                ok(moodEntriesJSON)
            case ("GET", "/api/mood/insights"):
                ok(moodInsightsJSON)
            case ("GET", "/api/mental-health/assessments"):
                // The server filters by instrument; both results are PHQ-9.
                ok(query.contains { $0.name == "instrument" && $0.value != "PHQ9" }
                    ? #"{"assessments":[]}"# : assessmentsJSON)
            case ("POST", "/api/mental-health/assessments"):
                ok(CitationFixtures.createAssessmentJSON)
            default:
                nil
            }
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The marketing world's three medications plus one kept as a record.
        /// Trulicity carries its treatment class here, so its detail shows the
        /// GLP-1 sections (the marketing world leaves the class out).
        ///
        /// 1.4 B4-c — "Letzte Einnahme" and today's count come from the same
        /// invented history the detail reads (`AreaMedsDetailFixtures`). The
        /// marketing rows stamp this morning's 08:05 whatever the clock says,
        /// so a capture before eight showed a last intake after the next one.
        private static func medications() -> (Int, Data)? {
            let marketing = Data(MarketingFixtures.medicationsJSON.utf8)
            let extra = Data(recordOnlyJSON.utf8)
            guard let list = (try? JSONSerialization.jsonObject(with: marketing)) as? [[String: Any]],
                  let recordOnly = (try? JSONSerialization.jsonObject(with: extra)) as? [String: Any] else { return nil }
            let iso = ISO8601DateFormatter()
            let classed = list.map { row -> [String: Any] in
                var row = row
                if let id = row["id"] as? String {
                    row["lastTakenAt"] = AreaMedsDetailFixtures.lastTakenAt(medicationID: id).map { iso.string(from: $0) }
                        ?? NSNull()
                    row["todayEventCount"] = AreaMedsDetailFixtures.todayEventCount(medicationID: id)
                }
                guard row["name"] as? String == "Trulicity" else { return MedPlusFixtures.decorate(row) }
                return row.merging(["treatmentClass": "GLP1"]) { _, new in new }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: classed + [recordOnly] + SuppFixtures.listRows) else { return nil }
            return (200, data)
        }

        /// `GET /api/medications/{id}` for a row of ``medications()``.
        private static func singleMedication(forPath path: String) -> (Int, Data)? {
            let prefix = "/api/medications/"
            let id = String(path.dropFirst(prefix.count))
            guard path.hasPrefix(prefix), !id.isEmpty, !id.contains("/"),
                  let list = medications().flatMap({ try? JSONSerialization.jsonObject(with: $0.1) as? [[String: Any]] }),
                  let row = list.first(where: { $0["id"] as? String == id }),
                  let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return (200, data)
        }

        private static let recordOnlyJSON = """
        { "id": "\(recordOnlyMedicationID)", "name": "Metformin", "dose": "500 mg",
          "active": true, "notificationsEnabled": false, "deliveryForm": "ORAL",
          "trackIntake": false, "createdAt": "2026-02-01T08:00:00.000Z",
          "schedules": [
            { "windowStart": "08:00", "timesOfDay": ["08:00", "20:00"], "scheduleType": "SCHEDULED" }
          ] }
        """

        // MARK: - Mood

        /// Thirty days, one entry a day at 20:00 local, a calm wave between
        /// "okay" and "great" with a workout tag on every third day.
        static var moodEntriesJSON: String {
            let iso = ISO8601DateFormatter()
            let levels = ["GUT", "OKAY", "SUPER_GUT", "GUT", "GUT", "OKAY", "SCHLECHT"]
            let calendar = Calendar.current
            let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
            let rows = (0 ..< 30).map { offset -> String in
                let day = calendar.date(byAdding: .day, value: -offset, to: evening) ?? evening
                let tags = offset % 3 == 0 ? #"["worked_out"]"# : "[]"
                return """
                {"id":"area-mood-\(offset)","mood":"\(levels[offset % levels.count])",\
                "tags":[],"tagKeys":\(tags),"moodLoggedAt":"\(iso.string(from: day))"}
                """
            }
            return #"{"entries":[\#(rows.joined(separator: ","))],"meta":{"total":30}}"#
        }

        static let moodInsightsJSON = """
        {
          "stability": {"score": 72, "stdDev": 0.7, "band": "steady", "days": 28},
          "stabilityWindowDays": 30,
          "tagInfluence": {
            "flat": [],
            "structured": [
              {"tag": "worked_out", "labelKey": "mood.tag.workedOut", "categoryKey": "health",
               "icon": "Dumbbell", "withDays": 10, "withoutDays": 20, "withAvg": 4.4,
               "withoutAvg": 3.5, "delta": 0.9, "pValue": 0.01, "confidence": "high"},
              {"tag": "alcohol", "labelKey": "mood.tag.alcohol", "categoryKey": "health",
               "icon": "Wine", "withDays": 6, "withoutDays": 24, "withAvg": 3.2,
               "withoutAvg": 3.8, "delta": -0.6, "pValue": 0.04, "confidence": "low"}
            ]
          },
          "betterDays": [
            {"source": "tag", "key": "worked_out", "labelKey": "mood.tag.workedOut",
             "categoryKey": "health", "icon": "Dumbbell", "direction": "up", "n": 10,
             "confidence": "high", "delta": 0.9, "r": null},
            {"source": "metric", "key": "sleep", "labelKey": null, "categoryKey": null,
             "icon": null, "direction": "up", "n": 28, "confidence": "medium",
             "delta": null, "r": 0.31}
          ],
          "factorCrosstab": [
            {"factor": "factor_work", "labelKey": "mood.tag.factorWork", "categoryKey": "factors",
             "icon": "Briefcase", "inverse": false, "metricKey": "sleepDuration", "display": "hours",
             "mode": "sameDay", "lowDays": 9, "highDays": 12, "lowAvg": 6.4, "highAvg": 7.3,
             "delta": -0.9, "pValue": 0.02, "qValue": 0.04, "confidence": "medium"}
          ],
          "patterns": [
            { "id": "weekend", "kind": "weekend", "strength": "moderate", "direction": "higher",
              "values": { "subject": 7.2, "comparison": 6.4, "delta": 0.8 },
              "sampleSize": { "subject": 8, "comparison": 22 } },
            { "id": "best_weekday", "kind": "best_weekday", "strength": "weak", "direction": "higher",
              "values": { "subject": 7.6, "comparison": 6.5, "delta": 1.1, "weekday": 5 },
              "sampleSize": { "subject": 4, "comparison": 26 } }
          ]
        }
        """

        // MARK: - Mental health

        /// Two PHQ-9 results a month apart, both below the action threshold.
        static let assessmentsJSON = """
        {
          "assessments": [
            {"id": "area-mh-2", "instrument": "PHQ9", "locale": "de", "version": "1",
             "totalScore": 4, "severityBand": "minimal", "item9Flagged": false,
             "crisisShownAt": null, "takenAt": "2026-10-01T08:00:00Z", "createdAt": "2026-10-01T08:00:00Z"},
            {"id": "area-mh-1", "instrument": "PHQ9", "locale": "de", "version": "1",
             "totalScore": 7, "severityBand": "mild", "item9Flagged": false,
             "crisisShownAt": null, "takenAt": "2026-09-01T08:00:00Z", "createdAt": "2026-09-01T08:00:00Z"}
          ]
        }
        """
    }
#endif
