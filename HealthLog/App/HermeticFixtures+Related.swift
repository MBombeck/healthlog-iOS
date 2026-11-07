#if DEBUG
    import Foundation

    /// **RELATED (1.5.0, #141) — the "Related" section on four pages.**
    ///
    /// Under `-uitest-related` (with `-uitest-area-meds`) the single reads of
    /// Metformin, the Influenza episode, one HbA1c value and the scanned
    /// report behind it carry the server's `related` list, so the sweep can
    /// open the medication and walk its related rows into the other three
    /// pages. Every list also holds a visit and a vaccination (no page in the
    /// app) and one kind the app does not know, which must not show. Everything
    /// is invented; no value of any real person appears here. `nil` for every
    /// other route.
    enum RelatedFixtures {
        static let argument = "-uitest-related"
        static let labID = "related-lab-hba1c"
        static let documentID = "related-doc-report"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive, method == "GET" else { return nil }
            switch path {
            case "/api/medications/\(AreaMedsFixtures.recordOnlyMedicationID)":
                return envelope(medicationJSON)
            case "/api/labs/\(labID)":
                return envelope(labJSON)
            case "/api/documents/inbound/\(documentID)":
                return envelope(documentJSON)
            case "/api/illness/episodes/\(AreaIllnessFixtures.influenzaID)":
                return episode()
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func link(_ kind: String, _ id: String, _ label: String, _ date: String?) -> String {
            let day = date.map { "\"\($0)\"" } ?? "null"
            return #"{"kind":"\#(kind)","id":"\#(id)","label":"\#(label)","date":\#(day),"href":"/x/\#(id)","via":"direct"}"#
        }

        private static var visit: String {
            link("encounter", "related-visit", "Hausarztpraxis Dr. Muster", "2026-03-02")
        }

        private static var vaccination: String {
            link("vaccination", "related-vacc", "Influenza 2025/26", "2025-10-14")
        }

        private static var unknownKind: String {
            link("careNote", "related-unknown", "MUST NOT SHOW", nil)
        }

        private static var lab: String {
            link("labResult", labID, "HbA1c", "2026-03-03T08:00:00.000Z")
        }

        private static var document: String {
            link("document", documentID, "Laborbefund März", "2026-03-03")
        }

        private static var medication: String {
            link("medication", AreaMedsFixtures.recordOnlyMedicationID, "Metformin", nil)
        }

        private static var episodeLink: String {
            link("conditionEpisode", AreaIllnessFixtures.influenzaID, "Influenza", nil)
        }

        private static var medicationJSON: String {
            """
            { "id": "\(AreaMedsFixtures.recordOnlyMedicationID)", "name": "Metformin", "dose": "500 mg",
              "active": true, "notificationsEnabled": false, "deliveryForm": "ORAL",
              "trackIntake": false, "createdAt": "2026-02-01T08:00:00.000Z",
              "schedules": [
                { "windowStart": "08:00", "timesOfDay": ["08:00", "20:00"], "scheduleType": "SCHEDULED" }
              ],
              "related": [\(lab), \(document), \(episodeLink), \(visit), \(unknownKind)] }
            """
        }

        private static var labJSON: String {
            """
            {"id":"\(labID)","biomarkerId":null,"panel":"Diabetes","analyte":"HbA1c","value":5.9,"valueText":null,
             "unit":"%","referenceLow":4.0,"referenceHigh":5.6,"takenAt":"2026-03-03T08:00:00.000Z",
             "source":"DOCUMENT","rangeStatus":"above","createdAt":"2026-03-03T09:00:00.000Z",
             "updatedAt":"2026-03-03T09:00:00.000Z","note":null,
             "related":[\(document), \(medication), \(visit)]}
            """
        }

        /// POLISH-A A2 — the report is linked to the Influenza episode, and the
        /// server lists that stored link in `related` as well (v1.47.0,
        /// `document:conditionEpisode` is a stored cell), exactly as it does live.
        private static var documentJSON: String {
            """
            {"id":"\(documentID)","kind":"LAB_RESULT","title":"Laborbefund März","filename":"befund.pdf",
             "mimeType":"application/pdf","byteSize":48213,"status":"EXTRACTED","providerType":"anthropic",
             "reportDate":"2026-03-03","documentDate":"2026-03-03","errorReason":null,"factCount":0,
             "pendingCount":0,"servingClass":"inline",
             "conditionLinks":[{"episodeId":"\(AreaIllnessFixtures.influenzaID)","name":"Influenza"}],
             "createdAt":"2026-03-03T09:00:00.000Z","updatedAt":"2026-03-03T09:00:00.000Z","facts":[],
             "related":[\(lab), \(episodeLink), \(visit), \(unknownKind)]}
            """
        }

        /// The area episode, with `related` added to its single read.
        private static func episode() -> (Int, Data)? {
            let path = "/api/illness/episodes/\(AreaIllnessFixtures.influenzaID)"
            guard let base = AreaIllnessFixtures.response(forPath: path, method: "GET", query: []),
                  var root = (try? JSONSerialization.jsonObject(with: base.body)) as? [String: Any],
                  var data = root["data"] as? [String: Any],
                  let links = try? JSONSerialization.jsonObject(with: Data("[\(document), \(vaccination), \(medication)]".utf8)) else { return nil }
            data["related"] = links
            root["data"] = data
            guard let body = try? JSONSerialization.data(withJSONObject: root) else { return nil }
            return (200, body)
        }
    }
#endif
