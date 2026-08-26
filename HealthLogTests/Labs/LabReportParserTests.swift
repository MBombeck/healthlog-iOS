import Foundation
@testable import HealthLog
import Testing

/// Locks `LabReportParser` — the one risky component of the lab-scan flow.
///
/// Everything else in that flow is Apple's code (VisionKit capture, Vision text
/// recognition) or already-shipped code (`LabsStore` → `LabsRepository` →
/// Outbox). The parser is where a misread character silently becomes a wrong
/// number in a health record, so it is pure, locale-independent, and covered
/// here. VisionKit itself is deliberately NOT tested — there is nothing of ours
/// in it.
@Suite("LabReportParser — OCR line → lab reading")
struct LabReportParserTests {
    // MARK: - Decimal separators

    @Test(
        "German and English decimal separators both parse to the same number",
        arguments: [
            ("7,4", 7.4),
            ("7.4", 7.4),
            ("0,27", 0.27),
            ("0.27", 0.27),
            ("45", 45.0),
            ("201", 201.0),
            ("13,75", 13.75)
        ]
    )
    func decimalSeparators(token: String, expected: Double) throws {
        let parsed = try #require(LabReportParser.number(from: token), "token did not parse")
        #expect(parsed == expected)
    }

    @Test("a German line and its English twin yield the same reading")
    func germanAndEnglishLineAgree() throws {
        let german = try #require(LabReportParser.parseLine("Harnsäure 7,4 mg/dl"))
        let english = try #require(LabReportParser.parseLine("Uric acid 7.4 mg/dl"))
        #expect(german.value == 7.4)
        #expect(english.value == 7.4)
        #expect(german.unit == "mg/dl")
        #expect(english.unit == "mg/dl")
    }

    @Test(
        "mixed separators resolve the LAST one as the decimal mark",
        arguments: [
            ("1.234,5", 1234.5),
            ("1,234.5", 1234.5),
            ("12.345,67", 12345.67)
        ]
    )
    func mixedSeparators(token: String, expected: Double) throws {
        let parsed = try #require(LabReportParser.number(from: token))
        #expect(parsed == expected)
    }

    @Test("repeated separators of one kind are unambiguously grouping")
    func repeatedSeparatorsAreGrouping() throws {
        let dotted = try #require(LabReportParser.number(from: "1.234.567"))
        let commaed = try #require(LabReportParser.number(from: "1,234,567"))
        #expect(dotted == 1_234_567)
        #expect(commaed == 1_234_567)
    }

    /// The deliberate asymmetry: a single separator is ALWAYS the decimal mark,
    /// so "250.000" reads as 250.0 rather than 250000. Understating by 1000× is
    /// glaring in the review screen and gets corrected; inflating by 1000× would
    /// look plausible and land silently. This test pins the choice so it cannot
    /// be "fixed" without a deliberate decision.
    @Test("a lone separator is read as a decimal mark, never as grouping")
    func loneSeparatorIsDecimal() throws {
        let dotted = try #require(LabReportParser.number(from: "250.000"))
        let commaed = try #require(LabReportParser.number(from: "250,000"))
        #expect(dotted == 250.0)
        #expect(commaed == 250.0)
    }

    @Test(
        "malformed numeric tokens do not parse",
        arguments: ["", "-", ",", "1..2", "1,,2", "1.,2", "abc", "7,4x", "12:30", "1-2"]
    )
    func malformedNumbers(token: String) {
        #expect(LabReportParser.number(from: token) == nil)
    }

    // MARK: - Units

    @Test("a spaced unit is captured")
    func spacedUnit() throws {
        let row = try #require(LabReportParser.parseLine("Ferritin 45,3 µg/l"))
        #expect(row.analyte == "Ferritin")
        #expect(row.value == 45.3)
        #expect(row.unit == "µg/l")
        #expect(row.needsReview == false)
    }

    @Test("a unit attached directly to the value is split off")
    func attachedUnit() throws {
        let row = try #require(LabReportParser.parseLine("Harnsäure 7,4mg/dL"))
        #expect(row.value == 7.4)
        #expect(row.unit == "mg/dL")
    }

    @Test("a percent unit is recognised")
    func percentUnit() throws {
        let row = try #require(LabReportParser.parseLine("HbA1c 5,4 %"))
        #expect(row.analyte == "HbA1c")
        #expect(row.value == 5.4)
        #expect(row.unit == "%")
    }

    @Test("a reading with no unit still parses, but is flagged for review")
    func missingUnitIsFlagged() throws {
        let row = try #require(LabReportParser.parseLine("Quick-Wert 98"))
        #expect(row.value == 98)
        #expect(row.unit == nil)
        #expect(row.needsReview)
    }

    // MARK: - Reference ranges

    @Test(
        "reference ranges parse from every printed form",
        arguments: [
            ("Kalium 4,2 mmol/l 3,5–5,1", 3.5, 5.1),
            ("Kalium 4,2 mmol/l 3,5-5,1", 3.5, 5.1),
            ("Kalium 4,2 mmol/l 3,5 - 5,1", 3.5, 5.1),
            ("Kalium 4,2 mmol/l 3,5 bis 5,1", 3.5, 5.1),
            ("Potassium 4.2 mmol/l 3.5 to 5.1", 3.5, 5.1)
        ]
    )
    func referenceRanges(line: String, low: Double, high: Double) throws {
        let row = try #require(LabReportParser.parseLine(line))
        #expect(row.referenceLow == low)
        #expect(row.referenceHigh == high)
    }

