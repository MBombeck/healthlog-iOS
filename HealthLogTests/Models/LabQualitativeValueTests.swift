import Foundation
@testable import HealthLog
import Testing

/// **Build 1 / item 1.5 — qualitative lab results (`valueText`).**
///
/// `LabsDTO.value` was a non-optional `Double`, so the server's qualitative row
/// shape (`{"value": null, "valueText": "negativ"}` — web `types.ts:11-13`,
/// live since v1.18.9) decoded to a fabricated `value = 0` and rendered as an
/// empty measurement. These tests pin the honest decode: `value` stays `nil`,
/// `valueText` survives, and NO surface invents a zero.
///
/// Follows the tolerant-decode idiom of `MedicationInventoryGenericTests` —
/// minimal payloads, explicit nulls, and an encode→decode round-trip.
@Suite("Labs — qualitative results (valueText)")
struct LabQualitativeValueTests {
    // MARK: - The headline decode contract

    @Test("Qualitative row round-trips: value nil, valueText preserved, never a fabricated 0")
    func qualitativeRowDecodesHonestly() throws {
        let json = Data("""
        {
          "id": "lab-qual-1",
          "biomarkerId": null,
          "panel": "Serologie",
          "analyte": "Borrelien-IgG",
          "value": null,
          "valueText": "negativ",
          "unit": "",
          "takenAt": "2026-07-04T08:30:00Z",
          "source": "MANUAL",
          "hasNote": false,
          "rangeStatus": "unknown"
        }
        """.utf8)
        let row = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: json)

