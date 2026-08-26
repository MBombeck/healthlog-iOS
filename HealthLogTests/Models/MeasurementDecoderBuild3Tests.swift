import Foundation
@testable import HealthLog
import Testing

/// **Build 3 / item 3.3 — the 23 wire types the tolerant list decoder used to
/// throw away.**
///
/// The parity audit claimed 23 missing `ServerMeasurementType` cases. That was
/// verified against the LIVE server enum rather than taken on faith: a
/// set-difference of `prisma/schema.prisma` `enum MeasurementType` (76 members)
/// against `ServerMeasurementType` returned exactly those 23, and the reverse
/// difference was empty. These tests pin the result so a future server addition
/// shows up as a red test rather than as rows quietly vanishing.
///
/// Follows the tolerant-decode idiom of `MedicationInventoryGenericTests`:
/// assert the KNOWN rows survive, assert an unknown row is dropped rather than
/// rejecting the envelope.
@Suite("Build 3 — measurement decoder catch-up")
struct MeasurementDecoderBuild3Tests {
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// One list envelope carrying a single row of `type`.
    private static func listJSON(type: String, value: Double) -> Data {
        Data("""
        {"measurements":[
          {"id":"row-\(type)","type":"\(type)","value":\(value),"measuredAt":"2026-07-01T08:00:00Z"}
        ]}
        """.utf8)
    }

    // MARK: - ACTIVITY_STEPS — the row class that was being discarded

    @Test("ACTIVITY_STEPS decodes to MetricKind.steps instead of being dropped")
    func activityStepsDecodes() throws {
        let resp = try Self.decoder().decode(
            MeasurementListWireResponse.self,
            from: Self.listJSON(type: "ACTIVITY_STEPS", value: 8534)
        )
        #expect(resp.measurements.count == 1, "the tolerant decoder must keep an ACTIVITY_STEPS row")
        let wire = try #require(resp.measurements.first)
        #expect(wire.type == .activitySteps)
        let domain = try #require(wire.toDomain())
        #expect(domain.kind == .steps, "ACTIVITY_STEPS reuses the existing steps kind")
        #expect(domain.value.primaryComponent == 8534)
    }

    @Test("a step row keeps the server's own source instead of a synthesized one")
    func activityStepsKeepsSource() throws {
        let json = Data("""
        {"measurements":[
          {"id":"s1","type":"ACTIVITY_STEPS","value":1200,
           "measuredAt":"2026-07-01T08:00:00Z","source":"WITHINGS"}
        ]}
        """.utf8)
        let resp = try Self.decoder().decode(MeasurementListWireResponse.self, from: json)
        let domain = try #require(resp.measurements.first?.toDomain())
        // The pre-fix workaround routed steps through `/series` and stamped
        // every synthesized row `.appleHealth`. A real list row carries the
        // real provenance.
        #expect(domain.source == .withings)
    }

    @Test("BODY_MASS_INDEX decodes to the existing bmi kind")
    func bodyMassIndexDecodes() throws {
        let resp = try Self.decoder().decode(
            MeasurementListWireResponse.self,
            from: Self.listJSON(type: "BODY_MASS_INDEX", value: 23.4)
        )
        let wire = try #require(resp.measurements.first)
        #expect(wire.type == .bodyMassIndex)
        #expect(wire.toDomain()?.kind == .bmi)
    }

    // MARK: - The four screener scores

    @Test("every screener sum score decodes and maps to its own MetricKind")
    func screenerScoresDecode() throws {
        let expected: [String: MetricKind] = [
            "PHQ9_SCORE": .phq9Score,
            "GAD7_SCORE": .gad7Score,
            "WHO5_SCORE": .who5Score,
            "SCI_SCORE": .sciScore
        ]
        for (wireToken, kind) in expected {
            let resp = try Self.decoder().decode(
                MeasurementListWireResponse.self,
                from: Self.listJSON(type: wireToken, value: 12)
            )
            #expect(resp.measurements.count == 1, "screener row was dropped by the tolerant decoder")
            let domain = try #require(resp.measurements.first?.toDomain())
            #expect(domain.kind == kind, "screener wire token mapped to the wrong kind")
            #expect(domain.value.primaryComponent == 12)
        }
    }

