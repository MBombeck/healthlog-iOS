@testable import HealthLog
import Testing

/// v0.13.1 IC — locks the per-kind has-data availability contract that fixes the
/// operator-reported "blood-pressure / pulse just aren't in the Insights list"
/// bug. The Insights strip used to gate pills on the last-400 `/api/measurements`
/// recency window, which under-reports low-frequency kinds on a HealthKit
/// power-user. The fix gates on the all-time summaries slice
/// (`/api/analytics?slice=summaries`) — the SAME per-kind `count` map the web
/// uses (`metric-availability.ts`). These tests pin the pure mapping so a
/// regression in the kind ↔ server-key table or the count gate surfaces in CI.
@Suite("Measurement availability — per-kind has-data signal (IC)")
struct MeasurementAvailabilityTests {
    private func dto(_ counts: [String: Int]) -> MeasurementAvailabilityDTO {
        MeasurementAvailabilityDTO(
            summaries: counts.mapValues { MeasurementAvailabilityDTO.CountSummary(count: $0) }
        )
    }

    @Test("A low-frequency kind with all-time data lights up even though it would miss the recent window")
    func lowFrequencyKindLightsUp() {
        // BP has months of history (count > 0) but might be absent from the
        // last-400 page — the summaries count is the authoritative signal.
        let kinds = MeasurementsRepository.kinds(withDataIn: dto([
            "BLOOD_PRESSURE_SYS": 12,
            "PULSE": 400,
            "WEIGHT": 8
        ]))
        #expect(kinds.contains(.bloodPressure))
        #expect(kinds.contains(.pulse))
        #expect(kinds.contains(.weight))
    }

    @Test("count == 0 keeps a kind hidden (no dead pill)")
    func zeroCountStaysHidden() {
        let kinds = MeasurementsRepository.kinds(withDataIn: dto([
            "PULSE": 5,
            "WEIGHT": 0
        ]))
        #expect(kinds.contains(.pulse))
        #expect(!kinds.contains(.weight))
    }

    @Test("BMI availability tracks stored BODY_MASS_INDEX rows, not WEIGHT")
    func bmiFromBodyMassIndex() {
        // Regression fix: BMI's browsable history lives under BODY_MASS_INDEX
        // (stored rows, e.g. smart-scale). The old "inherit the WEIGHT count"
        // coupling made BMI look available on weight alone, but its measurement
        // list then fetched WEIGHT rows that filtered out to empty — the exact
        // "BMI shows no data" bug. Availability now follows real BMI rows; the
        // server-derived BMI headline still paints on the dashboard tile via the
        // summary regardless.
        let withBmi = MeasurementsRepository.kinds(withDataIn: dto(["BODY_MASS_INDEX": 3]))
        #expect(withBmi.contains(.bmi))
        let weightOnly = MeasurementsRepository.kinds(withDataIn: dto(["WEIGHT": 3]))
        #expect(!weightOnly.contains(.bmi))
    }

    @Test("steps maps onto the ACTIVITY_STEPS key, not the camelCase raw value")
    func stepsKeyMapping() {
        #expect(MetricKind.steps.availabilitySummaryKey == "ACTIVITY_STEPS")
        let kinds = MeasurementsRepository.kinds(withDataIn: dto(["ACTIVITY_STEPS": 99]))
        #expect(kinds.contains(.steps))
    }

    @Test("the v1.10.0 additive kinds light up from their server keys")
    func additiveKindsLightUp() {
        let kinds = MeasurementsRepository.kinds(withDataIn: dto([
            "CARDIO_RECOVERY": 2,
            "WRIST_TEMPERATURE": 4,
            "FALL_COUNT": 1,
            "SIX_MINUTE_WALK_DISTANCE": 3,
            "STAIR_ASCENT_SPEED": 5,
            "STAIR_DESCENT_SPEED": 5,
            "BREATHING_DISTURBANCES": 7
        ]))
        #expect(kinds.contains(.cardioRecovery))
        #expect(kinds.contains(.wristTemperature))
        #expect(kinds.contains(.falls))
        #expect(kinds.contains(.sixMinuteWalk))
        #expect(kinds.contains(.stairAscentSpeed))
        #expect(kinds.contains(.stairDescentSpeed))
        #expect(kinds.contains(.breathingDisturbances))
    }

    @Test("every chartable kind carries a summaries key so it can be data-gated")
    func everyKindHasAvailabilityKey() {
        // Build 7 / item 7.3 — `mood` is the one dashboard tile that is NOT a
        // `Measurement`: the summary derives it from `buildMoodDailySeries`, so it
        // has no server `MeasurementType` in the `/api/analytics?slice=summaries`
        // slice and no availability key by design. It is data-gated by the summary
        // itself (the mood card is emitted only when `entryCount > 0`), not by this
        // measurement-availability path — so it is exempt here.
        for kind in MetricKind.allCases where kind != .mood {
            #expect(
                kind.availabilitySummaryKey != nil,
                "MetricKind.\(kind) has no availabilitySummaryKey — its Insights pill could never light up"
            )
        }
        #expect(
            MetricKind.mood.availabilitySummaryKey == nil,
            "mood is not a measurement-summaries kind — it must NOT carry an availability key"
        )
    }

    @Test("an unknown server key is ignored (tolerant of server-only types)")
    func unknownKeyIgnored() {
        let kinds = MeasurementsRepository.kinds(withDataIn: dto([
            "SOME_FUTURE_SERVER_TYPE": 10,
            "PULSE": 1
        ]))
        #expect(kinds == [.pulse])
    }
}

/// v0.13.1 IC — locks the reverse slug helper the Dashboard tile tap uses to
/// drive the `.insights(metric:)` deep link (nav unification). Every chartable
/// kind must round-trip slug → kind → slug so the tap lands on the right page.
@Suite("InsightsTabSlug reverse mapping (IC nav unification)")
struct InsightsTabSlugReverseTests {
    @Test("slug(forKind:) is the exact inverse of metricKind(forSlug:)")
    func reverseIsInverse() {
        for kind in MetricKind.allCases {
            guard let slug = InsightsTabSlug.slug(forKind: kind) else { continue }
            #expect(
                InsightsTabSlug.metricKind(forSlug: slug) == kind,
                "slug(forKind: .\(kind)) = \(slug) must map back to .\(kind)"
            )
        }
    }

    @Test("the operator's examples + cardio-fitness resolve to a slug")
    func keyKindsHaveSlugs() {
        #expect(InsightsTabSlug.slug(forKind: .bloodPressure) == "blood-pressure")
        #expect(InsightsTabSlug.slug(forKind: .pulse) == "pulse")
        // cardio-fitness was the one-line gap: .vo2Max existed but had no slug.
        #expect(InsightsTabSlug.slug(forKind: .vo2Max) == "cardio-fitness")
        #expect(InsightsTabSlug.slug(forKind: .cardioRecovery) == "cardio-recovery")
    }
}
