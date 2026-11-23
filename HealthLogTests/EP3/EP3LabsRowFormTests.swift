import Foundation
@testable import HealthLog
import Testing

/// The lab list, catalogue and marker page in the one row form: two lines on
/// each side at most, the range as quiet text, the page in the order of the
/// reference metric pages and the app's one period set.
@MainActor
@Suite("E-P3 labs: one row form, marker page order")
struct EP3LabsRowFormTests {
    private func row(
        id: String = "r1",
        value: Double? = 1.3,
        status: LabRangeStatus = .above,
        converted: Bool? = nil,
        sourceValue: Double? = nil,
        sourceUnit: String? = nil
    ) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: nil,
            panel: nil,
            analyte: "INR",
            value: value,
            unit: "",
            referenceLow: 0.8,
            referenceHigh: 1.2,
            takenAt: "2026-11-03T08:00:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: status,
            createdAt: "2026-11-03T08:00:00Z",
            updatedAt: "2026-11-03T08:00:00Z",
            converted: converted,
            sourceValue: sourceValue,
            sourceUnit: sourceUnit
        )
    }

    @Test("A range verdict reads as status text with its symbol and tone")
    func rowStatusForJudgedReadings() throws {
        let above = try #require(LabRangeStatus.above.rowStatus)
        #expect(above == HLRowStatus(LabRangeStatus.above.localizedLabel, icon: "arrow.up", tone: .warning))
        let inRange = try #require(LabRangeStatus.inRange.rowStatus)
        #expect(inRange == HLRowStatus(LabRangeStatus.inRange.localizedLabel, icon: "checkmark", tone: .success))
    }

    @Test("A reading without a range carries no status line in a row")
    func unknownRangeIsSilentInRows() {
        #expect(LabRangeStatus.unknown.rowStatus == nil)
    }

    @Test("A reading's detail line holds the date and, when converted, the printed value")
    func resultDetailLine() throws {
        let plain = LabResultRow.detailParts(row())
        #expect(plain.compactMap(\.self).count == 1)
        #expect(plain.first == LabsDateFormat.mediumDate("2026-11-03T08:00:00Z"))

        let converted = LabResultRow.detailParts(row(converted: true, sourceValue: 5.4, sourceUnit: "mmol/L"))
        let line = try #require(HLRowDetail.joined(converted))
        #expect(line.contains(", "))
        #expect(converted.compactMap(\.self).count == 2)
    }

    @Test("The index row counts its readings in the shared plural")
    func indexRowCount() {
        #expect(BiomarkerIndexRow.countCaption(2) == String(localized: "\(2) values"))
    }

    @Test("A catalogue entry folds panel, unit and range into one detail line")
    func catalogueDetailLine() {
        let marker = BiomarkerDTO(
            id: "m1", name: "GGT", unit: "U/L", lowerBound: 10, upperBound: 50, panel: "Leber",
            hasContext: false, context: nil,
            createdAt: "2026-08-14T08:00:00.000Z", updatedAt: "2026-08-14T08:00:00.000Z"
        )
        let parts = BiomarkerRow.detailParts(marker).compactMap(\.self)
        #expect(parts.count == 3)
        #expect(parts.first == "Leber")
        #expect(parts[1] == "U/L")
    }

    @Test("The marker page offers the app's one period set, six months included")
    func periodSet() {
        #expect(BiomarkerSeries.LabsRange.allCases == HLTimeRange.allCases)
        #expect(BiomarkerSeries.LabsRange.allCases.contains(.sixMonths))
    }

    @Test("The reference range reads as a fact with its unit; no bound, no fact")
    func referenceFact() throws {
        let both = try #require(BiomarkerSeries.referenceText(low: 10, high: 50, unit: "U/L"))
        #expect(both.hasSuffix("U/L"))
        #expect(BiomarkerSeries.referenceText(low: nil, high: 5.7, unit: "%")?.hasPrefix("≤") == true)
        #expect(BiomarkerSeries.referenceText(low: nil, high: nil, unit: "U/L") == nil)
        // The unity "1" is never printed after a number.
        #expect(BiomarkerSeries.referenceText(low: 1, high: 2, unit: "1")?.hasSuffix(" 1") == false)
    }

    @Test("The share in range counts only the readings the lab judged")
    func inRangeShare() throws {
        let rows = [
            row(id: "a", status: .inRange),
            row(id: "b", status: .above),
            row(id: "c", status: .unknown),
            row(id: "d", status: .inRange)
        ]
        let share = try #require(BiomarkerSeries.inRangeShare(rows))
        #expect(share.inRange == 2)
        #expect(share.judged == 3)
        #expect(BiomarkerSeries.inRangeShare([row(status: .unknown)]) == nil)
    }

    @Test("Statistic cells stand in the order of the reference page")
    func statCells() {
        let stats = SeriesStats(mean: 2, min: 1, max: 3, stdDev: 0.5, count: 3)
        let cells = BiomarkerSeries.statCells(stats: stats, median: 2, unit: "U/L")
        #expect(cells.map(\.label) == [
            String(localized: "Min"),
            String(localized: "chart.stat.mean"),
            String(localized: "Max"),
            String(localized: "chart.stat.median")
        ])
        #expect(cells.allSatisfy { $0.unit == "U/L" })
        #expect(BiomarkerSeries.statCells(stats: stats, median: nil, unit: "").count == 3)
    }

    @Test("The marker page shows statistics only from two numeric readings on")
    func statsNeedTwoReadings() throws {
        #expect(BiomarkerSeries.pageStats(for: [row(id: "a")]) == nil)
        #expect(BiomarkerSeries.pageStats(for: [row(id: "a"), row(id: "b", value: nil)]) == nil)
        let stats = try #require(BiomarkerSeries.pageStats(for: [row(id: "a", value: 1.1), row(id: "b", value: 1.3)]))
        #expect(stats.count == 2)
    }

    @Test("Known panel keys read in the person's language, anything else stays as written")
    func panelNames() {
        #expect(LabPanelName.display("coagulation") == String(localized: "labs.catalog.panel.coagulation"))
        #expect(LabPanelName.display("lipids") == BiomarkerSeedPanel.lipids.displayName)
        #expect(LabPanelName.display("blood_count") == BiomarkerSeedPanel.bloodCount.displayName)
        #expect(LabPanelName.display("Diabetes") == "Diabetes")
        #expect(LabPanelName.display("  ") == nil)
    }

    @Test("A reading's hero splits figure and unit; a qualitative result has no unit")
    func heroParts() {
        let numeric = LabReadingHero.Reading(value: 2.1, valueText: nil, unit: "mg/L", printed: nil).parts
        #expect(numeric.unit == "mg/L")
        #expect(numeric.number == RecordedNumber.text(2.1))
        let unity = LabReadingHero.Reading(value: 1.3, valueText: nil, unit: "1", printed: nil).parts
        #expect(unity.unit == nil)
        let text = LabReadingHero.Reading(value: nil, valueText: "negativ", unit: "mg/L", printed: nil).parts
        #expect(text.number == "negativ")
        #expect(text.unit == nil)
    }

    @Test("Outside the range reads orange as text, never as a capsule")
    func outsideRangeTone() {
        #expect(LabRangeStatus.below.badgeTone == .warning)
        #expect(LabRangeStatus.above.badgeTone == .warning)
        #expect(LabRangeStatus.inRange.badgeTone == .success)
        #expect(LabRangeBadge(status: .above).form == .text)
    }
}