    @Test("a COMPUTED screener row decodes its source and reads as read-only")
    func screenerRowIsReadOnly() throws {
        // Server v1.27.6 (migration 0225) stamps the screener sums `COMPUTED`.
        let json = Data("""
        {"measurements":[
          {"id":"phq-1","type":"PHQ9_SCORE","value":9,
           "measuredAt":"2026-07-01T08:00:00Z","source":"COMPUTED"}
        ]}
        """.utf8)
        let resp = try Self.decoder().decode(MeasurementListWireResponse.self, from: json)
        let domain = try #require(resp.measurements.first?.toDomain())
        #expect(domain.source == .computed)
        #expect(domain.isServerDerivedReadOnly, "a derived screener sum must not be editable")
    }

    @Test("WHO-5 and SCI are higher-is-better; PHQ-9 and GAD-7 are lower-is-better")
    func screenerPolarity() {
        #expect(MetricKind.phq9Score.descriptor.trendPolarity == .lowerIsBetter)
        #expect(MetricKind.gad7Score.descriptor.trendPolarity == .lowerIsBetter)
        // These two measure well-being, not burden — the polarity is inverted
        // and getting it wrong would paint an improving score as a regression.
        #expect(MetricKind.who5Score.descriptor.trendPolarity == .higherIsBetter)
        #expect(MetricKind.sciScore.descriptor.trendPolarity == .higherIsBetter)
    }

    // MARK: - Wearable score classes

    @Test("every WHOOP / Oura / Polar score type decodes to its own kind")
    func wearableScoresDecode() throws {
        let expected: [String: MetricKind] = [
            "RECOVERY_SCORE": .recoveryScore,
            "STRESS_SCORE": .stressScore,
            "STRAIN_SCORE": .strainScore,
            "HRV_RMSSD": .hrvRMSSD,
            "DAY_STRAIN": .dayStrain,
            "WORKOUT_STRAIN": .workoutStrain,
            "SLEEP_PERFORMANCE": .sleepPerformance,
            "SLEEP_EFFICIENCY": .sleepEfficiency,
            "SLEEP_CONSISTENCY": .sleepConsistency,
            "SLEEP_NEED": .sleepNeed,
            "ENERGY_EXPENDITURE_KJ": .energyExpenditureKJ,
            "RESILIENCE": .resilience
        ]
        for (wireToken, kind) in expected {
            let resp = try Self.decoder().decode(
                MeasurementListWireResponse.self,
                from: Self.listJSON(type: wireToken, value: 7)
            )
            #expect(resp.measurements.count == 1, "wearable score row was dropped by the tolerant decoder")
            let domain = try #require(resp.measurements.first?.toDomain())
            #expect(domain.kind == kind, "wearable score wire token mapped to the wrong kind")
        }
    }

    @Test("HRV_RMSSD is a distinct kind from Apple's SDNN heart-rate variability")
    func rmssdIsNotSDNN() {
        #expect(MetricKind.hrvRMSSD != MetricKind.hrv)
        let rmssd = MeasurementWireDTO(id: "r", type: .hrvRMSSD, value: 42, measuredAt: Date())
        let sdnn = MeasurementWireDTO(id: "s", type: .heartRateVariability, value: 42, measuredAt: Date())
        // Two different statistics over the same NN-interval series. Folding
        // them into one kind would blend numbers that routinely differ by tens
        // of milliseconds — the same doctrine that keeps the body-temperature
        // DEVIATION out of the absolute-temperature bucket.
        #expect(rmssd.toDomain()?.kind == .hrvRMSSD)
        #expect(sdnn.toDomain()?.kind == .hrv)
        #expect(MetricKind.hrvRMSSD.unit == "ms")
    }

