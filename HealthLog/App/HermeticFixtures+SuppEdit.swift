#if DEBUG
    import Foundation

    /// **SUPP-EDIT (1.5.0, #131 P3) — editing the composition, also from a
    /// label photo.**
    ///
    /// Under `-uitest-supp-edit` (with `-uitest-area-meds -uitest-supp`) the
    /// server serves the nutrient catalogue, takes the composition PUT and
    /// reads a label: the extract route answers 202 and the run ends with a
    /// proposal (vitamin D 1000 IU, magnesium 187.5 mg read unsure, one printed
    /// line without a nutrient, "pro 2 Kapseln"). The hermetic account has no
    /// `ai` block, so this world also offers the photo (``offersLabelPhoto``).
    /// With `-uitest-supp-edit-label` the form reads a tiny generated JPEG once
    /// it opens, because the system photo picker runs outside the app.
    /// Everything is invented; no value of any real person appears here.
    enum SuppEditFixtures {
        static let argument = "-uitest-supp-edit"
        static let labelArgument = "-uitest-supp-edit-label"
        static let runID = "supp-label-run"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static var offersLabelPhoto: Bool {
            isActive
        }

        static var readsLabelOnOpen: Bool {
            isActive && ProcessInfo.processInfo.arguments.contains(labelArgument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive else { return nil }
            switch (method, path) {
            case ("GET", "/api/nutrients/catalog"):
                return envelope(catalogJSON)
            case ("POST", "/api/medications/\(SuppFixtures.medicationID)/ingredients/extract"):
                return (202, Data(#"{"data":{"runId":"\#(runID)","status":"QUEUED","pollAfterMs":300},"error":null}"#.utf8))
            case ("GET", "/api/ai-runs/\(runID)"):
                return envelope(runJSON)
            case ("PUT", "/api/medications/\(SuppFixtures.medicationID)/ingredients"):
                return envelope(#"{"ingredients":[],"recompute":{"queued":true}}"#)
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func entry(_ code: String, _ unit: String, _ label: String, _ units: [(String, Double)]) -> String {
            let inputs = units.map { #"{"unit":"\#($0.0)","factorToCanonical":\#($0.1)}"# }.joined(separator: ",")
            return #"{"code":"\#(code)","unit":"\#(unit)","labelKey":"nutrients.names.\#(code)","label":"\#(label)","#
                + #""syncable":true,"inputUnits":[\#(inputs)],"upperLimit":null}"#
        }

        private static var catalogJSON: String {
            let entries = [
                entry("vitamin_d", "ug", "Vitamin D", [("ug", 1), ("mg", 1000), ("IU", 0.025)]),
                entry("magnesium", "mg", "Magnesium", [("mg", 1), ("ug", 0.001), ("g", 1000)]),
                entry("zinc", "mg", "Zink", [("mg", 1), ("ug", 0.001), ("g", 1000)]),
                entry("dha", "mg", "DHA (Omega-3)", [("mg", 1), ("ug", 0.001), ("g", 1000)]),
                entry("water", "ml", "Wasser", [("ml", 1), ("l", 1000)])
            ]
            return #"{"entries":[\#(entries.joined(separator: ","))]}"#
        }

        private static let runJSON = #"""
        {"id":"supp-label-run","kind":"SUPPLEMENT_LABEL_EXTRACT","documentId":null,"status":"SUCCEEDED",
         "result":{"ingredients":[
           {"nutrient":"vitamin_d","amount":1000,"unit":"IU","confidence":"high","printedText":"Vitamin D3 2000 IE"},
           {"nutrient":"magnesium","amount":187.5,"unit":"mg","confidence":"low","printedText":"Magnesium 375 mg"}],
          "unmatched":[{"printedText":"Coenzym Q10 20 mg"}],"servingNote":"pro 2 Kapseln"},
         "error":null,"createdAt":"2026-11-05T09:00:00.000Z","startedAt":null,"finishedAt":null,
         "queuedForMs":null,"retryAfterMs":300}
        """#
    }
#endif
