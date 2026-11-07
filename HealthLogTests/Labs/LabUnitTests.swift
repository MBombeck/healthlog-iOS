import Foundation
@testable import HealthLog
import ModelsR4
import SwiftUI
import Testing

/// #160 / server #1313 (v1.46.6) — lab values without a unit.
///
/// The wire value is the UCUM unity `"1"`. Every place that prints a unit
/// after a number prints nothing for it ("3.6", not "3.6 1"); every place
/// where the unit stands alone says "No unit"; every unit field sends `"1"`
/// only when the "No unit" switch is on, never from an empty field; and the
/// switch is offered from server 1.46.6 on.
@Suite("Lab values without a unit (#160)")
struct LabUnitTests {
    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private static func lab(value: Double? = 3.6, unit: String, low: Double? = nil, high: Double? = nil) -> LabResultDTO {
        LabResultDTO(
            id: "lab-ratio",
            biomarkerId: nil,
            panel: nil,
            analyte: "CHOL/HDL",
            value: value,
            unit: unit,
            referenceLow: low,
            referenceHigh: high,
            takenAt: "2026-11-01T08:00:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .above,
            createdAt: "2026-11-01T08:00:00Z",
            updatedAt: "2026-11-01T08:00:00Z"
        )
    }

    private static func defaults(version: String?) throws -> UserDefaults {
        let suite = "LabUnitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let version {
            defaults.set(version, forKey: KnownServerVersion.defaultsKey)
        }
        return defaults
    }

    // MARK: - Display

    @Test("A reading in the unity prints the number alone, a real unit still follows")
    func readingDisplay() {
        #expect(LabValueDisplay.text(value: 3.6, valueText: nil, unit: "1") == Self.number(3.6))
        #expect(LabValueDisplay.text(value: 3.6, valueText: nil, unit: " 1 ") == Self.number(3.6))
        #expect(LabValueDisplay.text(value: 3.6, valueText: nil, unit: "") == Self.number(3.6))
        #expect(LabValueDisplay.text(value: 3.6, valueText: nil, unit: "mg/dL") == "\(Self.number(3.6)) mg/dL")
        // A unit that merely contains a 1 is a real unit.
        #expect(LabValueDisplay.text(value: 2, valueText: nil, unit: "10*3/uL") == "\(Self.number(2)) 10*3/uL")
        // The list row, the biomarker card and the detail header all read this.
        #expect(Self.lab(unit: "1").displayValue == Self.number(3.6))
    }

    @Test("Range line, conversion note and reading nudge carry no unity")
    func rangeConversionAndNudge() throws {
        let both = try #require(LabResultDetailScreen.rangeText(low: 0.8, high: 1.2, unit: "1"))
        #expect(!both.hasSuffix(" 1"))
        #expect(both.contains(Self.number(0.8)) && both.contains(Self.number(1.2)))
        let withUnit = try #require(LabResultDetailScreen.rangeText(low: 0.8, high: 1.2, unit: "mg/dL"))
        #expect(withUnit.hasSuffix(" mg/dL"))
        let onlyHigh = try #require(LabResultDetailScreen.rangeText(low: nil, high: 5, unit: "1"))
        #expect(!onlyHigh.hasSuffix(" 1"))
        #expect(LabResultDetailScreen.rangeText(low: nil, high: nil, unit: "1") == nil)

        let note = LabConversion(converted: true, sourceValue: 4, sourceUnit: "1", printedReferenceText: nil)
        let converted = try #require(note.convertedLine)
        #expect(!converted.contains("4 1"))

        #expect(ThresholdNudgeContent.formatValue(3.6, unit: "1") == 3.6.formatted(.number.precision(.fractionLength(0 ... 1))))
        #expect(ThresholdNudgeContent.formatValue(140, unit: "mg/dL") == "\(140.formatted()) mg/dL")
        let nudge = ThresholdNudgeContent(lab: Self.lab(unit: "1", high: 3.5))
        #expect(!nudge.body.contains(" 1 "))
    }

    @Test("Chart axis and VoiceOver: no unit is spoken for the unity")
    func chartAxisAndVoiceOver() {
        #expect(BiomarkerChart.valueAxisTitle(unit: "1") == String(localized: "biomarker.detail.chart.ax.valueAxis"))
        #expect(BiomarkerChart.valueAxisTitle(unit: "") == String(localized: "biomarker.detail.chart.ax.valueAxis"))
        #expect(BiomarkerChart.valueAxisTitle(unit: "mmol/L") == "mmol/L")
        #expect(BiomarkerChart.spokenValue(1.8, unit: "1") == Self.number(1.8))
        #expect(BiomarkerChart.spokenValue(1.8, unit: "mmol/L") == "\(Self.number(1.8)) mmol/L")
    }

    @Test("Where the unit stands alone it says No unit; an empty unit stays empty")
    func standaloneLabel() {
        #expect(LabUnit.standalone("1") == String(localized: "labs.unit.none"))
        #expect(LabUnit.standalone("mg/dL") == "mg/dL")
        #expect(LabUnit.standalone("") == nil)
        #expect(LabUnit.standalone(nil) == nil)
        #expect(String(localized: "labs.unit.none") != "labs.unit.none")
    }

    // MARK: - Input

    @Test("A unit field sends 1 only when No unit is on, never from an empty field")
    func wireValue() {
        #expect(LabUnit.wire(typed: "", noUnit: false) == nil)
        #expect(LabUnit.wire(typed: "   ", noUnit: false) == nil)
        #expect(LabUnit.wire(typed: "", noUnit: true) == "1")
        // Switching on keeps what was typed; the wire sends the unity.
        #expect(LabUnit.wire(typed: "mg/dL", noUnit: true) == "1")
        // Switching off again sends the typed text.
        #expect(LabUnit.wire(typed: " mg/dL ", noUnit: false) == "mg/dL")
    }

    @Test("The field shows the typed text, nothing while No unit is on, and keeps the typed text")
    func fieldBindingRestoresTypedText() {
        var typed = "mg/dL"
        let binding = Binding(get: { typed }, set: { typed = $0 })
        let locked = LabUnit.fieldBinding(typed: binding, noUnit: true)
        #expect(locked.wrappedValue.isEmpty)
        locked.wrappedValue = "x"
        #expect(typed == "mg/dL")
        let open = LabUnit.fieldBinding(typed: binding, noUnit: false)
        #expect(open.wrappedValue == "mg/dL")
        open.wrappedValue = "mmol/L"
        #expect(typed == "mmol/L")
    }

    @Test("The switch is offered from 1.46.6, not on 1.46.5 or an unknown server", arguments: [
        ("1.46.5", false), ("1.46.6", true), ("1.47.0", true), ("1.45.9", false)
    ])
    func offeredFromServer(version: String, offered: Bool) throws {
        #expect(try LabUnit.offersNoUnit(defaults: Self.defaults(version: version)) == offered)
    }

    @Test("Unknown server: no switch, unless the value already has no unit")
    func offeredForStoredUnity() throws {
        let unknown = try Self.defaults(version: nil)
        #expect(LabUnit.offersNoUnit(defaults: unknown) == false)
        #expect(LabUnit.offersNoUnit(current: "mg/dL", defaults: unknown) == false)
        #expect(LabUnit.offersNoUnit(current: "1", defaults: unknown))
    }

    @Test("Scan review: No unit sends 1, an empty unit sends none, a read 1 is not taken as No unit")
    @MainActor
    func scanReviewRow() {
        let candidate = LabScanCandidate(analyte: "A/G ratio", value: 1.8, unit: nil, rawLine: "A/G ratio 1.8")
        var row = LabScanRow(candidate: candidate, biomarkerId: nil, isLowConfidence: false)
        #expect(LabScanStore.body(for: row, takenAt: "2026-11-01").unit == nil)
        row.noUnit = true
        #expect(LabScanStore.body(for: row, takenAt: "2026-11-01").unit == "1")

        // A "1" read off the page is not a person's choice: the field starts
        // empty, the switch off, and the row is flagged for a look.
        let read = LabScanCandidate(analyte: "INR", value: 1.1, unit: "1", rawLine: "INR 1.1 1")
        let readRow = LabScanRow(candidate: read, biomarkerId: nil, isLowConfidence: false)
        #expect(readRow.unit.isEmpty)
        #expect(readRow.noUnit == false)
        #expect(readRow.isLowConfidence)
        #expect(LabScanStore.body(for: readRow, takenAt: "2026-11-01").unit == nil)
    }

    @Test("Save and next resets No unit with the analyte")
    func saveAndNextResetsNoUnit() {
        let draft = LabEntryDraft(analyte: "INR", unit: "", noUnit: true, takenAt: .now)
        #expect(draft.resetForNextValue().noUnit == false)
    }

    @Test("Marker and reading bodies carry the unity on the wire")
    func writeBodies() throws {
        let marker = BiomarkerCreate(name: "INR", unit: "1", lowerBound: 0.8, upperBound: 1.2, context: nil, panel: nil)
        let markerJSON = try #require(String(data: JSONEncoder.hlDefault.encode(marker), encoding: .utf8))
        #expect(markerJSON.contains(#""unit":"1""#))
        let reading = LabResultCreate(analyte: "INR", value: 1.1, unit: LabUnit.wire(typed: "", noUnit: true), takenAt: "2026-11-01")
        let readingJSON = try #require(String(data: JSONEncoder.hlDefault.encode(reading), encoding: .utf8))
        #expect(readingJSON.contains(#""unit":"1""#))
    }

    // MARK: - Export

    @Test("FHIR: the unity is a coded UCUM 1, an empty unit is a bare number")
    func fhirExport() {
        let unity = DoctorReportToFHIRBundle.makeLabObservation(row: Self.lab(unit: "1"), patientID: "p1")
        guard case let .quantity(quantity)? = unity.value else {
            Issue.record("expected a valueQuantity")
            return
        }
        #expect(quantity.unit?.value?.string == "1")
        #expect(quantity.code?.value?.string == "1")
        #expect(quantity.system?.value?.url.absoluteString == "http://unitsofmeasure.org")

        let empty = DoctorReportToFHIRBundle.makeLabObservation(row: Self.lab(unit: ""), patientID: "p1")
        guard case let .quantity(bare)? = empty.value else {
            Issue.record("expected a valueQuantity")
            return
        }
        #expect(bare.unit == nil)
        #expect(bare.code == nil)
    }

    // MARK: - POLISH-A (F-LAB-1, F-LAB-2, F-SUPP-1)

    @Test("the statistics row of a ratio prints no unit; a real unit stays")
    func statsUnitOfARatio() {
        #expect((LabUnit.suffix("1") ?? "").isEmpty)
        #expect(LabUnit.suffix("mg/dL") == "mg/dL")
    }

    @Test("a reading's source reads as words, never the raw server value")
    func sourceInWords() {
        for raw in ["MANUAL", "OCR", "DOCUMENT", "IMPORT", "manual", "SOMETHING_NEW"] {
            let name = LabUnit.sourceName(raw)
            #expect(!name.isEmpty)
            #expect(name != raw && !name.hasPrefix("labs.source."), "\(raw)")
        }
        #expect(LabUnit.sourceName("MANUAL") == LabUnit.sourceName("manual"))
        #expect(LabUnit.sourceName("SOMETHING_NEW") == String(localized: "labs.source.other"))
    }

    @Test("a nutrient day key reads as a date, never as YYYY-MM-DD")
    func nutrientDayAsDate() throws {
        let text = try #require(RelatedRecordFormat.date("2026-11-06"))
        #expect(text != "2026-11-06")
        #expect(text.contains("2026"))
    }
}
