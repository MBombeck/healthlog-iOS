import Foundation
@testable import HealthLog
import Testing

/// FORM-5 — locale-aware, display-only headline-dose parsing.
///
/// `MedicationDetailStore.parseHeadlineDose` used to blindly replace ","→"."
/// before `Double(_:)`, which mangled a German grouped headline
/// ("1.000 mg" → `1.0`, wrong by 1000×). It now extracts the leading numeric
/// token and delegates to `LocaleDecimalParser`, honouring the locale's
/// decimal + grouping separators. These parses are display-only — nothing here
/// touches a persisted value.
@MainActor
@Suite("parseHeadlineDose (locale-aware)")
struct ParseHeadlineDoseTests {
    @Test("Plain integer dose parses to its value, locale-independent")
    func plainInteger() {
        #expect(MedicationDetailStore.parseHeadlineDose("5 mg", locale: Locale(identifier: "en_US")) == 5)
        #expect(MedicationDetailStore.parseHeadlineDose("5 mg", locale: Locale(identifier: "de_DE")) == 5)
    }

    @Test("German grouped '1.000 mg' is not mangled to 1.0")
    func germanGrouped() {
        // Under a German locale "." is a grouping separator: 1.000 == one
        // thousand, NOT 1.0. The old comma→dot replace produced 1.0 (wrong).
        let value = MedicationDetailStore.parseHeadlineDose("1.000 mg", locale: Locale(identifier: "de_DE"))
        #expect(value == 1000)
        #expect(value != 1.0)
    }

    @Test("Comma-decimal '0,5 mg' parses to 0.5")
    func commaDecimal() {
        #expect(MedicationDetailStore.parseHeadlineDose("0,5 mg", locale: Locale(identifier: "de_DE")) == 0.5)
        #expect(MedicationDetailStore.parseHeadlineDose("0,5 mg", locale: Locale(identifier: "en_US")) == 0.5)
    }

    @Test("Non-numeric headline yields nil")
    func nonNumeric() {
        #expect(MedicationDetailStore.parseHeadlineDose("ohne Dosis", locale: Locale(identifier: "de_DE")) == nil)
        #expect(MedicationDetailStore.parseHeadlineDose("mg", locale: Locale(identifier: "en_US")) == nil)
    }
}
