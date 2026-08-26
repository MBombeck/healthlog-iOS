import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the comprehensive Insights payload (`AIInsightResponse`) decoding
/// against the v1.4.25 server schema (15-insights-architecture §"The
/// AIInsightResponse Zod schema").
@Suite("AIInsightResponse decoding")
struct AIInsightResponseDecodingTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test("Decodes the full comprehensive shape with citations + briefing")
    func fullShape() throws {
        let json = Data(#"""
        {
            "summary": "Average systolic over the last 30 days fell by 4 mmHg.",
            "recommendations": [
                {
                    "id": "rec-1",
                    "text": "Keep the morning routine.",
                    "severity": "suggestion",
                    "metricSource": {
                        "type": "bloodPressure",
                        "timeRange": "last30days",
                        "summary": "avg systolic 134, avg diastolic 82",
                        "n": 42
                    },
                    "rationale": {
                        "dataWindow": "last30days",
                        "comparedTo": "last90days",
                        "deviation": "-4 mmHg systolic"
                    }
                }
            ],
            "citations": [
                {
                    "type": "bloodPressure",
                    "timeRange": "last30days",
                    "summary": "avg systolic 134, avg diastolic 82"
                }
            ],
            "warnings": [],
            "dailyBriefing": {
                "paragraph": "Your blood pressure is trending into target.",
                "keyFindings": [
                    {
                        "tone": "good",
                        "headline": "BP closer to target",
                        "detail": "Systolic ↓ 4 mmHg",
                        "delta": "↓ 4 mmHg",
                        "sourceWindow": "30d",
                        "sourceMetric": "bp"
                    }
                ]
            },
            "promptVersion": "4.25.0",
            "provider": "anthropic"
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.summary?.contains("systolic") == true)
        #expect(response.recommendations.count == 1)
        #expect(response.recommendations.first?.severity == .suggestion)
        #expect(response.recommendations.first?.metricSource.n == 42)
        #expect(response.citations.count == 1)
        #expect(response.dailyBriefing?.keyFindings.first?.tone == .good)
        #expect(response.dailyBriefing?.keyFindings.first?.delta == "↓ 4 mmHg")
        #expect(response.promptVersion == "4.25.0")
        #expect(response.provider == "anthropic")
        #expect(response.providerLabel == "Anthropic")
    }

    @Test("Tolerates missing optional fields (briefing / promptVersion / provider)")
    func minimalShape() throws {
        let json = Data(#"""
        {
            "summary": "Not enough data yet.",
            "recommendations": [],
            "citations": [],
            "warnings": []
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.summary == "Not enough data yet.")
        #expect(response.recommendations.isEmpty)
        #expect(response.dailyBriefing == nil)
        #expect(response.promptVersion == nil)
        #expect(response.provider == nil)
        #expect(response.providerLabel == nil)
    }

    @Test(
        "All four lowercase EN severity tokens decode without throwing",
        arguments: ["info", "suggestion", "important", "urgent"]
    )
    func severityTokens(value: String) throws {
        let json = Data(#"""
        {
            "summary": "S",
            "recommendations": [{
                "id": "r-1",
                "text": "T",
                "severity": "\#(value)",
                "metricSource": { "type": "weight", "timeRange": "last7days", "summary": "x" }
            }],
            "citations": [],
            "warnings": []
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.recommendations.first?.severity.rawValue == value)
    }

    @Test("Recommendations sort by severity descending")
    func severitySortRank() {
        let order: [RecommendationSeverity] = [.info, .suggestion, .important, .urgent]
        let ranks = order.map(\.sortRank)
        #expect(ranks == [0, 1, 2, 3])
    }

    @Test("Daily briefing tone tokens decode")
    func briefingToneTokens() throws {
        let json = Data(#"""
        {
            "paragraph": "p",
            "keyFindings": [
                { "tone": "good", "headline": "h1", "detail": "d", "sourceWindow": "7d", "sourceMetric": "bp" },
                { "tone": "watch", "headline": "h2", "detail": "d", "sourceWindow": "30d", "sourceMetric": "weight" },
                { "tone": "info", "headline": "h3", "detail": "d", "sourceWindow": "90d", "sourceMetric": "mood" }
            ]
        }
        """#.utf8)
        let briefing = try decoder.decode(DailyBriefing.self, from: json)
        #expect(briefing.keyFindings.map(\.tone) == [.good, .watch, .info])
    }

    // MARK: - v1.18.7 "Signals of the day"

    @Test("Decodes signalsOfDay (headline + nudge + tone + delta)")
    func signalsOfDayDecode() throws {
        let json = Data(#"""
        {
            "paragraph": "p",
            "keyFindings": [],
            "signalsOfDay": [
                { "sourceMetric": "bp", "tone": "watch", "headline": "Systolic up today", "nudge": "Take a calm 10-min walk.", "delta": "+6 mmHg vs your 30-day average" },
                { "sourceMetric": "sleep", "tone": "good", "headline": "Well rested", "nudge": "Keep the rhythm.", "delta": null }
            ]
        }
        """#.utf8)
        let briefing = try decoder.decode(DailyBriefing.self, from: json)
        #expect(briefing.signalsOfDay.count == 2)
        #expect(briefing.signalsOfDay.first?.tone == .watch)
        #expect(briefing.signalsOfDay.first?.sourceMetric == "bp")
        #expect(briefing.signalsOfDay.first?.delta == "+6 mmHg vs your 30-day average")
        #expect(briefing.signalsOfDay.first?.nudge == "Take a calm 10-min walk.")
        // Nullable delta decodes to nil, not an empty string.
        #expect(briefing.signalsOfDay.last?.delta == nil)
    }

    @Test("Pre-v1.18.7 briefing without signalsOfDay decodes to an empty list")
    func signalsOfDayAbsentTolerated() throws {
        let json = Data(#"""
        { "paragraph": "p", "keyFindings": [] }
        """#.utf8)
        let briefing = try decoder.decode(DailyBriefing.self, from: json)
        #expect(briefing.signalsOfDay.isEmpty)
    }

    @Test("Null signalsOfDay decodes to an empty list")
    func signalsOfDayNullTolerated() throws {
        let json = Data(#"""
        { "paragraph": "p", "keyFindings": [], "signalsOfDay": null }
        """#.utf8)
        let briefing = try decoder.decode(DailyBriefing.self, from: json)
        #expect(briefing.signalsOfDay.isEmpty)
    }

    @Test("Citation id is derived from (type, timeRange) pair")
    func citationIdentity() {
        let citation = Citation(type: "bloodPressure", timeRange: "last30days", summary: "x")
        #expect(citation.id == "bloodPressure-last30days")
    }

    /// v0.3.0 hotfix — the production `/api/insights/comprehensive` route
    /// returns a metric digest envelope (summaries / bmi / alerts / …)
    /// without any of the AI-shaped fields the W2b-A4 model was designed
    /// for. Decoder must tolerate the real shape and surface empties
    /// rather than throw "Key 'summary' Not Found".
    @Test("Tolerates the real /api/insights/comprehensive metric-digest envelope")
    func realServerMetricDigestEnvelope() throws {
        let json = Data(#"""
        {
            "summaries": {
                "WEIGHT": { "latest": 78.4 },
                "BLOOD_PRESSURE_SYS": { "avg30": 134, "latest": 130 }
            },
            "bmi": 25.1,
            "bmiClassification": "overweight",
            "bpClassification": "elevated",
            "bpPctInTarget": 71,
            "bpTargets": { "sys": 135, "dia": 85 },
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
            "alerts": [],
            "hasProvider": false,
            "dataSpanDays": 42,
            "totalMeasurements": 178
        }
        """#.utf8)

        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.summary == nil)
        #expect(response.recommendations.isEmpty)
        #expect(response.citations.isEmpty)
        #expect(response.warnings.isEmpty)
        #expect(response.dailyBriefing == nil)
        #expect(response.providerLabel == nil)
    }

    /// v0.7.0 W-API-RENDER — typed Recommendation decoding. Schema drift
    /// (type mismatch on a known field) must surface as a thrown
    /// DecodingError instead of silently coalescing into an empty
    /// recommendation. Without this guard the server could rename
    /// `severity` to `severityToken` and the iOS UI would render
    /// blank cards forever without anyone noticing.
    @Test("Severity type mismatch surfaces a decoding error (no silent empty)")
    func severityTypeMismatchThrows() {
        let json = Data(#"""
        {
            "summary": "S",
            "recommendations": [{
                "id": "r-1",
                "text": "T",
                "severity": 42,
                "metricSource": { "type": "weight", "timeRange": "last7days", "summary": "x" }
            }],
            "citations": [],
            "warnings": []
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try decoder.decode(AIInsightResponse.self, from: json)
        }
    }

    /// String-fallback union branch survives the typed-decoder fix —
    /// the legitimate `recommendations: ["plain prose"]` shape must
    /// continue to decode into a Recommendation with `.info` severity.
    @Test("Plain-string Recommendation union branch still decodes")
    func stringRecommendationUnion() throws {
        let json = Data(#"""
        {
            "summary": "S",
            "recommendations": ["just a plain prose recommendation"],
            "citations": [],
            "warnings": []
        }
        """#.utf8)
        let response = try decoder.decode(AIInsightResponse.self, from: json)
        #expect(response.recommendations.count == 1)
        #expect(response.recommendations.first?.text == "just a plain prose recommendation")
        #expect(response.recommendations.first?.severity == .info)
    }
}
