#if DEBUG
    import Foundation

    /// **1.0.3 (App Review 1.4.1) — the citation-evidence fixture overlay.**
    ///
    /// Apple rejected 1.0 for showing medical information without citations. The
    /// Resolution Center reply has to photograph the controls that answer that,
    /// and four of them sit on surfaces that only exist when the account HOLDS
    /// something: a correlation card, a classified blood-pressure reading, a lab
    /// biomarker, a completed questionnaire. The shared hermetic table serves
    /// `[]` / `{}` for all four routes, so `MedicalSourcesReviewPathUITests`
    /// could reach the hub and the disclaimer and nothing else.
    ///
    /// This overlay answers exactly those routes, and ONLY under
    /// ``argument``. Same discipline as ``MarketingFixtures``: no other test
    /// passes the flag, so the world every other assertion in this repository
    /// depends on stays byte-identical. That matters more here than it looks —
    /// `/api/measurements` currently answers `[]` for everyone, and several
    /// walkthroughs assert against exactly that emptiness.
    ///
    /// **Deterministic.** Every value is fixed or derived from a fixed anchor
    /// date, so two runs produce the same pixels and a screenshot diff means a
    /// product change.
    ///
    /// **Localized like the real server.** Two of these payloads carry SERVER
    /// PROSE that the app renders verbatim — the correlation `interpretation`
    /// and the outcome channel's resolved label. The real route localizes them
    /// per request; a fixed English string would put an English sentence in the
    /// middle of the German evidence and look exactly like the translation bug
    /// the screenshots are meant to rule out. ``isGerman`` reads the forced
    /// display language, so the German run gets German prose — which is what
    /// the server does.
    enum CitationFixtures {
        /// Opt-in. `MedicalSourcesReviewPathUITests` is the only caller.
        static let argument = "-uitest-citations"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        /// The app's presented language.
        ///
        /// `Bundle.main.preferredLocalizations`, NOT `Locale.preferredLanguages`:
        /// the first run read the latter and served German prose to the ENGLISH
        /// capture, because the argument-domain `-AppleLanguages (en)` did not
        /// win there against the simulator's own language. The bundle's resolved
        /// localization is the same thing `Text()` renders from, so the fixture
        /// prose and the app chrome can no longer disagree.
        private static var isGerman: Bool {
            Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? false
        }

        /// `nil` for every route this overlay has nothing to say about — and for
        /// EVERY route when the flag is absent — so the shared fixture table
        /// answers unchanged for every other test in the suite.
        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive else { return nil }
            switch path {
            case "/api/insights/correlations":
                return ok(correlationsJSON)
            case "/api/insights/comprehensive":
                return ok(comprehensiveJSON)
            case "/api/user/ai-provider" where method == "GET":
                return ok(aiProviderJSON)
            // Exact match only: `/api/measurements/series` and the write paths
            // must keep falling through to the shared table.
            case "/api/measurements" where method == "GET":
                return ok(measurementsJSON)
            case "/api/measurements/series" where method == "GET":
                return ok(seriesJSON)
            case "/api/labs" where method == "GET":
                return ok(labsJSON)
            case "/api/biomarkers":
                return ok(biomarkersJSON)
            case "/api/mental-health/assessments":
                return ok(method == "POST" ? createAssessmentJSON : #"{"assessments":[]}"#)
            default:
                return nil
            }
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// Every payload this overlay can serve, named by its route.
        ///
        /// The point of the list is that it is ONE list. `HermeticCitationFixtureShapeTests`
        /// decodes each entry through the app's real DTO, so a fixture that stops
        /// matching the decoder it is written against fails in milliseconds
        /// instead of as a missing control three minutes into a UI walk — which
        /// is how the blood-pressure series gap was actually found. A payload
        /// added here without a decode case makes that suite fail its own
        /// coverage check.
        static var servedPayloads: [(route: String, json: String)] {
            [
                ("/api/insights/correlations", correlationsJSON),
                ("/api/insights/comprehensive", comprehensiveJSON),
                ("/api/user/ai-provider", aiProviderJSON),
                ("/api/measurements", measurementsJSON),
                ("/api/measurements/series", seriesJSON),
                ("/api/labs", labsJSON),
                ("/api/biomarkers", biomarkersJSON),
                ("/api/mental-health/assessments", createAssessmentJSON)
            ]
        }

        // MARK: - Correlations (`GET /api/insights/correlations`)

        /// Two FDR-surviving pairs shaped like `CorrelationDiscoveryResponse`.
        ///
        /// The prose is deliberately the server's own conservative register —
        /// "shows a faint hint, if anything", "never a cause". A correlation card
        /// is the surface Apple photographed, so the sentence on it has to be the
        /// sentence the product actually ships, not a test string.
        ///
        /// `behaviourLabel` is omitted for `SLEEP_DURATION`: it is one of the 17
        /// curated channels, and `InsightsCorrelationsDiscoveryBlock` deliberately
        /// lets the LOCAL German table win for those (decision E6 — the server's
        /// label for a curated channel is an English token). `BLOOD_PRESSURE_DIA`
        /// is NOT curated, so its label has to come from here, exactly as it
        /// would from the server.
        static var correlationsJSON: String {
            let diaLabel = isGerman ? "diastolischer Blutdruck" : "diastolic blood pressure"
            let rhrLabel = isGerman ? "Ruhepuls" : "resting heart rate"
            let firstDE = "Eine längere Schlafdauer geht in deinen Daten allenfalls mit einem leicht "
                + "höheren diastolischen Blutdruck am Folgetag einher — zu klein, um sich darauf zu "
                + "stützen, und nie eine Ursache."
            let firstEN = "Higher sleep duration shows a faint hint, if anything, of higher next-day "
                + "diastolic blood pressure in your data — too small to lean on, never a cause."
            let secondDE = "Mehr Schritte gehen in deinen Daten mit einem etwas niedrigeren Ruhepuls "
                + "am Folgetag einher. Das beschreibt einen Zusammenhang, keine Wirkung."
            let secondEN = "More steps go with a somewhat lower resting heart rate the next day in "
                + "your data. That describes an association, not an effect."
            let first = isGerman ? firstDE : firstEN
            let second = isGerman ? secondDE : secondEN
            return """
            {
              "discovered": [
                {
                  "behaviour": "SLEEP_DURATION",
                  "outcome": "BLOOD_PRESSURE_DIA",
                  "outcomeLabel": "\(diaLabel)",
                  "n": 140,
                  "r": 0.27,
                  "pValue": 0.0012,
                  "qValue": 0.08,
                  "interpretation": "\(first)",
                  "lagDays": 1,
                  "canonicalKey": "p1:c17e9f2a4b6d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
                  "dismissed": false
                },
                {
                  "behaviour": "STEPS",
                  "outcome": "RESTING_HEART_RATE",
                  "outcomeLabel": "\(rhrLabel)",
                  "n": 126,
                  "r": -0.31,
                  "pValue": 0.0004,
                  "qValue": 0.05,
                  "interpretation": "\(second)",
                  "lagDays": 1,
                  "canonicalKey": "p1:d28f0a3b5c7e9f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192",
                  "dismissed": false
                }
              ],
              "pairsTested": 31,
              "fdrQ": 0.1,
              "minPairs": 20
            }
            """
        }

        // MARK: - Comprehensive digest (`GET /api/insights/comprehensive`)

        /// The flat `AIInsightResponse` envelope (digest fields ride the ROOT —
        /// see `AIInsightResponse.digest`, "server emits a flat envelope, not
        /// nested"). `bpClassification: high_normal` is what makes
        /// `InsightsMetricStatusDescriptor.buildBloodPressure` attach the ESH
        /// 2023 guideline caption, which IS `sources.bpClassification`.
        static let comprehensiveJSON = """
        {
          "summary": null,
          "recommendations": [],
          "citations": [],
          "warnings": [],
          "dailyBriefing": null,
          "hasProvider": false,
          "dataSpanDays": 30,
          "totalMeasurements": 60,
          "bpClassification": "high_normal",
          "bpPctInTarget": 46,
          "bpTargets": { "sysLow": 120, "sysHigh": 129, "diaLow": 70, "diaHigh": 79 },
          "summaries": {
            "BLOOD_PRESSURE_SYS": { "count": 30, "latest": 128, "min": 121, "max": 135, "mean": 128, "avg7": 128, "avg30": 128 },
            "BLOOD_PRESSURE_DIA": { "count": 30, "latest": 82, "min": 76, "max": 88, "mean": 82, "avg7": 82, "avg30": 82 }
          }
        }
        """

        // MARK: - AI provider (`GET /api/user/ai-provider`)

        /// A configured server-side provider.
        ///
        /// This is not cosmetic and it is not about the coach. `InsightsStore.load()`
        /// is gated on `AppContainer.makeAIConsentGate()`, which refuses outright
        /// when `AIProviderStore.config` is `nil` — so with the shared fixture
        /// table's empty answer the comprehensive digest is NEVER fetched, the
        /// blood-pressure status card never mounts, and the ESH 2023 caption that
        /// IS `sources.bpClassification` cannot exist. Three gate runs reported
        /// that caption missing before the app's own log said why:
        /// `InsightsStore.load gated by AI consent — skipped`.
        ///
        /// With a provider configured the consent sheet presents, the walk
        /// ACCEPTS it the way a reviewer would, and the digest loads.
        static let aiProviderJSON = """
        {
          "provider": "anthropic",
          "model": "claude-3-5-haiku",
          "baseUrl": null,
          "hasAnthropicKey": true,
          "anthropicKeyPreview": "sk-ant-…hermetic",
          "hasOpenaiKey": false,
          "openaiKeyPreview": null,
          "hasLocalKey": false,
          "aiAvailable": true,
          "managedBy": null
        }
        """

        // MARK: - Measurements (`GET /api/measurements`)

        /// Thirty days of paired blood-pressure readings around 128/82, so the
        /// metric page draws a real line under the status card instead of an
        /// empty chart. Deterministic: the offsets cycle through a fixed table
        /// anchored on a fixed date, so every run produces the same series.
        static var measurementsJSON: String {
            let anchor = Date(timeIntervalSince1970: 1_781_596_800) // 2026-06-16T08:00:00Z
            let sysOffsets = [0, 3, -2, 5, 1, -4, 2, 6, -1, 0]
            let diaOffsets = [0, 2, -1, 3, 1, -3, 0, 4, -2, 1]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let rows = (0 ..< 30).flatMap { day -> [String] in
                let at = formatter.string(from: anchor.addingTimeInterval(TimeInterval(-day * 86400)))
                let sys = 128 + sysOffsets[day % sysOffsets.count]
                let dia = 82 + diaOffsets[day % diaOffsets.count]
                return [
                    row(id: "bp-sys-\(day)", type: "BLOOD_PRESSURE_SYS", value: sys, unit: "mmHg", at: at),
                    row(id: "bp-dia-\(day)", type: "BLOOD_PRESSURE_DIA", value: dia, unit: "mmHg", at: at)
                ]
            }
            return #"{"measurements":["# + rows.joined(separator: ",") + "]}"
        }

        /// `GET /api/measurements/series?kind=bloodPressure` — the dense per-day
        /// frame the metric page's CHART reads. Without it the page paints
        /// "Couldn't read the data", the status card never mounts, and with it
        /// the ESH caption that IS `sources.bpClassification`: the page-level
        /// error is what hid the citation on the first fixture run.
        ///
        /// `secondary` carries the diastolic half, as the server does for BP.
        static var seriesJSON: String {
            let anchor = Date(timeIntervalSince1970: 1_781_596_800) // 2026-06-16T08:00:00Z
            let sysOffsets = [0, 3, -2, 5, 1, -4, 2, 6, -1, 0]
            let diaOffsets = [0, 2, -1, 3, 1, -3, 0, 4, -2, 1]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let points = (0 ..< 30).reversed().map { day -> String in
                let at = formatter.string(from: anchor.addingTimeInterval(TimeInterval(-day * 86400)))
                let sys = 128 + sysOffsets[day % sysOffsets.count]
                let dia = 82 + diaOffsets[day % diaOffsets.count]
                return #"{"id":"bp-p-\#(day)","at":"\#(at)","value":\#(sys),"secondary":\#(dia)}"#
            }
            return """
            {
              "kind": "bloodPressure",
              "unit": "mmHg",
              "points": [\(points.joined(separator: ","))],
              "stats": { "mean": 128, "min": 121, "max": 135, "stdDev": 3.4, "count": 30 }
            }
            """
        }

        private static func row(id: String, type: String, value: Int, unit: String, at: String) -> String {
            """
            {"id":"\(id)","type":"\(type)","value":\(value),"unit":"\(unit)",\
            "measuredAt":"\(at)","source":"MANUAL","notes":null}
            """
        }

        // MARK: - Labs (`GET /api/labs`, `GET /api/biomarkers`)

        /// One catalogue-linked hs-CRP marker with one reading, in range.
        ///
        /// The name matters: `BiomarkerExplainer` resolves "hs-CRP" to the
        /// `hs-crp` slug, which is what gives the detail page an explainer
        /// paragraph — and the citation control lives INSIDE that paragraph's
        /// slot, so a marker with no explainer would render no `sources.lab.*`
        /// at all.
        static let biomarkersJSON = """
        {
          "biomarkers": [
            {
              "id": "bm-hs-crp",
              "name": "hs-CRP",
              "unit": "mg/L",
              "lowerBound": 0,
              "upperBound": 3,
              "panel": "inflammation",
              "hasContext": false,
              "context": null,
              "hidden": false,
              "createdAt": "2026-05-01T08:00:00Z",
              "updatedAt": "2026-05-01T08:00:00Z"
            }
          ]
        }
        """

        static let labsJSON = """
        {
          "results": [
            {
              "id": "lab-hs-crp-1",
              "biomarkerId": "bm-hs-crp",
              "panel": "inflammation",
              "analyte": "hs-CRP",
              "value": 2.1,
              "valueText": null,
              "unit": "mg/L",
              "referenceLow": 0,
              "referenceHigh": 3,
              "takenAt": "2026-06-02T08:00:00Z",
              "source": "MANUAL",
              "hasNote": false,
              "rangeStatus": "in-range",
              "createdAt": "2026-06-02T08:00:00Z",
              "updatedAt": "2026-06-02T08:00:00Z"
            }
          ]
        }
        """

        // MARK: - Mental health (`POST /api/mental-health/assessments`)

        /// The server-authoritative PHQ-9 result the walk's submitted answers
        /// come back as: total 7, band `mild`, item 9 NOT flagged (so no crisis
        /// card rides along — the evidence shot is about the screening
        /// disclaimer and its citation, and a crisis card in a screenshot bound
        /// for Apple would be misleading about what the walk did).
        ///
        /// `actionThreshold: 10` is the PHQ-9 value the route serves, so 7 sits
        /// below it and the gentle "consider a professional" nudge stays down.
        static let createAssessmentJSON = """
        {
          "assessment": {
            "id": "mh-hermetic-1",
            "instrument": "PHQ9",
            "locale": "en",
            "version": "1",
            "totalScore": 7,
            "severityBand": "mild",
            "item9Flagged": false,
            "crisisShownAt": null,
            "takenAt": "2026-06-16T08:00:00Z",
            "createdAt": "2026-06-16T08:00:00Z"
          },
          "actionThreshold": 10,
          "crisis": null
        }
        """
    }
#endif
