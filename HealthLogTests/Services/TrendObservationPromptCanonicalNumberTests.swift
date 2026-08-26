import Foundation
@testable import HealthLog
import Testing

/// A360-5 M-5 — the external-AI trend prompt must embed CANONICAL (dot-decimal,
/// invariant-locale) numbers. On a German device the device-locale `String(
/// format:)` emitted "5,5", which is ambiguous / mis-tokenised by a server-
/// routed or external model. The prompt now pins numeric formatting to
/// `en_US_POSIX` regardless of the device locale (the prose language still
/// follows the user's locale).
@Suite("TrendObservationPrompt — canonical numbers (A360-5 M-5)")
struct TrendObservationPromptCanonicalNumberTests {
    @Test("German-locale prompt still emits dot-decimal numbers")
    func germanLocaleUsesDotDecimal() {
        let prompt = TrendObservationPrompt.build(
            metric: .weight,
            scalars: [80.5, 79.2, 78.8],
            delta: -1.7,
            direction: .falling,
            seriesCount: 3,
            locale: Locale(identifier: "de_DE")
        )
        // Canonical numbers present…
        #expect(prompt.contains("80.5"))
        #expect(prompt.contains("78.8"))
        #expect(prompt.contains("-1.7"))
        // …and NO German comma decimal leaked into a numeric token.
        #expect(!prompt.contains("80,5"))
        #expect(!prompt.contains("78,8"))
        #expect(!prompt.contains("-1,7"))
    }

    @Test("English-locale prompt is unchanged (dot-decimal)")
    func englishLocaleUnchanged() {
        let prompt = TrendObservationPrompt.build(
            metric: .weight,
            scalars: [80.5],
            delta: 0.5,
            direction: .rising,
            seriesCount: 1,
            locale: Locale(identifier: "en_US")
        )
        #expect(prompt.contains("80.5"))
        #expect(prompt.contains("+0.5"))
    }
}