    @Test("an upper-bound-only reference reads as a high bound")
    func upperBoundOnly() throws {
        let row = try #require(LabReportParser.parseLine("Cholesterin gesamt 201 mg/dl < 200"))
        #expect(row.analyte == "Cholesterin gesamt")
        #expect(row.value == 201)
        #expect(row.unit == "mg/dl")
        #expect(row.referenceLow == nil)
        #expect(row.referenceHigh == 200)
    }

    @Test("a lower-bound-only reference reads as a low bound")
    func lowerBoundOnly() throws {
        let row = try #require(LabReportParser.parseLine("HDL-Cholesterin 62 mg/dl > 40"))
        #expect(row.referenceLow == 40)
        #expect(row.referenceHigh == nil)
    }

    // MARK: - Qualitative rows

    /// Build 1 made `value` optional and added `valueText`. A qualitative row
    /// must therefore stay text — never a fabricated number, never a `0`.
    @Test(
        "a qualitative result stays text and produces no number",
        arguments: [
            ("Borrelien-IgG negativ", "Borrelien-IgG", "negativ"),
            ("Hepatitis B positiv", "Hepatitis B", "positiv"),
            ("Troponin grenzwertig", "Troponin", "grenzwertig"),
            ("HIV-Suchtest nicht nachweisbar", "HIV-Suchtest", "nicht nachweisbar"),
            ("Rheumafaktor borderline", "Rheumafaktor", "borderline")
        ]
    )
    func qualitativeRows(line: String, analyte: String, result: String) throws {
        let row = try #require(LabReportParser.parseLine(line))
        #expect(row.analyte == analyte)
        #expect(row.value == nil)
        #expect(row.valueText == result)
        #expect(row.isQualitative)
    }

    /// A comparator result is not a measurement — dropping the "<" would turn
    /// "below the assay limit" into a measured value.
    @Test("a comparator result is kept verbatim, not coerced into a number")
    func comparatorResultStaysText() throws {
        let row = try #require(LabReportParser.parseLine("Troponin T < 0,01 ng/l"))
        #expect(row.value == nil)
        #expect(row.valueText == "< 0,01")
        #expect(row.needsReview)
    }

    // MARK: - Lines that must NOT parse

    @Test(
        "report chrome yields no reading",
        arguments: [
            "Laborbericht",
            "Parameter Ergebnis Einheit Referenzbereich",
            "Referenzbereich",
            "Seite 1 von 3",
            "Page 2 of 4",
            "Probenentnahme: 12.03.2026",
            "12.03.2026",
            "2026-03-12",
            "12/03/2026",
            "Patient: Mustermann, Max",
            "Geburtsdatum 01.02.1980",
            "Material: Serum",
            "Befund vom 12.03.2026",
            "- 2 -",
            "42",
            ""
        ]
    )
    func nonReadingsAreRejected(line: String) {
        #expect(LabReportParser.parseLine(line) == nil, "line should not parse as a reading")
    }

    // MARK: - Analyte names that contain digits

    /// The classic failure mode of a naive "first number wins" parser: it steals
    /// the digits out of the analyte name.
    @Test(
        "digits inside an analyte name are not mistaken for the value",
        arguments: [
            ("Vitamin B12 456 pg/ml", "Vitamin B12", 456.0),
            ("Freies T4 1,3 ng/dl", "Freies T4", 1.3),
            ("Omega-3-Index 8,1 %", "Omega-3-Index", 8.1),
            ("Vitamin D (25-OH) 32 ng/ml", "Vitamin D (25-OH)", 32.0),
        ]
    )
    func analyteDigitsAreNotValues(line: String, analyte: String, value: Double) throws {
        let row = try #require(LabReportParser.parseLine(line))
        #expect(row.analyte == analyte)
        #expect(row.value == value)
    }

    // MARK: - Whole transcript

    @Test("a realistic transcript yields only the readings")
    func wholeTranscript() {
        let transcript = """
        Laborbericht
        Patient: Mustermann, Max
        Probenentnahme: 12.03.2026 08:15
        Parameter Ergebnis Einheit Referenzbereich
        Ferritin 45,3 µg/l 30 - 400
        Cholesterin gesamt 201 mg/dl < 200
        Kalium 4,2 mmol/l 3,5–5,1
        Borrelien-IgG negativ
        Seite 1 von 2
        """
        let rows = LabReportParser.parse(transcript: transcript)
        #expect(rows.count == 4)
        #expect(rows.map(\.analyte) == ["Ferritin", "Cholesterin gesamt", "Kalium", "Borrelien-IgG"])
        #expect(rows[0].value == 45.3)
        #expect(rows[0].referenceHigh == 400)
        #expect(rows[3].value == nil)
        #expect(rows[3].valueText == "negativ")
    }

    @Test("the raw line is carried through for the review screen")
    func rawLineIsCarried() throws {
        let row = try #require(LabReportParser.parseLine("  Ferritin 45,3 µg/l  "))
        #expect(row.rawLine == "Ferritin 45,3 µg/l")
    }
}
