import Foundation
@testable import HealthLog
import Testing

/// **POLISH-B B2 (1.5, MATRIX M6).** The widget "Latest measurement" read
/// "72.4 kg, in 4 hours": a reading stamped after the widget's clock (a clock
/// skew between devices, a time zone mix-up at the source, a fixture) was
/// formatted as a time still to come. A measurement cannot lie in the future,
/// so the relative line never names one: such a stamp reads as now.
@Suite("POLISH-B B2 — Latest measurement never shows a time in the future")
struct LatestMeasurementFutureTimeTests {
    private static let now = Date(timeIntervalSince1970: 1_793_950_000)

    private static func latest(at date: Date) -> WidgetSnapshot.LatestMeasurement {
        WidgetSnapshot.LatestMeasurement(
            kindRaw: "WEIGHT",
            title: "Gewicht",
            formattedValue: "72,4",
            unit: "kg",
            symbol: "scalemass",
            recordedAt: date
        )
    }

    @Test("a stamp after now reads as now", arguments: [1, 60, 4 * 3600, 3 * 86400] as [Double])
    func futureClampsToNow(seconds: Double) {
        let reading = Self.latest(at: Self.now.addingTimeInterval(seconds))
        #expect(reading.shownDate(now: Self.now) == Self.now)
    }

    @Test("a past stamp stays exactly as recorded", arguments: [0, 60, 2 * 3600, 40 * 86400] as [Double])
    func pastIsUnchanged(seconds: Double) {
        let recorded = Self.now.addingTimeInterval(-seconds)
        #expect(Self.latest(at: recorded).shownDate(now: Self.now) == recorded)
    }

    @Test("formatted the widget's way, a future stamp no longer reads as still to come")
    func formattedLineIsNotFuture() {
        var style = Date.RelativeFormatStyle(presentation: .named)
        style.locale = Locale(identifier: "en_US")
        let reading = Self.latest(at: Date.now.addingTimeInterval(4 * 3600))
        let line = reading.shownDate(now: .now).formatted(style)
        #expect(!line.hasPrefix("in "), "\(line)")
    }
}