    @Test("the 0-100 strain score and WHOOP's native 0-21 strain stay separate kinds")
    func strainScalesStaySeparate() {
        #expect(MetricKind.strainScore != MetricKind.dayStrain)
        #expect(MetricKind.dayStrain != MetricKind.workoutStrain)
    }

    @Test("energy expenditure in kJ is a distinct kind from active energy in kcal")
    func kilojoulesAreNotKilocalories() {
        #expect(MetricKind.energyExpenditureKJ != MetricKind.activeEnergy)
        #expect(MetricKind.energyExpenditureKJ.unit == "kJ")
        #expect(MetricKind.activeEnergy.unit == "kcal")
    }

    @Test("sleep need stays in minutes — no minutes-to-hours conversion")
    func sleepNeedStaysInMinutes() throws {
        // `SLEEP_DURATION` converts because `MetricKind.sleep` declares hours.
        // `SLEEP_NEED` declares minutes, so the wire value passes through and a
        // 480-minute need must NOT arrive as 8.
        let resp = try Self.decoder().decode(
            MeasurementListWireResponse.self,
            from: Self.listJSON(type: "SLEEP_NEED", value: 480)
        )
        let domain = try #require(resp.measurements.first?.toDomain())
        #expect(domain.value.primaryComponent == 480)
        #expect(MetricKind.sleepNeed.unit == "min")
    }

    // MARK: - Categorical events

    @Test("every categorical cardiac / breathing event decodes to its own kind")
    func categoricalEventsDecode() throws {
        let expected: [String: MetricKind] = [
            "IRREGULAR_RHYTHM_NOTIFICATION": .irregularRhythmNotification,
            "HIGH_HEART_RATE_EVENT": .highHeartRateEvent,
            "LOW_HEART_RATE_EVENT": .lowHeartRateEvent,
            "WALKING_STEADINESS_EVENT": .walkingSteadinessEvent,
            "BREATHING_DISTURBANCE_EVENT": .breathingDisturbanceEvent
        ]
        for (wireToken, kind) in expected {
            let resp = try Self.decoder().decode(
                MeasurementListWireResponse.self,
                from: Self.listJSON(type: wireToken, value: 1)
            )
            #expect(resp.measurements.count == 1, "categorical event row was dropped by the tolerant decoder")
            let domain = try #require(resp.measurements.first?.toDomain())
            #expect(domain.kind == kind, "categorical event wire token mapped to the wrong kind")
        }
    }

    @Test("categorical events are flagged as occurrences, not magnitudes")
    func categoricalEventsAreFlagged() {
        let events: [MetricKind] = [
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent
        ]
        for kind in events {
            #expect(kind.isCategoricalEvent, "categorical event kind must be flagged as one")
            #expect(kind.unit.isEmpty, "a 1-of-1 occurrence has no unit to print")
            #expect(kind.descriptor.secondaryHint != nil, "an event must explain that its value carries no magnitude")
        }
        // The percentage / count siblings must NOT be swept into the flag.
        #expect(!MetricKind.walkingSteadiness.isCategoricalEvent)
        #expect(!MetricKind.breathingDisturbances.isCategoricalEvent)
    }

    @Test("the walking-steadiness EVENT is a different kind than the steadiness PERCENTAGE")
    func steadinessEventIsNotSteadinessPercentage() {
        #expect(MetricKind.walkingSteadinessEvent != MetricKind.walkingSteadiness)
        #expect(MetricKind.breathingDisturbanceEvent != MetricKind.breathingDisturbances)
    }

    // MARK: - Contract-level invariants

