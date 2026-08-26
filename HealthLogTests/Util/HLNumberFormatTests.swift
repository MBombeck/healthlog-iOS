import Foundation
@testable import HealthLog
import Testing

/// L10N-5 — locale-aware **display** number formatting. Locks the behaviour the
/// locale-less `String(format: "%.1f", …)` idiom got wrong: a German user must
/// see a decimal **comma** ("7,5 mg"), not a point, while precision stays
/// exactly as `%.Nf` produced it.
@Suite("HLNumberFormat (L10N-5)")
struct HLNumberFormatTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    @Test("German locale renders a decimal comma")
    func germanComma() {
        #expect(HLNumberFormat.decimal(7.5, fractionDigits: 1, locale: de) == "7,5")
        #expect(HLNumberFormat.decimal(0.42, fractionDigits: 2, locale: de) == "0,42")
    }

    @Test("English locale renders a decimal point")
    func englishPoint() {
        #expect(HLNumberFormat.decimal(7.5, fractionDigits: 1, locale: en) == "7.5")
        #expect(HLNumberFormat.decimal(0.42, fractionDigits: 2, locale: en) == "0.42")
    }

    @Test("fraction length is fixed — precision matches %.Nf (padding + rounding)")
    func fixedFraction() {
        // %.1f pads a whole number to one fraction digit.
        #expect(HLNumberFormat.decimal(5, fractionDigits: 1, locale: en) == "5.0")
        #expect(HLNumberFormat.decimal(5, fractionDigits: 1, locale: de) == "5,0")
        // Rounds to the requested precision, same as %.2f.
        #expect(HLNumberFormat.decimal(0.137, fractionDigits: 2, locale: en) == "0.14")
    }
}
