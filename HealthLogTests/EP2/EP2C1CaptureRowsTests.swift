import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

/// The measurement history row keeps source, sleep split and note in one
/// detail line instead of a source badge and extra lines.
@MainActor
@Suite("EP2C1 measurement history row")
struct EP2C1MeasurementRowTests {
    private func reading(note: String? = nil, source: MeasurementSource = .manual) -> Measurement {
        Measurement(
            id: "m-1",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            value: .scalar(72.4),
            note: note,
            source: source
        )
    }

    @Test("source alone is the detail line")
    func sourceOnly() {
        #expect(MeasurementRow.detailLine(for: reading(source: .appleHealth)) == "Apple Health")
    }

    @Test("source and note share one line, an empty note adds nothing")
    func sourceAndNote() {
        let manual = String(localized: "Manual")
        #expect(MeasurementRow.detailLine(for: reading(note: "after training")) == "\(manual), after training")
        #expect(MeasurementRow.detailLine(for: reading(note: "  ")) == manual)
    }

    @Test("a sleep day with naps puts the split between source and note")
    func sleepSplitJoins() throws {
        var night = Measurement(
            id: "s-1",
            kind: .sleep,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            value: .scalar(470),
            note: "late",
            source: .appleHealth
        )
        night.sleepSplit = SleepNightSplit(mainAsleepMinutes: 430, napCount: 1, napAsleepMinutes: 40)
        let split = try #require(night.sleepSplit?.breakdownLine)
        #expect(MeasurementRow.detailLine(for: night) == "Apple Health, \(split), late")
    }
}

/// Rows show the custom-metric band as a quiet status text; the capsule stays
/// for the detail head.
@MainActor
@Suite("EP2C1 custom metric band status")
struct EP2C1CustomMetricBandStatusTests {
    @Test("an unknown band shows nothing in the row")
    func unknownIsHidden() {
        #expect(CustomMetricBandBadge.rowStatus(.unknown) == nil)
    }

    @Test("in band is the success tone, outside is information, never an alarm")
    func tones() {
        #expect(CustomMetricBandBadge.rowStatus(.inBand)
            == HLRowStatus(String(localized: "customMetric.band.inBand"), tone: .success))
        #expect(CustomMetricBandBadge.rowStatus(.above)?.tone == .info)
        #expect(CustomMetricBandBadge.rowStatus(.below)?.tone == .info)
    }
}

/// The custom-metric page offers the app-wide period set and lists at most
/// five values before the drill row.
@MainActor
@Suite("EP2C1 custom metric period and preview")
struct EP2C1CustomMetricPeriodTests {
    @Test("the period choice is T, W, M, 6M, J, Alle")
    func fullPeriodSet() {
        #expect(CustomMetricSeries.Range.allCases == [.day, .week, .month, .sixMonths, .year, .all])
        #expect(CustomMetricSeries.Range.standard == .month)
    }

    @Test("six months keeps a value from four months ago and drops one from eight")
    func sixMonthWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func entry(_ id: String, daysAgo: Int) -> CustomMetricEntryDTO {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return CustomMetricEntryDTO(
                id: id,
                customMetricId: "cm-1",
                value: 1,
                unit: "kg",
                measuredAt: ISO8601DateFormatter.fractional.string(from: date)
            )
        }
        let kept = CustomMetricSeries.windowed(
            [entry("recent", daysAgo: 120), entry("old", daysAgo: 240)],
            range: .sixMonths,
            now: now
        )
        #expect(kept.map(\.id) == ["recent"])
    }

    @Test("the hero value follows the metric's decimals, clamped like the list")
    func fractionDigits() {
        #expect(CustomMetricSeries.fractionDigits(decimals: nil) == CustomMetricFormat.defaultFractionRange)
        #expect(CustomMetricSeries.fractionDigits(decimals: 1) == 1 ... 1)
        #expect(CustomMetricSeries.fractionDigits(decimals: 9) == 6 ... 6)
        #expect(CustomMetricSeries.fractionDigits(decimals: -2) == 0 ... 0)
    }

    @Test("five values inline, the rest behind the drill row")
    func inlinePreview() {
        #expect(CustomMetricDetailScreen.inlinePreviewCount == 5)
    }
}