        #expect(row.value == nil, "an explicit null value must NOT become 0")
        #expect(row.valueText == "negativ")
        #expect(row.isQualitative)
        #expect(!row.valueIsAbsent, "a qualitative row HAS a result — it is not data-absent")
        #expect(row.displayValue == "negativ", "the row renders its result, not an empty measurement")
    }

    @Test("Qualitative row survives an encode → decode round-trip")
    func qualitativeRoundTrip() throws {
        let json = Data(#"{"id":"l1","analyte":"HIV","value":null,"valueText":"negativ","unit":""}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: json)
        let reencoded = try JSONEncoder().encode(decoded)
        let text = try #require(String(data: reencoded, encoding: .utf8))

        #expect(!text.contains("\"value\":"), "absence of a number must not re-encode as 0")
        #expect(text.contains("negativ"))

        let again = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: reencoded)
        #expect(again.value == nil)
        #expect(again.valueText == "negativ")
    }

    @Test("A missing value KEY and an explicit null both decode to nil")
    func missingKeyAndExplicitNullAgree() throws {
        let omitted = try JSONDecoder.hlDefault.decode(
            LabResultDTO.self,
            from: Data(#"{"id":"a","analyte":"TSH","unit":"mU/L"}"#.utf8)
        )
        let explicitNull = try JSONDecoder.hlDefault.decode(
            LabResultDTO.self,
            from: Data(#"{"id":"b","analyte":"TSH","value":null,"unit":"mU/L"}"#.utf8)
        )
        #expect(omitted.value == nil)
        #expect(explicitNull.value == nil)
        #expect(omitted.valueIsAbsent)
        #expect(explicitNull.valueIsAbsent, "no number AND no text = genuinely absent")
    }

    @Test("A genuine numeric 0 is still a reading, not an absence")
    func genuineZeroIsNotAbsence() throws {
        let row = try JSONDecoder.hlDefault.decode(
            LabResultDTO.self,
            from: Data(#"{"id":"z","analyte":"Blasten","value":0,"unit":"%"}"#.utf8)
        )
        #expect(row.value == 0)
        #expect(!row.valueIsAbsent)
        #expect(!row.isQualitative)
        #expect(row.displayValue == "\(0.0.formatted(.number.precision(.fractionLength(0 ... 2)))) %")
    }

    // MARK: - Detail DTO carries the same absence

    @Test("LabResultDetailDTO carries value absence through (no ?? 0)")
    func detailCarriesAbsence() throws {
        let json = Data("""
        {"id":"d1","analyte":"Borrelien-IgG","value":null,"valueText":"grenzwertig","unit":"","note":"Kontrolle in 6 Wochen"}
        """.utf8)
        let detail = try JSONDecoder.hlDefault.decode(LabResultDetailDTO.self, from: json)

        #expect(detail.value == nil)
        #expect(detail.valueText == "grenzwertig")
        #expect(detail.isQualitative)
        #expect(!detail.valueIsAbsent)
        #expect(detail.displayValue == "grenzwertig")
        #expect(detail.note == "Kontrolle in 6 Wochen")
    }

    @Test("Detail DTO with no reading at all reads as absent")
    func detailAbsentReading() throws {
        let detail = try JSONDecoder.hlDefault.decode(
            LabResultDetailDTO.self,
            from: Data(#"{"id":"d2","analyte":"CRP","unit":"mg/L"}"#.utf8)
        )
        #expect(detail.value == nil)
        #expect(detail.valueIsAbsent)
        #expect(detail.displayValue == LabValueDisplay.absentPlaceholder)
    }

    // MARK: - Display precedence

    @Test("Display precedence: number+unit → qualitative text → em-dash")
    func displayPrecedence() {
        // Locale-independent: the number renders through the standard formatter,
        // then the unit is appended.
        let expectedNumber = 5.4.formatted(.number.precision(.fractionLength(0 ... 2)))
        #expect(LabValueDisplay.text(value: 5.4, valueText: nil, unit: "%") == "\(expectedNumber) %")
        #expect(LabValueDisplay.text(value: 5.4, valueText: nil, unit: "") == expectedNumber)
        #expect(LabValueDisplay.text(value: nil, valueText: "positiv", unit: "") == "positiv")
        // A unit must never be glued onto a qualitative result.
        #expect(LabValueDisplay.text(value: nil, valueText: "positiv", unit: "mg/dL") == "positiv")
        #expect(LabValueDisplay.text(value: nil, valueText: nil, unit: "mg/dL") == "—")
        #expect(LabValueDisplay.text(value: nil, valueText: "", unit: "") == "—")
    }

    // MARK: - Derivations must not plot a qualitative row

    @Test("Qualitative rows are excluded from stats / median / chart points")
    func qualitativeExcludedFromNumericDerivations() throws {
        func row(_ id: String, value: Double?, valueText: String? = nil, daysAgo: Int) -> LabResultDTO {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            let iso = ISO8601DateFormatter().string(from: date)
            return LabResultDTO(
                id: id, biomarkerId: nil, panel: nil, analyte: "Borrelien-IgG",
                value: value, valueText: valueText, unit: "", referenceLow: nil, referenceHigh: nil,
                takenAt: iso, source: "MANUAL", hasNote: false, rangeStatus: .unknown,
                createdAt: iso, updatedAt: iso
            )
        }
        let rows = [
            row("num-1", value: 10, daysAgo: 1),
            row("qual", value: nil, valueText: "negativ", daysAgo: 2),
            row("num-2", value: 30, daysAgo: 3)
        ]
        let bearing = BiomarkerSeries.valueBearing(rows)
        #expect(Set(bearing.map(\.id)) == ["num-1", "num-2"], "\"negativ\" has no position on a numeric axis")

        let stats = try #require(BiomarkerSeries.stats(for: rows))
        #expect(stats.count == 2)
        #expect(stats.min == 10, "the qualitative row must not drag min to 0")
        #expect(stats.mean == 20)
        #expect(BiomarkerSeries.median(for: rows) == 20)
    }

    // MARK: - Write bodies emit exactly one arm

    @Test("LabResultCreate emits valueText and OMITS value for a qualitative row")
    func createEmitsQualitativeArmOnly() throws {
        let body = LabResultCreate(
            analyte: "Borrelien-IgG",
            valueText: "negativ",
            takenAt: "2026-07-04T08:30:00Z"
        )
        let text = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(text.contains("\"valueText\":\"negativ\""))
        #expect(!text.contains("\"value\":"), "a qualitative create must not send a numeric value")
    }

    @Test("LabResultCreate emits value and OMITS valueText for a numeric row")
    func createEmitsNumericArmOnly() throws {
        let body = LabResultCreate(analyte: "HbA1c", value: 5.4, takenAt: "2026-07-04T08:30:00Z")
        let text = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(text.contains("\"value\":5.4"))
        #expect(!text.contains("valueText"))
    }

    @Test("LabResultPatch emits exactly the arm it was given")
    func patchEmitsOneArm() throws {
        let qualitative = LabResultPatch(valueText: "grenzwertig")
        let qualText = try #require(String(data: JSONEncoder().encode(qualitative), encoding: .utf8))
        #expect(qualText.contains("grenzwertig"))
        #expect(!qualText.contains("\"value\":"))

        let numeric = LabResultPatch(value: 5.4)
        let numText = try #require(String(data: JSONEncoder().encode(numeric), encoding: .utf8))
        #expect(numText.contains("\"value\":5.4"))
        #expect(!numText.contains("valueText"))
    }

    // MARK: - Threshold nudge never fires on a non-numeric row

    @Test("A qualitative row can never produce a bounded threshold breach")
    func qualitativeRowNeverNudgesOnBounds() {
        let row = LabResultDTO(
            id: "q", biomarkerId: nil, panel: nil, analyte: "Borrelien-IgG",
            value: nil, valueText: "positiv", unit: "", referenceLow: 0, referenceHigh: 1,
            takenAt: "2026-07-04T08:30:00Z", source: "MANUAL", hasNote: false,
            rangeStatus: .above, createdAt: "", updatedAt: ""
        )
        #expect(
            ThresholdNudgeContent.boundedValue(for: row) == nil,
            "there is no number to state against a numeric bound"
        )
    }
}
