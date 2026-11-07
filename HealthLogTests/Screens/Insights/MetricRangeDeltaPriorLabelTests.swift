import Foundation
@testable import HealthLog
import Testing

/// **H2 (1.1.0) — the delta caption's German reads as German.**
///
/// The QA sweep photographed "+0,2 % ggü. monat davor" on every metric page:
/// the suffix lowercased the range's display name, which in German is a noun.
/// Each range now has its own phrase. English keeps its wording, except that
/// "All data" no longer produces "vs. prior all data".
@Suite("Metric range delta — prior label")
struct MetricRangeDeltaPriorLabelTests {
    @Test("German: one grammatical phrase per range")
    func german() throws {
        let bundle = try Self.lprojBundle("de")
        #expect(MetricRangeDelta.priorLabel(for: .day, bundle: bundle) == "ggü. Vortag")
        #expect(MetricRangeDelta.priorLabel(for: .week, bundle: bundle) == "ggü. Vorwoche")
        #expect(MetricRangeDelta.priorLabel(for: .month, bundle: bundle) == "ggü. Vormonat")
        #expect(MetricRangeDelta.priorLabel(for: .sixMonths, bundle: bundle) == "ggü. den 6 Monaten davor")
        #expect(MetricRangeDelta.priorLabel(for: .year, bundle: bundle) == "ggü. Vorjahr")
        #expect(MetricRangeDelta.priorLabel(for: .all, bundle: bundle) == "ggü. früheren Daten")
    }

    @Test("1.5 VERDICTS — the server's change says it runs from the first day of the range")
    func serverChangeSuffix() throws {
        let german = try Self.lprojBundle("de")
        let english = try Self.lprojBundle("en")
        let server = try #require(MetricRangeDelta.resolve(serverDelta: 2, unit: "kg", sentiment: .neutral))
        #expect(MetricRangeDelta.suffix(for: server, range: .month, bundle: german) == "seit dem ersten Tag im Zeitraum")
        #expect(MetricRangeDelta.suffix(for: server, range: .month, bundle: english) == "since the first day in range")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let own = try #require(MetricRangeDelta.resolve(points: [100, 100, 110, 110].enumerated().map { index, value in
            SeriesPoint(id: "\(index)", at: day.addingTimeInterval(Double(index) * 86400), value: value, secondary: nil)
        }))
        #expect(MetricRangeDelta.suffix(for: own, range: .month, bundle: english) == "vs. prior month")
    }

    @Test("English keeps its wording")
    func english() throws {
        let bundle = try Self.lprojBundle("en")
        #expect(MetricRangeDelta.priorLabel(for: .month, bundle: bundle) == "vs. prior month")
        #expect(MetricRangeDelta.priorLabel(for: .sixMonths, bundle: bundle) == "vs. prior 6 months")
        #expect(MetricRangeDelta.priorLabel(for: .all, bundle: bundle) == "vs. earlier data")
    }

    private static func lprojBundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
}