    @Test("all 23 catch-up wire tokens decode and none is dropped from a mixed page")
    func mixedPageKeepsEveryNewType() throws {
        let tokens = [
            "ACTIVITY_STEPS", "BODY_MASS_INDEX",
            "PHQ9_SCORE", "GAD7_SCORE", "WHO5_SCORE", "SCI_SCORE",
            "RECOVERY_SCORE", "STRESS_SCORE", "STRAIN_SCORE", "HRV_RMSSD",
            "DAY_STRAIN", "WORKOUT_STRAIN",
            "SLEEP_PERFORMANCE", "SLEEP_EFFICIENCY", "SLEEP_CONSISTENCY", "SLEEP_NEED",
            "ENERGY_EXPENDITURE_KJ", "RESILIENCE",
            "IRREGULAR_RHYTHM_NOTIFICATION", "HIGH_HEART_RATE_EVENT", "LOW_HEART_RATE_EVENT",
            "WALKING_STEADINESS_EVENT", "BREATHING_DISTURBANCE_EVENT"
        ]
        #expect(tokens.count == 23, "the audit counted 23 and the live server enum agreed")
        let rows = tokens.enumerated().map { index, token in
            "{\"id\":\"r\(index)\",\"type\":\"\(token)\",\"value\":1,\"measuredAt\":\"2026-07-01T08:00:00Z\"}"
        }
        let json = Data("{\"measurements\":[\(rows.joined(separator: ","))]}".utf8)
        let resp = try Self.decoder().decode(MeasurementListWireResponse.self, from: json)
        #expect(resp.measurements.count == 23, "every catch-up type must survive the tolerant decoder")
    }

    @Test("an unknown future type is still dropped rather than rejecting the page")
    func unknownTypeStillTolerated() throws {
        let json = Data("""
        {"measurements":[
          {"id":"a","type":"ACTIVITY_STEPS","value":900,"measuredAt":"2026-07-01T08:00:00Z"},
          {"id":"b","type":"SOME_FUTURE_TYPE_2099","value":9,"measuredAt":"2026-07-01T08:00:00Z"}
        ]}
        """.utf8)
        let resp = try Self.decoder().decode(MeasurementListWireResponse.self, from: json)
        #expect(resp.measurements.count == 1, "tolerant decode keeps the known row and drops the unknown")
        #expect(resp.measurements.first?.type == .activitySteps)
    }

    @Test("none of the 21 new kinds gains a manual-create wire row")
    func newKindsRemainReadOnly() {
        // Build 1 pruned the MeasureSheet picker down to the kinds that can
        // actually serialize. These 21 are read-only ingest, so they must keep
        // producing NO wire row — otherwise the picker could quietly regain an
        // entry that reports success without saving.
        let readOnly: [MetricKind] = [
            .phq9Score, .gad7Score, .who5Score, .sciScore,
            .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
            .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
            .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent
        ]
        #expect(readOnly.count == 21)
        for kind in readOnly {
            let measurement = HealthLog.Measurement(
                id: "m-\(kind.rawValue)",
                kind: kind,
                recordedAt: Date(timeIntervalSince1970: 0),
                value: .scalar(1),
                note: nil,
                source: .manual
            )
            #expect(measurement.toCreateDTOs().isEmpty, "a read-only kind must not emit a wire row")
        }
    }

    @Test("every new kind carries real display metadata rather than the fallback descriptor")
    func newKindsHaveDescriptors() {
        let newKinds: [MetricKind] = [
            .phq9Score, .gad7Score, .who5Score, .sciScore,
            .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
            .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
            .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent
        ]
        for kind in newKinds {
            let descriptor = kind.descriptor
            #expect(descriptor.kind == kind)
            #expect(descriptor.sfSymbol != "questionmark.circle", "kind fell through to the fallback descriptor")
            #expect(!String(localized: descriptor.title).isEmpty, "kind has an empty title")
            #expect(kind.availabilitySummaryKey != nil, "kind needs a server type key for the kind-scoped read")
        }
    }
}
