import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the comprehensive Insights metric-digest payload decoding against
/// the production `GET /api/insights/comprehensive` route shape
/// (server source: `src/app/api/insights/comprehensive/route.ts:377-400`).
///
/// **Background:** v0.4.0 Stream Golf — the W2b-A4 model only decoded the
/// AI-shaped fields and silently discarded the digest. This suite locks the
/// full envelope including BMI/BP classification, four correlation matrices,
/// alerts and data-span.
@Suite("ComprehensiveDigest decoding")
struct ComprehensiveDigestDecodingTests {
    private let decoder = JSONDecoder.hlDefault

    @Test("Full envelope decodes every digest field (server route.ts ground-truth)")
    func fullEnvelope() throws {
        // This fixture mirrors `route.ts:377-400` field-for-field. Every
        // value is realistic so the math (BMI/BP classification, BP-in-target,
        // correlation strength) parses without going through tolerant fallbacks.
        let json = Data(#"""
        {
            "summaries": {
                "WEIGHT": {
                    "count": 87,
                    "latest": 78.4,
                    "min": 76.1,
                    "max": 82.5,
                    "mean": 79.2,
                    "avg7": 78.7,
                    "avg30": 79.2,
                    "slope7": { "slope": -0.04, "direction": "down", "confidence": 0.62 },
                    "slope30": { "slope": -0.02, "direction": "down", "confidence": 0.41 },
                    "slope90": null,
                    "anomalyCount": 0,
                    "avg30LastMonth": 80.1,
                    "avg30LastYear": null
                },
                "BLOOD_PRESSURE_SYS": {
                    "count": 92,
                    "latest": 132,
                    "avg30": 134,
                    "anomalyCount": 1
                },
                "BLOOD_PRESSURE_DIA": {
                    "count": 92,
                    "latest": 84,
                    "avg30": 86,
                    "anomalyCount": 0
                }
            },
            "bmi": 25.1,
            "bmiClassification": "overweight",
            "bpClassification": "high_normal",
            "bpPctInTarget": 71,
            "bpTargets": { "sysLow": 120, "sysHigh": 129, "diaLow": 70, "diaHigh": 79 },
            "weightBpCorrelation": { "r": 0.41, "strength": "moderat", "n": 78 },
            "scatterData": [
                { "weight": 78.4, "sysBP": 132 },
                { "weight": 79.1, "sysBP": 136 }
            ],
            "bpMedicationCorrelation": {
                "r": -0.38, "strength": "schwach", "n": 64, "medicationCount": 2
            },
            "bpMedicationScatterData": [
                { "continuityPct": 100, "sysBP": 128 },
                { "continuityPct": 50,  "sysBP": 138 }
            ],
            "moodSummary": {
                "count": 45, "latest": 4, "mean": 3.6, "avg7": 3.8, "avg30": 3.6
            },
            "moodBpCorrelation": { "r": -0.22, "strength": "schwach", "n": 41 },
            "moodBpScatterData": [ { "mood": 4, "sysBP": 128 } ],
            "moodWeightCorrelation": null,
            "moodWeightScatterData": [],
            "moodPulseCorrelation": { "r": 0.12, "strength": "keine", "n": 38 },
            "moodPulseScatterData": [ { "mood": 3, "pulse": 72 } ],
            "medications": [
                {
                    "id": "med-1",
                    "name": "Lisinopril",
                    "dose": "5 mg",
                    "category": "BLOOD_PRESSURE",
                    "compliance7": 94,
                    "compliance30": 90,
                    "streak": 5,
                    "taken7": 7,
                    "skipped7": 0,
                    "missed7": 0
                }
            ],
            "alerts": [
                { "level": "warning", "title": "BMI in overweight range", "message": "Your BMI of 25.1 is in the overweight range." },
                { "level": "success", "title": "Excellent compliance: Lisinopril", "message": "94% compliance over the last 7 days." }
            ],
            "hasProvider": true,
            "dataSpanDays": 92,
            "totalMeasurements": 247
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        let digest = try #require(response.digest)

        // Summaries map decoded with all three keys.
        #expect(digest.summaries?["WEIGHT"]?.latest == 78.4)
        #expect(digest.summaries?["WEIGHT"]?.slope7?.direction == .down)
        #expect(digest.summaries?["BLOOD_PRESSURE_SYS"]?.avg30 == 134)
        #expect(digest.summaries?["BLOOD_PRESSURE_DIA"]?.avg30 == 86)

        // BMI + classification.
        #expect(digest.bmi == 25.1)
        #expect(digest.bmiClassification == .overweight)

        // BP classification + target adherence + targets band.
        #expect(digest.bpClassification == .highNormal)
        #expect(digest.bpPctInTarget == 71)
        #expect(digest.bpTargets?.sysLow == 120)
        #expect(digest.bpTargets?.sysHigh == 129)

        // Correlations + scatter data.
        #expect(digest.weightBpCorrelation?.r == 0.41)
        #expect(digest.weightBpCorrelation?.strength == .moderat)
        #expect(digest.weightBpCorrelation?.n == 78)
        #expect(digest.scatterData?.count == 2)
        #expect(digest.scatterData?.first?.weight == 78.4)

        #expect(digest.bpMedicationCorrelation?.r == -0.38)
        #expect(digest.bpMedicationCorrelation?.medicationCount == 2)
        #expect(digest.bpMedicationScatterData?.first?.continuityPct == 100)

        // Mood correlations — keine + null handled.
        #expect(digest.moodBpCorrelation?.strength == .schwach)
        #expect(digest.moodWeightCorrelation == nil)
        #expect(digest.moodPulseCorrelation?.strength == .keine)

        // Medications.
        #expect(digest.medications?.count == 1)
        #expect(digest.medications?.first?.compliance30 == 90)

        // Alerts.
        #expect(digest.alerts?.count == 2)
        #expect(digest.alerts?.first?.level == .warning)
        #expect(digest.alerts?.last?.level == .success)

        // Data-span footer fields.
        #expect(digest.hasProvider == true)
        #expect(digest.dataSpanDays == 92)
        #expect(digest.totalMeasurements == 247)
    }

    @Test("Empty envelope decodes with digest == nil (helper collapses no-signal payloads)")
    func emptyEnvelopeDigestIsNil() throws {
        // The Insights-Settings test user with zero measurements gets every
        // field nullable. Decoder must not throw + the digest helper must
        // collapse the all-nil payload to nil so UI callsites can branch.
        let json = Data(#"""
        {
            "summaries": {},
            "bmi": null,
            "bmiClassification": null,
            "bpClassification": null,
            "bpPctInTarget": null,
            "bpTargets": null,
            "weightBpCorrelation": null,
            "scatterData": [],
            "bpMedicationCorrelation": null,
            "bpMedicationScatterData": [],
            "moodSummary": null,
            "moodBpCorrelation": null,
            "moodBpScatterData": [],
            "moodWeightCorrelation": null,
            "moodWeightScatterData": [],
            "moodPulseCorrelation": null,
            "moodPulseScatterData": [],
            "medications": [],
            "alerts": []
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        // hasProvider / dataSpanDays / totalMeasurements absent — so digest IS nil
        // because no field carries signal.
        #expect(response.digest == nil)
    }

    @Test("Partial envelope (BMI only) keeps digest non-nil")
    func partialEnvelope() throws {
        let json = Data(#"""
        {
            "bmi": 22.4,
            "bmiClassification": "normal"
        }
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        let digest = try #require(response.digest)
        #expect(digest.bmi == 22.4)
        #expect(digest.bmiClassification == .normal)
        #expect(digest.bpClassification == nil)
    }

    @Test("BMI classification normalises grade variants")
    func bmiClassificationNormalisation() throws {
        // Server may emit "obesity_grade_1", "obese_grade_i", "Obese Grade I" —
        // all should decode to .obeseGradeI.
        for raw in ["obesity_grade_1", "obese_grade_i", "Obese Grade I", "OBESE_GRADE_I"] {
            let json = Data(#"{"bmiClassification":"\#(raw)"}"#.utf8)
            let response = try decoder.decode(AIInsightResponse.self, from: json)
            #expect(response.digest?.bmiClassification == .obeseGradeI, "Failed normalisation for \(raw)")
        }
    }

    @Test("BMI classification accepts object envelope from rule-engine routes")
    func bmiClassificationObjectShape() throws {
        // Some server routes emit `{ category, color, severity }` instead of
        // a bare string. We accept both shapes — favouring the string path
        // but falling back to the object's `category` field.
        let json = Data(#"""
        {
            "bmiClassification": { "category": "overweight", "color": "#ffb86c", "severity": "warning" }
        }
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.digest?.bmiClassification == .overweight)
    }

    @Test("BP classification normalises ESH-2023 variants")
    func bpClassificationNormalisation() throws {
        let mapping: [(String, BPClassification)] = [
            ("optimal", .optimal),
            ("normal", .normal),
            ("high_normal", .highNormal),
            ("High-normal", .highNormal),
            ("hypertension_grade_1", .hypertensionGrade1),
            ("Hypertension Grade 1", .hypertensionGrade1),
            ("hypertension_grade_2", .hypertensionGrade2),
            ("hypertension_grade_3", .hypertensionGrade3)
        ]
        for (raw, expected) in mapping {
            let json = Data(#"{"bpClassification":"\#(raw)"}"#.utf8)
            let response = try decoder.decode(AIInsightResponse.self, from: json)
            #expect(response.digest?.bpClassification == expected, "Failed mapping for \(raw)")
        }
    }

    /// v0.7.0 W-API-RENDER — an unrecognised BMI token must decode to
    /// `.unknown`, NOT the prior medically-misleading `.normal` fallback.
    /// A server typo or a new WHO sub-band has to surface as "Unbekannt"
    /// rather than a false-reassuring green "Normalgewicht" chip.
    @Test("BMI classification maps unknown tokens to .unknown, never .normal")
    func bmiClassificationUnknown() throws {
        for raw in ["mystery_band", "grade_iv", "übergewicht_xl", ""] {
            let json = Data(#"{"bmiClassification":"\#(raw)"}"#.utf8)
            let response = try decoder.decode(AIInsightResponse.self, from: json)
            #expect(response.digest?.bmiClassification == .unknown, "Token \(raw) should map to .unknown")
            #expect(response.digest?.bmiClassification != .normal, "Token \(raw) must not masquerade as .normal")
        }
    }

    /// v0.7.0 W-API-RENDER — same contract for BP: an unknown ESH token is
    /// `.unknown`, never the dangerous `.normal` default on a hypertension
    /// surface.
    @Test("BP classification maps unknown tokens to .unknown, never .normal")
    func bpClassificationUnknown() throws {
        for raw in ["isolated_systolic", "grade_4", "stage_2_us", ""] {
            let json = Data(#"{"bpClassification":"\#(raw)"}"#.utf8)
            let response = try decoder.decode(AIInsightResponse.self, from: json)
            #expect(response.digest?.bpClassification == .unknown, "Token \(raw) should map to .unknown")
            #expect(response.digest?.bpClassification != .normal, "Token \(raw) must not masquerade as .normal")
        }
    }

    /// The `.unknown` case must round-trip through the object envelope too —
    /// `{ category: <unknown> }` decodes to `.unknown`, not a throw.
    @Test("Unknown classification token in object envelope decodes to .unknown")
    func classificationUnknownObjectShape() throws {
        let json = Data(#"""
        { "bmiClassification": { "category": "future_band", "color": "#fff" } }
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.digest?.bmiClassification == .unknown)
    }

    @Test("AI-shaped + digest fields co-exist on the same root container")
    func aiAndDigestCoexist() throws {
        // The strict-prompt path (generate endpoint) can return BOTH AI fields
        // AND digest passthrough — make sure our decoder reads both.
        let json = Data(#"""
        {
            "summary": "BD stabil im Zielbereich.",
            "recommendations": [],
            "citations": [],
            "warnings": [],
            "bmi": 23.0,
            "bmiClassification": "normal",
            "totalMeasurements": 50
        }
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.summary?.contains("Zielbereich") == true)
        #expect(response.digest?.bmi == 23.0)
        #expect(response.digest?.bmiClassification == .normal)
    }

    @Test("Correlation strength tokens decode (German enum literals)")
    func correlationStrength() throws {
        for raw in ["stark", "moderat", "schwach", "keine"] {
            let json = Data(#"{"weightBpCorrelation":{"r":0.5,"strength":"\#(raw)","n":20}}"#.utf8)
            let response = try decoder.decode(AIInsightResponse.self, from: json)
            #expect(response.digest?.weightBpCorrelation?.strength?.rawValue == raw)
        }
    }

    @Test("Alert level decoder is permissive — unknown tokens decode to .info")
    func alertLevelPermissive() throws {
        // generateAlerts emits "success" | "info" | "warning" | "danger"; if a
        // future label leaks through we should not throw the whole payload.
        let json = Data(#"""
        {"alerts":[{"level":"futureLevel","title":"X","message":"Y"}]}
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.digest?.alerts?.first?.level == .info)
    }

    @Test("TrendDirection decodes case-insensitive, defaults to throw on unknown")
    func trendDirection() throws {
        let json = Data(#"""
        {"summaries":{"WEIGHT":{"latest":78,"slope30":{"slope":-0.02,"direction":"DOWN","confidence":0.5}}}}
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.digest?.summaries?["WEIGHT"]?.slope30?.direction == .down)
    }
}
