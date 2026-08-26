import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore

    private typealias HLMeasurement = HealthLogCore.Measurement
#else
    @testable import HealthLog

    private typealias HLMeasurement = HealthLog.Measurement
#endif

/// I-2 test suite for TrendObservationsService.
///
/// Reuse-policy:
/// - MDRSafetyFilter coverage is inherited from I-1
///   (OnDeviceBriefingTests). We do NOT duplicate the 15-pattern matrix
///   here; we only verify the *same instance* is reused by this service.
/// - Tests added by I-2: trend-direction detection, delta calculation,
///   structured-output decoding (via the cache round-trip — the
///   @Generable decoding itself is iOS-26-only), feature-flag short-
///   circuit (both flags), locale switch, framework-unavailable fallback,
///   insufficient-data fallback.
@Suite("TrendObservationsService — I-2 trend-observations coverage")
struct TrendObservationsServiceTests {
    // MARK: - I-1 pattern reuse verification

    @Test("MDRSafetyFilter — reused (same actor type) by TrendObservation flow")
    func mdrFilterReusedByTrendFlow() async {
        // The service exposes safetyFilter publicly so callers can verify
        // a single shared instance is in use. Construct with a known
        // filter and assert the same actor is held.
        let shared = MDRSafetyFilter()
        let service = TrendObservationsService(safetyFilter: shared)
        #expect(await service.safetyFilter === shared)
    }

    @Test("TrendObservation — feeds MDRSafetyFilter via BriefingTextProvider")
    func observationConformsToBriefingTextProvider() async {
        let observation = TrendObservation(
            observation: "Du hast in den letzten 30 Tagen 12 Messungen erfasst.",
            metric: .pulse,
            delta: 2.0,
            direction: .stable,
            confidence: 0.5,
            safetyApplied: false
        )
        let filter = MDRSafetyFilter()
        let result = await filter.scrub(observation)
        #expect(result == .passed)
    }

    @Test("TrendObservation — predictive copy refused by inherited filter")
    func observationWithPredictiveCopyRefused() async {
        let bad = TrendObservation(
            observation: "Dein Puls wird in der nächsten Woche weiter steigen.",
            metric: .pulse
        )
        let filter = MDRSafetyFilter()
        let result = await filter.scrub(bad)
        if case .refused = result {
            // expected
        } else {
            Issue.record("Expected refusal for predictive copy, got \(result)")
        }
    }

    // MARK: - Direction-detection

    @Test("direction(_:) — rising series")
    func directionRising() {
        let scalars: [Double] = [120, 122, 125, 128, 132]
        #expect(TrendObservationsService.direction(scalars) == .rising)
    }

    @Test("direction(_:) — falling series")
    func directionFalling() {
        let scalars: [Double] = [140, 135, 130, 125, 120]
        #expect(TrendObservationsService.direction(scalars) == .falling)
    }

    @Test("direction(_:) — stable series (drift < 2%)")
    func directionStable() {
        let scalars: [Double] = [120.0, 120.5, 120.2, 119.8, 120.1]
        #expect(TrendObservationsService.direction(scalars) == .stable)
    }

    @Test("direction(_:) — mixed: high variance, zero drift")
    func directionMixed() {
        // 100 → 130 → 90 → 130 → 100 — net drift zero, but huge swing.
        let scalars: [Double] = [100, 130, 90, 130, 100]
        #expect(TrendObservationsService.direction(scalars) == .mixed)
    }

    @Test("direction(_:) — insufficient data when < 5 samples")
    func directionInsufficient() {
        let scalars: [Double] = [120, 122, 125]
        #expect(TrendObservationsService.direction(scalars) == .insufficientData)
    }

    // MARK: - Delta calculation

    @Test("delta(_:) — last minus first")
    func deltaIsLastMinusFirst() {
        let scalars: [Double] = [80, 82, 85, 88, 90]
        #expect(TrendObservationsService.delta(scalars) == 10)
    }

    @Test("delta(_:) — nil for single-sample series")
    func deltaNilForSingleSample() {
        #expect(TrendObservationsService.delta([100]) == nil)
    }

    @Test("delta(_:) — nil for empty series")
    func deltaNilForEmpty() {
        #expect(TrendObservationsService.delta([]) == nil)
    }

    @Test("delta(_:) — negative delta for falling")
    func deltaNegative() {
        let scalars: [Double] = [140, 130, 120]
        #expect(TrendObservationsService.delta(scalars) == -20)
    }

    // MARK: - Scalar series extraction

    @Test("scalarSeries — blood pressure folds to systolic")
    func scalarSeriesFoldsBPToSystolic() {
        let now = Date()
        let series: [HLMeasurement] = [
            HLMeasurement(
                id: "1",
                kind: .bloodPressure,
                recordedAt: now,
                value: .bloodPressure(systolic: 130, diastolic: 85)
            ),
            HLMeasurement(
                id: "2",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(86400),
                value: .bloodPressure(systolic: 135, diastolic: 88)
            )
        ]
        let scalars = TrendObservationsService.scalarSeries(series, kind: .bloodPressure)
        #expect(scalars == [130, 135])
    }

    @Test("scalarSeries — filters out non-matching kinds")
    func scalarSeriesFiltersKinds() {
        let now = Date()
        let series: [HLMeasurement] = [
            HLMeasurement(id: "1", kind: .pulse, recordedAt: now, value: .scalar(72)),
            HLMeasurement(id: "2", kind: .weight, recordedAt: now, value: .scalar(80)),
            HLMeasurement(id: "3", kind: .pulse, recordedAt: now.addingTimeInterval(60), value: .scalar(74))
        ]
        let pulse = TrendObservationsService.scalarSeries(series, kind: .pulse)
        #expect(pulse == [72, 74])
    }

