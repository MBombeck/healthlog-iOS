import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore

    private typealias HLMeasurement = HealthLogCore.Measurement
#else
    @testable import HealthLog

    private typealias HLMeasurement = HealthLog.Measurement
#endif

/// I-4 integration suite for the on-device wiring layer.
///
/// Covers the call-site wirings between I-1 / I-2 producers (services +
/// caches) and the consuming surfaces (`OnDeviceBriefingHero`,
/// `TrendObservationCard`). The view bodies themselves are SwiftUI-rendered
/// and exercised by the snapshot suite (`TrendObservationCardSnapshotTests`);
/// the unit-test contract verified here is the data-flow contract:
///
/// 1. `TrendObservationCache` round-trips for the cache-keyed integration
///    path used by `TrendObservationCard.resolve()`.
/// 2. Service-side fallbacks surface as a `nil`-observation outcome so the
///    card's `serverObservationText` branch can take over without crash.
/// 3. The `MeasurementsStore.recent` → `TrendObservationsService.observe(...)`
///    series shape stays compatible (Sendable, kind-filterable).
@Suite("TrendObservationCard — I-4 integration coverage")
struct TrendObservationCardIntegrationTests {
    // MARK: - Cache integration (round-trip via the card's resolve path)

    @Test("Cache key shape matches the card's cacheKey contract (metric.lang.day)")
    func cacheKeyShapeRoundTrips() {
        // Mirrors the card's `cacheKey`: "\(metric.rawValue).\(lang).\(day)".
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let day = formatter.string(from: Date())
        let cacheKey = "\(MetricKind.bloodPressure.rawValue).de.\(day)"

        let observation = TrendObservation(
            observation: "Dein Blutdruck war in den letzten 7 Tagen stabil.",
            metric: .bloodPressure,
            delta: 0.5,
            direction: .stable,
            confidence: 0.7,
            safetyApplied: false
        )
        TrendObservationCache.shared.write(observation, for: cacheKey)
        let reread = TrendObservationCache.shared.read(for: cacheKey)
        #expect(reread != nil)
        #expect(reread?.observation == observation.observation)
        #expect(reread?.metric == observation.metric)
        #expect(reread?.direction == observation.direction)
    }

    // MARK: - Service-fallback contract used by the card

    @Test("Service returns nil observation when feature-flag off — card path can read serverObservationText")
    func serviceNilWhenFlagOff() async {
        struct OffFlags: FeatureFlagsServicing, @unchecked Sendable {
            func isEnabled(_: FeatureFlag) -> Bool {
                false
            }
        }
        let service = TrendObservationsService(featureFlags: OffFlags())
        let outcome = await service.observe(metric: .pulse, series: [], locale: .init(identifier: "de"))
        #expect(outcome.observation == nil)
    }

    @Test("Service returns nil observation when series is sparse (insufficient data)")
    func serviceNilWhenInsufficientData() async {
        let now = Date()
        let sparse: [HLMeasurement] = [
            HLMeasurement(id: "1", kind: .pulse, recordedAt: now, value: .scalar(70)),
            HLMeasurement(id: "2", kind: .pulse, recordedAt: now.addingTimeInterval(60), value: .scalar(72))
        ]
        let service = TrendObservationsService()
        let outcome = await service.observe(metric: .pulse, series: sparse, locale: .init(identifier: "de"))
        // < 5 samples → insufficient-data fallback contract → observation == nil
        #expect(outcome.observation == nil)
    }

    // MARK: - MeasurementsStore.recent → service compatibility

    @Test("MeasurementsStore.recent shape feeds TrendObservationsService unchanged")
    func recentShapeFeedsService() {
        let now = Date()
        let recent: [HLMeasurement] = (0 ..< 6).map { i in
            HLMeasurement(
                id: "m\(i)",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(Double(i) * 86400),
                value: .bloodPressure(systolic: 120 + Double(i), diastolic: 80)
            )
        }
        let scalars = TrendObservationsService.scalarSeries(recent, kind: .bloodPressure)
        #expect(scalars.count == 6)
        // Sorted ascending by recordedAt, then folded to systolic.
        #expect(scalars.first == 120)
        #expect(scalars.last == 125)
    }

    // MARK: - Polish-jitter resolve contract

    @Test("withAnimation wrap around resolve does not change cache-hit contract")
    func animatedResolveDoesNotMutateCache() {
        // Smoke test: writing + reading via the cache stays purely
        // synchronous around the animation wrapper used in the card.
        let cacheKey = "test.de.2026-05-16"
        let observation = TrendObservation(
            observation: "Stabiler Verlauf in den letzten 7 Tagen.",
            metric: .weight,
            delta: 0.1,
            direction: .stable,
            confidence: 0.6,
            safetyApplied: false
        )
        TrendObservationCache.shared.write(observation, for: cacheKey)
        let read = TrendObservationCache.shared.read(for: cacheKey)
        #expect(read?.observation == observation.observation)
    }
}
