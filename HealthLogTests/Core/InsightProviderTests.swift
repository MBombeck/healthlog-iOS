import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks: `Insight.provider` decodes any free-form server string without
/// throwing — the previous narrow provider enum rejected wider model-family
/// identifiers and brought
/// the entire insights array down (W2a-A2 Audit §2.4).
@Suite("Insight.provider tolerant decoding")
struct InsightProviderTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test(
        "Provider strings decode without throwing",
        arguments: ["anthropic", "claude_haiku", "openai", "gpt_4o_mini", "gemini", "google", "future-model-2027"]
    )
    func providerDecodes(value: String) throws {
        let json = Data(#"""
        {
            "id": "i-1",
            "title": "T",
            "summary": "S",
            "body": null,
            "severity": "info",
            "recommendations": [],
            "generatedAt": "2026-05-14T08:00:00.000Z",
            "provider": "\#(value)"
        }
        """#.utf8)
        let insight = try decoder.decode(Insight.self, from: json)
        #expect(insight.provider == value)
    }

    @Test(
        "providerLabel maps known families to the friendly label",
        arguments: [
            ("anthropic", "Anthropic"),
            ("claude_haiku", "Anthropic"),
            ("openai", "OpenAI"),
            ("gpt_4o_mini", "OpenAI"),
            ("gemini", "Gemini"),
            ("google", "Gemini")
        ]
    )
    func providerLabel(provider: String, expected: String) {
        #expect(AIInsightResponse.providerFamilyLabel(provider) == expected)
    }

    @Test("Unknown provider tidies separators in the fallback label")
    func providerLabelFallback() {
        let label = AIInsightResponse.providerFamilyLabel("future-model_2027")
        // Expect title-cased, separators replaced with spaces.
        #expect(label.contains("Future"))
        #expect(label.contains("Model"))
        #expect(!label.contains("_"))
    }
}
