import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#108 / #115 1.4 — one chart screen, one glucose unit.**
///
/// `GET /api/measurements/series` converts glucose into the ACCOUNT's unit and
/// stamps it on the payload (`MeasurementsSeriesResponse.unit`, server v1.39.0:
/// "`glucose` follows the user's mg/dL|mmol/L preference"). The analytics
/// summary (`avg30LastYear`) stays canonical mg/dL and the app converts it.
/// Before the fix the conversion used the DEVICE pick, so an account in mmol/L
/// on a phone still set to mg/dL showed the chart in mmol/L and the year-ago
/// row beneath it in mg/dL.
@Suite("ChartDetailStore — glucose summary follows the series unit (#108)", .mockURLSession)
@MainActor
struct ChartDetailGlucoseUnitTests {
    private func makeStore(kind: MetricKind) throws -> ChartDetailStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try ChartDetailStore(
            kind: kind,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" }
        )
    }

    /// A series payload in the `MeasurementsSeriesResponse` shape for an
    /// account in mmol/L: values already converted by the server.
    private func mmolSeries() throws -> MeasurementSeries {
        let json = #"""
        {"kind":"glucose","unit":"mmol/L",
         "points":[{"id":"g1","at":"2026-09-20T07:00:00.000Z","value":5.5,"secondary":null},
                   {"id":"g2","at":"2026-09-21T07:00:00.000Z","value":6.1,"secondary":null}],
         "stats":{"mean":5.8,"min":5.5,"max":6.1,"stdDev":0.3,"count":2}}
        """#
        return try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(json.utf8))
    }

    @Test("Device pick mg/dL, account mmol/L: the summary converts into the chart's unit")
    func summaryFollowsSeriesUnit() throws {
        let store = try makeStore(kind: .glucose)
        store.series = try mmolSeries()
        let device = UnitPreferences(glucose: .mgdL)

        #expect(store.displayUnit(units: device) == "mmol/L")
        #expect(store.summaryDisplayUnit(units: device) == store.displayUnit(units: device))
        // A canonical 99 mg/dL year-ago mean reads as 5.49 mmol/L, not 99.
        #expect(abs(store.convertSummaryValue(99, units: device) - 99 / 18.0182) < 0.0001)
        #expect(store.effectiveUnits(device).glucose == .mmolL)
    }

    @Test("A series in mg/dL keeps mg/dL even when the device still says mmol/L")
    func mgdlSeriesWins() throws {
        let store = try makeStore(kind: .glucose)
        store.series = MeasurementSeries(
            kind: .glucose,
            points: [],
            stats: SeriesStats(mean: 99, min: 99, max: 99, stdDev: 0, count: 1),
            unit: "mg/dL"
        )
        let device = UnitPreferences(glucose: .mmolL)
        #expect(store.summaryDisplayUnit(units: device) == "mg/dL")
        #expect(store.convertSummaryValue(99, units: device) == 99)
    }

    @Test("No series unit (older server) and non-glucose kinds keep the settings units")
    func fallsBackToSettings() throws {
        let glucose = try makeStore(kind: .glucose)
        glucose.series = MeasurementSeries(
            kind: .glucose,
            points: [],
            stats: SeriesStats(mean: 99, min: 99, max: 99, stdDev: 0, count: 1)
        )
        #expect(glucose.effectiveUnits(UnitPreferences(glucose: .mmolL)).glucose == .mmolL)

        let weight = try makeStore(kind: .weight)
        weight.series = MeasurementSeries(
            kind: .weight,
            points: [],
            stats: SeriesStats(mean: 80, min: 80, max: 80, stdDev: 0, count: 1),
            unit: "mmol/L"
        )
        #expect(weight.effectiveUnits(UnitPreferences(weight: .lb)) == UnitPreferences(weight: .lb))
    }
}

// swiftlint:enable force_unwrapping
