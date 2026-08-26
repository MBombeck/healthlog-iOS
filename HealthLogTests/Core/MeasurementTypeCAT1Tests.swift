import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Wire-Lock für die zwei `v1.4.30`-additiven `MeasurementType`-Werte aus
/// der CAT-1-Phase (Categorisation overlay consumption).
///
/// Server-Enum-Source-of-Truth: `prisma/schema.prisma` →
/// `enum MeasurementType { … WALKING_STEADINESS  AUDIO_EXPOSURE_EVENT }`.
/// Per R10 (CROSS-COORDINATION-AUDIT §b.5) sind beide **per-sample**, also
/// nicht im HK-STATS-cumulative-Scope.
///
/// Die Tests pinnen:
///   1. Raw-Wire-String matcht exakt SCREAMING_SNAKE_CASE-Form.
///   2. Decoder round-trippt zurück auf die Swift-camelCase-Cases.
///   3. `CaseIterable.allCases` enthält beide neuen Werte (Drift-Sentinel).
///   4. Die zwei neuen Werte sind in den Categorisation-Buckets `activity`
///      (`walkingSteadiness`) bzw `hearing` (`audioExposureEvent`).
@Suite("MeasurementType — v1.4.30 CAT-1 additive enum cases")
struct MeasurementTypeCAT1Tests {
    @Test("walkingSteadiness encodes as WALKING_STEADINESS")
    func walkingSteadinessEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementType.walkingSteadiness)
        #expect(String(data: data, encoding: .utf8) == "\"WALKING_STEADINESS\"")
    }

    @Test("audioExposureEvent encodes as AUDIO_EXPOSURE_EVENT")
    func audioExposureEventEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementType.audioExposureEvent)
        #expect(String(data: data, encoding: .utf8) == "\"AUDIO_EXPOSURE_EVENT\"")
    }

    @Test("WALKING_STEADINESS wire-form round-trips")
    func walkingSteadinessRoundTrip() throws {
        let data = Data("\"WALKING_STEADINESS\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: data)
        #expect(decoded == .walkingSteadiness)
    }

    @Test("AUDIO_EXPOSURE_EVENT wire-form round-trips")
    func audioExposureEventRoundTrip() throws {
        let data = Data("\"AUDIO_EXPOSURE_EVENT\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: data)
        #expect(decoded == .audioExposureEvent)
    }

    @Test("All twelve cases survive round-trip", arguments: ServerMeasurementType.allCases)
    func allCasesRoundTrip(type: ServerMeasurementType) throws {
        let encoded = try JSONEncoder().encode(type)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: encoded)
        #expect(decoded == type)
    }

    @Test("CaseIterable surface contains the two CAT-1 additions plus F2 additions")
    func allCasesContainsAdditions() {
        let all = Set(ServerMeasurementType.allCases.map(\.rawValue))
        #expect(all.contains("WALKING_STEADINESS"))
        #expect(all.contains("AUDIO_EXPOSURE_EVENT"))
        // v0.5.2 F2 — three new server-backed types
        #expect(all.contains("RESTING_HEART_RATE"))
        #expect(all.contains("HEART_RATE_VARIABILITY"))
        #expect(all.contains("VO2_MAX"))
        // v0.8.3 W-D — four render-backlog activity aggregates
        #expect(all.contains("ACTIVE_ENERGY_BURNED"))
        #expect(all.contains("FLIGHTS_CLIMBED"))
        #expect(all.contains("WALKING_RUNNING_DISTANCE"))
        #expect(all.contains("TIME_IN_DAYLIGHT"))
        // v0.8.4 W-WALK — two gait aggregates, server-persisted since v1.6.0
        #expect(all.contains("WALKING_SPEED"))
        #expect(all.contains("WALKING_STEP_LENGTH"))
        // v0.11 W21 — eight web-parity body-composition + cardio additions.
        #expect(all.contains("FAT_FREE_MASS"))
        #expect(all.contains("LEAN_BODY_MASS"))
        #expect(all.contains("MUSCLE_MASS"))
        #expect(all.contains("SKIN_TEMPERATURE"))
        #expect(all.contains("PULSE_WAVE_VELOCITY"))
        #expect(all.contains("VASCULAR_AGE"))
        #expect(all.contains("VISCERAL_FAT"))
        #expect(all.contains("WALKING_HEART_RATE_AVERAGE"))
        // v0.11 reconcile (F3) — 9th type Withings FAT_MASS.
        #expect(all.contains("FAT_MASS"))
        // v0.13.1 IC — seven v1.10.0 additive HealthKit signals.
        #expect(all.contains("CARDIO_RECOVERY"))
        #expect(all.contains("WRIST_TEMPERATURE"))
        #expect(all.contains("FALL_COUNT"))
        #expect(all.contains("SIX_MINUTE_WALK_DISTANCE"))
        #expect(all.contains("STAIR_ASCENT_SPEED"))
        #expect(all.contains("STAIR_DESCENT_SPEED"))
        #expect(all.contains("BREATHING_DISTURBANCES"))
        // v0.11 marathon — sleep + 5 sibling read-types the list decoder
        // previously dropped (operator: "Bei Schlaf werden keine Messwerte
        // angezeigt"). Server has persisted all six for a while; iOS just
        // lacked the wire case.
        #expect(all.contains("SLEEP_DURATION"))
        #expect(all.contains("RESPIRATORY_RATE"))
        #expect(all.contains("AUDIO_EXPOSURE_ENV"))
        #expect(all.contains("AUDIO_EXPOSURE_HEADPHONE"))
        #expect(all.contains("WALKING_ASYMMETRY"))
        #expect(all.contains("WALKING_DOUBLE_SUPPORT"))
        // v0.14.6 — three v1.12.8 WHOOP-native read-only aggregates.
        #expect(all.contains("AVERAGE_HEART_RATE"))
        #expect(all.contains("MAX_HEART_RATE"))
        #expect(all.contains("SLEEP_DISTURBANCE_COUNT"))
        // v0.14.1 W-B189 — four v1.17.1 source-fixed render-only signals (#23).
        #expect(all.contains("ANS_CHARGE"))
        #expect(all.contains("CARDIO_LOAD"))
        #expect(all.contains("SLEEP_SCORE"))
        #expect(all.contains("BODY_TEMPERATURE_DEVIATION"))
        // v0158 — four v1.25 clinical measurement types.
        #expect(all.contains("PAIN_NRS"))
        #expect(all.contains("GRIP_STRENGTH"))
        #expect(all.contains("WAIST_CIRCUMFERENCE"))
        #expect(all.contains("WAIST_TO_HEIGHT"))
        // 12 base + 9 (F2/W-D/W-WALK groups above) + 9 (W21 + FAT_MASS)
        // + 7 (IC v1.10.0) + 6 (v0.11 sleep + siblings) + 3 (v0.14.6 WHOOP)
        // + 4 (v0.14.1 W-B189 v1.17.1 source-fixed) + 4 (v0158 v1.25 clinical)
        // + 23 (Build 3 / 3.3 — der Decoder-Nachzug: ACTIVITY_STEPS, die vier
        //   Screener-Scores, die WHOOP/Oura-Score-Klassen und die kategorialen
        //   Herz-/Atem-Events; verifiziert als Mengendifferenz gegen das
        //   77-gliedrige Server-Enum) = 77.
        #expect(all.count == 77)
    }
}
