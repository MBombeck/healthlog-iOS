import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0153 I4 guard.** The Blutdruck Insights page must show min/max/median for
/// BOTH components. The server `SeriesStats` covers systolic (the primary)
/// only; diastolic lives per-point as `SeriesPoint.secondary` and is aggregated
/// on-device by `ChartDetailStore.diastolicStats` / `diastolicMedian`. These
/// tests pin that aggregation against a known BP series and confirm the
/// accessors self-suppress for non-BP kinds.
@Suite("ChartDetailStore — diastolic stats (I4)", .serialized)
@MainActor
struct ChartDetailStoreDiastolicStatsTests {
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeStore(kind: MetricKind) throws -> ChartDetailStore {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let insightsRepo = MetricInsightsRepository(api: api)
        return ChartDetailStore(
            kind: kind,
            measurementsRepo: measurementsRepo,
            insightsRepo: insightsRepo,
            resolveLocale: { "de" }
        )
    }

    /// systolic / diastolic pairs: 120/80, 130/85, 118/78, 140/90
    private func bpSeries() -> MeasurementSeries {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let points: [SeriesPoint] = [
            SeriesPoint(id: "1", at: base, value: 120, secondary: 80),
            SeriesPoint(id: "2", at: base.addingTimeInterval(3600), value: 130, secondary: 85),
            SeriesPoint(id: "3", at: base.addingTimeInterval(7200), value: 118, secondary: 78),
            SeriesPoint(id: "4", at: base.addingTimeInterval(10800), value: 140, secondary: 90)
        ]
        // Server SeriesStats reflects systolic (the primary) only.
        let systolicStats = SeriesStats(mean: 127, min: 118, max: 140, stdDev: 0, count: 4)
        return MeasurementSeries(kind: .bloodPressure, points: points, stats: systolicStats, unit: "mmHg")
    }

    @Test("diastolicStats aggregates min/max/mean over SeriesPoint.secondary")
    func diastolicStatsAggregatesSecondary() throws {
        let store = try makeStore(kind: .bloodPressure)
        store.series = bpSeries()
        let dia = try #require(store.diastolicStats)
        #expect(dia.min == 78) // min(80,85,78,90)
        #expect(dia.max == 90) // max(80,85,78,90)
        // mean(80,85,78,90) = 333 / 4 = 83.25
        #expect(abs(dia.mean - 83.25) < 0.0001)
        #expect(dia.count == 4)
    }

    @Test("diastolicMedian is the median of SeriesPoint.secondary, not systolic")
    func diastolicMedianUsesSecondary() throws {
        let store = try makeStore(kind: .bloodPressure)
        store.series = bpSeries()
        // sorted diastolic = 78, 80, 85, 90 → median = (80 + 85) / 2 = 82.5
        #expect(store.diastolicMedian == 82.5)
        // systolic median would be (120 + 130) / 2 = 125 — must differ.
        #expect(store.median == 125)
    }

    @Test("diastolic accessors self-suppress for non-BP kinds")
    func nonBPReturnsNil() throws {
        let store = try makeStore(kind: .weight)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.series = MeasurementSeries(
            kind: .weight,
            points: [SeriesPoint(id: "1", at: base, value: 80, secondary: nil)],
            stats: SeriesStats(mean: 80, min: 80, max: 80, stdDev: 0, count: 1),
            unit: "kg"
        )
        #expect(store.diastolicStats == nil)
        #expect(store.diastolicMedian == nil)
    }

    @Test("BP series with no diastolic peers → diastolicStats nil (no empty row)")
    func bpWithoutSecondaryReturnsNil() throws {
        let store = try makeStore(kind: .bloodPressure)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.series = MeasurementSeries(
            kind: .bloodPressure,
            points: [SeriesPoint(id: "1", at: base, value: 120, secondary: nil)],
            stats: SeriesStats(mean: 120, min: 120, max: 120, stdDev: 0, count: 1),
            unit: "mmHg"
        )
        #expect(store.diastolicStats == nil)
        #expect(store.diastolicMedian == nil)
    }
}
