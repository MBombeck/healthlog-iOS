#if DEBUG
    import Foundation

    /// **The LAB-DOC surfaces, for the picture sweep.**
    ///
    /// Under `-uitest-lab-doc` the fixture server holds two lab markers, one
    /// of them without a unit (`"1"`, shown as a bare number and "No unit"),
    /// and a vault with one scanned report whose read stopped before the end
    /// (`extractionIncomplete`) with two staged values. The sweep pairs it
    /// with `-hl.healthkit.serverVersion 1.47.0`, so the editors offer the
    /// "No unit" switch. Everything is invented; no value of any real person
    /// appears here. `nil` for every other route.
    enum LabDocFixtures {
        static let argument = "-uitest-lab-doc"
        static let documentID = "labdoc-incomplete"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive, method == "GET" else { return nil }
            switch path {
            case "/api/labs":
                return (200, Data(labsJSON.utf8))
            case "/api/labs/overview":
                return envelope(overviewJSON)
            case "/api/biomarkers":
                return (200, Data(biomarkersJSON.utf8))
            case "/api/documents/inbound":
                return envelope(#"{"documents":[\#(documentJSON)],"nextCursor":null}"#)
            case "/api/documents/inbound/\(documentID)":
                return envelope(String(documentJSON.dropLast()) + #","facts":[\#(facts)],"extractionIncomplete":true}"#)
            default:
                return reading(path)
            }
        }

        /// The single read of one lab value (`GET /api/labs/<id>`).
        private static func reading(_ path: String) -> (status: Int, body: Data)? {
            let readings = [
                "labdoc-inr-2": lab("labdoc-inr-2", "labdoc-bm-inr", "coagulation", "INR", 1.3, "1", 0.85, 1.15, "2026-10-21", "above"),
                "labdoc-inr-1": lab("labdoc-inr-1", "labdoc-bm-inr", "coagulation", "INR", 1.1, "1", 0.85, 1.15, "2026-09-02", "in-range"),
                "labdoc-crp-1": lab("labdoc-crp-1", "labdoc-bm-crp", "inflammation", "hs-CRP", 2.1, "mg/L", 0, 3, "2026-10-21", "in-range")
            ]
            guard path.hasPrefix("/api/labs/"), let json = readings[String(path.dropFirst("/api/labs/".count))] else { return nil }
            return envelope(json)
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        static let biomarkersJSON = """
        {"biomarkers":[
          {"id":"labdoc-bm-inr","name":"INR","unit":"1","lowerBound":0.85,"upperBound":1.15,"panel":"coagulation",
           "hasContext":false,"context":null,"hidden":false,
           "createdAt":"2026-05-01T08:00:00Z","updatedAt":"2026-05-01T08:00:00Z"},
          {"id":"labdoc-bm-crp","name":"hs-CRP","unit":"mg/L","lowerBound":0,"upperBound":3,"panel":"inflammation",
           "hasContext":false,"context":null,"hidden":false,
           "createdAt":"2026-05-01T08:00:00Z","updatedAt":"2026-05-01T08:00:00Z"}
        ]}
        """

        static let labsJSON = """
        {"results":[
          \(lab("labdoc-inr-2", "labdoc-bm-inr", "coagulation", "INR", 1.3, "1", 0.85, 1.15, "2026-10-21", "above")),
          \(lab("labdoc-inr-1", "labdoc-bm-inr", "coagulation", "INR", 1.1, "1", 0.85, 1.15, "2026-09-02", "in-range")),
          \(lab("labdoc-crp-1", "labdoc-bm-crp", "inflammation", "hs-CRP", 2.1, "mg/L", 0, 3, "2026-10-21", "in-range"))
        ]}
        """

        /// The overview the list reads: one entry per marker with its trend,
        /// and the two categories the server resolved for them. The server
        /// labels a catalog category in the viewer's language, so the fixture
        /// does too; an English label in a German list was the fixture's.
        static var overviewJSON: String {
            let coagulation = String(localized: "labs.catalog.panel.coagulation")
            let inflammation = String(localized: "labs.catalog.panel.inflammation")
            return """
            {"markers":[
              {"key":"bm:labdoc-bm-inr","count":2,"trend":[1.1,1.3],
               "latest":\(lab("labdoc-inr-2", "labdoc-bm-inr", "coagulation", "INR", 1.3, "1", 0.85, 1.15, "2026-10-21", "above"))},
              {"key":"bm:labdoc-bm-crp","count":1,"trend":[2.1],
               "latest":\(lab("labdoc-crp-1", "labdoc-bm-crp", "inflammation", "hs-CRP", 2.1, "mg/L", 0, 3, "2026-10-21", "in-range"))}
            ],"categories":[
              {"key":"coagulation","label":"\(coagulation)","markerKeys":["bm:labdoc-bm-inr"],
               "counts":{"inRange":0,"below":0,"above":1,"unknown":0},"status":"above"},
              {"key":"inflammation","label":"\(inflammation)","markerKeys":["bm:labdoc-bm-crp"],
               "counts":{"inRange":1,"below":0,"above":0,"unknown":0},"status":"in-range"}
            ],"grouped":true}
            """
        }

        private static func lab(
            _ id: String, _ marker: String, _ panel: String, _ analyte: String, _ value: Double,
            _ unit: String, _ low: Double, _ high: Double, _ day: String, _ status: String
        ) -> String {
            #"{"id":"\#(id)","biomarkerId":"\#(marker)","panel":"\#(panel)","analyte":"\#(analyte)","#
                + #""value":\#(value),"valueText":null,"unit":"\#(unit)","referenceLow":\#(low),"#
                + #""referenceHigh":\#(high),"takenAt":"\#(day)T08:00:00Z","source":"DOCUMENT","hasNote":false,"#
                + #""rangeStatus":"\#(status)","createdAt":"\#(day)T09:00:00Z","updatedAt":"\#(day)T09:00:00Z"}"#
        }

        private static var documentJSON: String {
            #"{"id":"\#(documentID)","kind":"LAB_RESULT","title":"Laborbefund Oktober","filename":"befund.pdf","#
                + #""mimeType":"application/pdf","byteSize":3480000,"status":"EXTRACTED","providerType":null,"#
                + #""reportDate":"2026-10-21","documentDate":"2026-10-21","errorReason":null,"factCount":2,"#
                + #""pendingCount":2,"conditionLinks":[],"servingClass":"inline","#
                + #""createdAt":"2026-10-21T09:00:00.000Z","updatedAt":"2026-10-21T09:00:00.000Z"}"#
        }

        private static var facts: String {
            [("labdoc-fact-inr", "INR", "1.3", "1"), ("labdoc-fact-crp", "hs-CRP", "2.1", "mg/L")].map { id, label, value, unit in
                #"{"id":"\#(id)","factType":"OBSERVATION","status":"PENDING","confidence":0.92,"needsReview":true,"#
                    + #""data":{"label":"\#(label)","value":\#(value),"unit":"\#(unit)"},"#
                    + #""provenance":{"sourceText":"\#(label) \#(value)","page":1,"confidence":0.92},"#
                    + #""committedRecordId":null,"committedRecordType":null}"#
            }.joined(separator: ",")
        }
    }
#endif
