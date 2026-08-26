import Foundation
@testable import HealthLog
import Testing

/// A360-5 H-4 — locale-aware decimal parsing for typed numeric input. Locks the
/// behaviours the naive `Double(text.replacing(",","."))` idiom got wrong:
/// German comma decimals, grouped thousands, and explicit parse failure.
@Suite("LocaleDecimalParser (A360-5 H-4)")
struct LocaleDecimalParserTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    @Test("German comma decimal parses")
    func germanComma() {
        #expect(LocaleDecimalParser.parse("5,5", locale: de) == 5.5)
        #expect(LocaleDecimalParser.parse("72,4", locale: de) == 72.4)
    }

    @Test("German grouped thousands parse (the naive replace broke this)")
    func germanGrouped() {
        // "1.234,5" is 1234.5 in de-DE. The old replace turned it into the
        // unparseable "1.234.5" → nil; the formatter reads it correctly.
        #expect(LocaleDecimalParser.parse("1.234,5", locale: de) == 1234.5)
    }

    @Test("English dot decimal parses on both locales")
    func englishDot() {
        #expect(LocaleDecimalParser.parse("72.4", locale: en) == 72.4)
        // A de-locale user who typed a dot still succeeds via the fallback.
        #expect(LocaleDecimalParser.parse("72.4", locale: de) == 72.4)
    }

    @Test("empty / whitespace / garbage returns nil (visible failure, not silent zero)")
    func failures() {
        #expect(LocaleDecimalParser.parse("", locale: de) == nil)
        #expect(LocaleDecimalParser.parse("   ", locale: de) == nil)
        #expect(LocaleDecimalParser.parse("abc", locale: de) == nil)
        // Multi-dot ambiguous input must not silently read as 1.0.
        #expect(LocaleDecimalParser.parse("1.000.000", locale: en) == nil)
    }

    @Test("plain integer parses")
    func integer() {
        #expect(LocaleDecimalParser.parse("80", locale: de) == 80)
        #expect(LocaleDecimalParser.parse("80", locale: en) == 80)
    }
}