    @Test("scalarSeries — sorts ascending by recordedAt")
    func scalarSeriesSortsAscending() {
        let base = Date()
        let series: [HLMeasurement] = [
            HLMeasurement(id: "1", kind: .pulse, recordedAt: base.addingTimeInterval(200), value: .scalar(80)),
            HLMeasurement(id: "2", kind: .pulse, recordedAt: base, value: .scalar(70)),
            HLMeasurement(id: "3", kind: .pulse, recordedAt: base.addingTimeInterval(100), value: .scalar(75))
        ]
        let pulse = TrendObservationsService.scalarSeries(series, kind: .pulse)
        #expect(pulse == [70, 75, 80])
    }

    // MARK: - Feature-flag short-circuit (both flags AND-gate)

    @Test("observe — both flags required: briefing OFF blocks")
    func briefingFlagOffBlocks() async throws {
        let defaults = try #require(UserDefaults(suiteName: "test.trendflag.brief.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        flags.setEnabled(.assistantBriefing, value: false)
        flags.setEnabled(.assistantTrend, value: true)
        let service = TrendObservationsService(featureFlags: flags)
        let outcome = await service.observe(
            metric: .pulse,
            series: pulseSeries(count: 30),
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.observation == nil)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    @Test("observe — both flags required: trend sub-flag OFF blocks")
    func trendSubFlagOffBlocks() async throws {
        let defaults = try #require(UserDefaults(suiteName: "test.trendflag.sub.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        flags.setEnabled(.assistantBriefing, value: true)
        flags.setEnabled(.assistantTrend, value: false)
        let service = TrendObservationsService(featureFlags: flags)
        let outcome = await service.observe(
            metric: .pulse,
            series: pulseSeries(count: 30),
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.observation == nil)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    @Test("FeatureFlag.assistantTrend defaults ON")
    func trendFlagDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.trendflag.default.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        #expect(flags.isEnabled(.assistantTrend) == true)
    }

    // MARK: - Insufficient-data fallback

    @Test("observe — fewer than 5 samples returns insufficientData")
    func insufficientDataFallsBack() async throws {
        let defaults = try #require(UserDefaults(suiteName: "test.trend.insuff.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        let service = TrendObservationsService(featureFlags: flags)
        let outcome = await service.observe(
            metric: .pulse,
            series: pulseSeries(count: 3),
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.observation == nil)
        #expect(outcome.fallbackReason == .insufficientData)
    }

    // MARK: - Locale switching in prompt template

    @Test("TrendObservationPrompt — DE locale produces German digest")
    func promptUsesGermanForDELocale() {
        let prompt = TrendObservationPrompt.build(
            metric: .pulse,
            scalars: [70, 72, 75, 78, 80],
            delta: 10,
            direction: .rising,
            seriesCount: 5,
            locale: Locale(identifier: "de_DE")
        )
        #expect(prompt.contains("Metrik:"))
        #expect(prompt.contains("Niemals diagnostizieren") || prompt.contains("beobachtend"))
    }

    @Test("TrendObservationPrompt — EN locale produces English digest")
    func promptUsesEnglishForENLocale() {
        let prompt = TrendObservationPrompt.build(
            metric: .pulse,
            scalars: [70, 72, 75, 78, 80],
            delta: 10,
            direction: .rising,
            seriesCount: 5,
            locale: Locale(identifier: "en_US")
        )
        #expect(prompt.contains("Metric:"))
        #expect(prompt.contains("Never diagnose"))
    }

    // MARK: - Structured-output decoding (via cache round-trip)

    @Test("TrendObservationCache — round-trip preserves all fields")
    func cacheRoundTripPreservesFields() throws {
        let suiteName = "test.trend.cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = TrendObservation(
            observation: "Du hast in 30 Tagen 12 Messungen erfasst, Puls bewegt sich um 70 bpm.",
            metric: .pulse,
            delta: -2.5,
            direction: .falling,
            confidence: 0.7,
            safetyApplied: true
        )
        // Use reflection-free path: write via internal API on shared cache
        // but with a unique key under default standard. We accept the
        // shared singleton here because the key is UUID-scoped — no
        // cross-test pollution.
        let key = "test.\(UUID().uuidString)"
        TrendObservationCache.shared.write(original, for: key)
        let read = TrendObservationCache.shared.read(for: key)
        #expect(read?.observation == original.observation)
        #expect(read?.metric == .pulse)
        #expect(read?.delta == -2.5)
        #expect(read?.direction == .falling)
        #expect(read?.confidence == 0.7)
        #expect(read?.safetyApplied == true)
        // Clean up cache entry
        UserDefaults.standard.removeObject(forKey: "trend_observation_cache.\(key)")
    }

    // MARK: - Framework-unavailable (compile-gated)

    #if !canImport(FoundationModels)
        @Test("observe — framework-unavailable returns fallback")
        func frameworkUnavailableFallsBack() async throws {
            let defaults = try #require(UserDefaults(suiteName: "test.trend.fw.\(UUID().uuidString)"))
            let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
            let service = TrendObservationsService(featureFlags: flags)
            let outcome = await service.observe(
                metric: .pulse,
                series: pulseSeries(count: 30),
                locale: Locale(identifier: "de_DE")
            )
            #expect(outcome.observation == nil)
            #expect(outcome.fallbackReason == .frameworkUnavailable)
        }
    #endif

    // MARK: - Helpers

    private func pulseSeries(count: Int) -> [HLMeasurement] {
        let base = Date()
        return (0 ..< count).map { idx in
            HLMeasurement(
                id: "m-\(idx)",
                kind: .pulse,
                recordedAt: base.addingTimeInterval(TimeInterval(idx * 3600)),
                value: .scalar(70 + Double(idx % 3))
            )
        }
    }
}
