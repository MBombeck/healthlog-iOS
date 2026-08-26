import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `MedicationDraftHeuristic`. Pure-function lexical extractor —
/// no Vision, no simulator. Each test feeds a synthetic OCR transcript and
/// asserts on the four extracted fields.
@Suite("MedicationDraftHeuristic — OCR-text → MedicationDraft (iOS 18-25 path)")
struct MedicationDraftHeuristicTests {
    // MARK: - Name extraction

    @Test("extract — picks the longest non-keyword line as name")
    func picksLongestLineAsName() {
        let ocr = """
        Tablette
        Metformin Hexal
        500 mg
        """
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.name == "Metformin Hexal")
    }

    @Test("extract — falls back to first line when every candidate is keyword-only")
    func fallsBackToFirstLine() {
        let ocr = "Aspirin\nTablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.name == "Aspirin")
    }

    // MARK: - Dose-strength extraction

    @Test("extract — captures DE-style comma decimal dose (0,5 mg)")
    func capturesDECommaDecimal() {
        let ocr = "Ozempic\n0,5 mg\nSpritze"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseStrength == "0,5 mg")
    }

    @Test("extract — captures EN-style dot decimal dose (0.5 mg)")
    func capturesENDotDecimal() {
        let ocr = "Ozempic\n0.5 mg"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseStrength == "0.5 mg")
    }

    @Test("extract — handles integer dose without decimal (500 mg)")
    func capturesIntegerDose() {
        let ocr = "Metformin\n500 mg\nTablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseStrength == "500 mg")
    }

    @Test("extract — handles µg / mcg interchangeably")
    func capturesMicrogramUnit() {
        let ocr1 = "Levothyroxin\n50 µg"
        let ocr2 = "Levothyroxin\n50 mcg"
        let draft1 = MedicationDraftHeuristic.extract(from: ocr1)
        let draft2 = MedicationDraftHeuristic.extract(from: ocr2)
        #expect(draft1?.doseStrength == "50 µg")
        #expect(draft2?.doseStrength == "50 mcg")
    }

    @Test("extract — IE / IU insulin units are recognised")
    func capturesInsulinUnits() {
        let ocr = "Insulin Aspart\n100 IE/ml"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        // The regex matches the leading "100 IE" — the trailing "/ml" is
        // outside the unit alternation. Either capture is acceptable; we
        // pin "100 IE" because that's what the regex returns today.
        #expect(draft?.doseStrength == "100 IE")
    }

    @Test("extract — returns nil dose when no number+unit pair present")
    func returnsNilWhenNoDose() {
        let ocr = "Aspirin\nTablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseStrength == nil)
    }

    // MARK: - Dose-form extraction

    @Test("extract — finds Filmtablette before Tablette (most-specific wins)")
    func picksMostSpecificDoseForm() {
        let ocr = "Naproxen 400\nFilmtablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseForm == "Filmtablette")
    }

    @Test("extract — Spritze for an injectable")
    func picksSpritzeForInjectable() {
        let ocr = "Ozempic\n0,5 mg\nSpritze"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseForm == "Spritze")
    }

    @Test("extract — nil doseForm when no known keyword present")
    func returnsNilDoseFormWhenAbsent() {
        let ocr = "Random Wort"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.doseForm == nil)
    }

    // MARK: - Manufacturer extraction

    @Test("extract — captures manufacturer line ending in GmbH")
    func capturesManufacturerGmbH() {
        let ocr = "Metformin 500 mg\nHexal AG\nFilmtablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.manufacturerHint == "Hexal AG")
    }

    @Test("extract — nil manufacturer when no recognised suffix present")
    func returnsNilManufacturerWhenAbsent() {
        let ocr = "Aspirin\n500 mg"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.manufacturerHint == nil)
    }

    // MARK: - Source provenance

    @Test("extract — every draft carries source == .heuristic")
    func sourceTaggedAsHeuristic() {
        let ocr = "Aspirin 500 mg\nFilmtablette"
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.source == .heuristic)
    }

    // MARK: - Edge cases

    @Test("extract — empty transcript returns nil draft")
    func emptyTranscriptReturnsNil() {
        #expect(MedicationDraftHeuristic.extract(from: "") == nil)
        #expect(MedicationDraftHeuristic.extract(from: "   \n  \n") == nil)
    }

    @Test("extract — pure-digit lines are dropped from the name pool")
    func dropsPureDigitLines() {
        let ocr = """
        12345
        Metformin
        500 mg
        """
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        // "12345" should NOT become the name; "Metformin" should win.
        #expect(draft?.name == "Metformin")
    }

    @Test("extract — Wirkstoff metadata line is dropped from name pool")
    func dropsMetadataLines() {
        let ocr = """
        Wirkstoff: Metformin
        Metformin Hexal
        500 mg
        """
        let draft = MedicationDraftHeuristic.extract(from: ocr)
        #expect(draft?.name == "Metformin Hexal")
    }
}
