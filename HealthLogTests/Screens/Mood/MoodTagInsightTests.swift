import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — lock the tag-chip delta formatting (proper +/− sign,
/// one fractional digit) — the load-bearing monochrome valence cue (DESIGN-B
/// §4.3: direction by glyph + sign + ink-weight, never hue).
@Suite("Mood tag-insight delta formatting")
struct MoodTagInsightTests {
    @Test("positive delta gets a leading plus")
    func positiveSign() {
        #expect(MoodTagInsightSection.deltaString(0.7).hasPrefix("+"))
        #expect(MoodTagInsightSection.deltaString(0.7).contains("0"))
    }

    @Test("negative delta uses a proper minus, not a hyphen")
    func negativeSign() {
        let s = MoodTagInsightSection.deltaString(-0.4)
        #expect(s.hasPrefix("−")) // U+2212 MINUS SIGN
        #expect(!s.hasPrefix("-")) // not ASCII hyphen
    }

    @Test("delta formats to one fractional digit")
    func oneFractionDigit() {
        // 0.74 → "+0.7" (en) — the magnitude carries exactly one decimal.
        let s = MoodTagInsightSection.deltaString(0.74)
        let digits = s.filter(\.isNumber)
        #expect(digits.count == 2) // "0" + "7"
    }
}
