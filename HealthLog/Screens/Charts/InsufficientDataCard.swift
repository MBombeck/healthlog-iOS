import SwiftUI

// W3b C1 — extracted from `ChartDetailScreen.swift` so the host file stays
// under the 1000-line SwiftLint ceiling after the fullscreen zoom-morph
// wiring landed. No behaviour change — same Apple-Health humane empty state.

/// Apple-Health-style empty / insufficient-data card.
///
/// Shown in two situations:
/// 1. Series has 0 points — full empty state with CTA.
/// 2. Series has 1 point — "Need more data" insufficient state (one reading
///    is enough to display, but not enough to compute a useful trend).
///
/// Copy varies per metric: vital-signs that integrate with HealthKit get a
/// "Verbinde Apple Health"-shaped CTA; manually-logged metrics get an
/// "Erfasse jetzt"-shaped CTA. Both surfaces are CTA-rich (Apple Health does
/// this — they never leave the user staring at an empty rectangle).
struct InsufficientDataCard: View {
    let kind: MetricKind
    /// `true` if the series has exactly one point — communicates as "we need
    /// more data" rather than "no data at all".
    let hasOnePoint: Bool

    var body: some View {
        HLCard {
            VStack(spacing: HLSpace.md) {
                Image(systemName: iconName)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(
                        size: 36,
                        weight: .regular
                    )) // Empty-state hero medallion glyph — intentionally off the HLIconSize scale (>hero/28pt), purely decorative (no text
                    // content scales with it).
                    .foregroundStyle(HLText.tertiary)
                    .padding(.top, HLSpace.sm)
                VStack(spacing: HLSpace.xs) {
                    Text(title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(subtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, HLSpace.md)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(subtitle)"))
    }

    private var iconName: String {
        if hasOnePoint {
            return "chart.line.flattrend.xyaxis"
        }
        switch kind {
        case .steps, .sleep, .pulse, .restingHeartRate, .hrv: return "heart.text.square"
        case .weight, .bodyFat, .bodyWater, .boneMass, .bmi: return "scalemass"
        case .bloodPressure: return "waveform.path.ecg"
        case .glucose: return "drop"
        case .bodyTemperature: return "thermometer.medium"
        case .spo2, .vo2Max, .respiratoryRate: return "lungs"
        case .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
             .walkingSteadiness: return "figure.walk.motion"
        case .audioExposureEnvironment, .audioExposureHeadphone: return "ear"
        // v0.8.3 W-D — render-backlog activity aggregates.
        case .activeEnergy: return "flame"
        case .flightsClimbed: return "figure.stairs"
        case .distanceWalkingRunning: return "figure.walk"
        case .timeInDaylight: return "sun.max"
        // v0.11 W21 — web-parity body-composition + cardio additions.
        case .fatFreeMass, .leanBodyMass, .muscleMass, .visceralFat, .fatMass: return "scalemass"
        case .skinTemperature: return "thermometer.medium"
        case .pulseWaveVelocity: return "waveform.path"
        case .vascularAge, .walkingHeartRate: return "heart.text.square"
        // v0.13.1 IC — v1.10.0 additive signals.
        case .falls: return "figure.fall"
        case .sixMinuteWalk: return "figure.walk"
        case .stairAscentSpeed, .stairDescentSpeed: return "figure.stairs"
        case .breathingDisturbances: return "lungs"
        case .cardioRecovery: return "heart.text.square"
        case .wristTemperature: return "thermometer.medium"
        // v0.14.6 — v1.12.8 WHOOP-native types.
        case .averageHeartRate, .maxHeartRate: return "heart.text.square"
        case .sleepDisturbanceCount: return "moon.zzz"
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
        case .ansCharge: return "bolt.heart"
        case .cardioLoad: return "figure.run"
        case .sleepScore: return "moon.stars.fill"
        case .bodyTemperatureDeviation: return "thermometer.variable"
        // v0158 — v1.25 clinical measurement types.
        case .painNRS: return "bandage.fill"
        case .gripStrength: return "hand.raised.fill"
        case .waistCircumference: return "ruler.fill"
        case .waistToHeight: return "divide"
        // Build 3 / item 3.3 — the 21 decoder catch-up types.
        case .phq9Score, .gad7Score: return "list.clipboard"
        case .who5Score: return "face.smiling"
        case .sciScore: return "bed.double"
        case .recoveryScore: return "arrow.clockwise.heart"
        case .stressScore: return "waveform.path.ecg"
        case .strainScore, .dayStrain, .workoutStrain: return "flame"
        case .hrvRMSSD: return "waveform.path"
        case .sleepPerformance, .sleepEfficiency, .sleepConsistency: return "moon.zzz"
        case .sleepNeed: return "hourglass"
        case .energyExpenditureKJ: return "bolt"
        case .resilience: return "shield.lefthalf.filled"
        case .irregularRhythmNotification: return "waveform.path.ecg.rectangle"
        case .highHeartRateEvent: return "arrow.up.heart"
        case .lowHeartRateEvent: return "arrow.down.heart"
        case .walkingSteadinessEvent: return "figure.walk.motion"
        case .breathingDisturbanceEvent: return "lungs"
        // Build 7 / item 7.3 — mood.
        case .mood: return "face.smiling"
        }
    }

    private var title: String {
        if hasOnePoint {
            return String(localized: "Not enough data yet")
        }
        return String(localized: "No data yet")
    }

    private var subtitle: String {
        let metric = kind.displayName
        if hasOnePoint {
            return String(localized: "Log another \(metric) measurement to see a trend.")
        }
        switch kind {
        case .steps, .sleep, .pulse, .bodyTemperature, .spo2, .restingHeartRate, .hrv, .vo2Max,
             .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
             .walkingSteadiness,
             .respiratoryRate, .audioExposureEnvironment, .audioExposureHeadphone,
             // v0.8.3 W-D — render-backlog activity aggregates arrive from Apple Health.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — walking-HR + skin temp arrive from Apple Health.
             .skinTemperature, .walkingHeartRate,
             // v0.13.1 IC — v1.10.0 additive signals all arrive from Apple Health.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature:
            return String(localized: "Connect Apple Health so \(metric) data arrives automatically.")
        case .weight, .bodyFat, .bodyWater, .boneMass, .bmi:
            return String(localized: "Log a \(metric) measurement now — or connect Apple Health.")
        case .bloodPressure, .glucose,
             // v0.11 W21 — Withings smart-scale body-composition + arterial metrics.
             .fatFreeMass, .leanBodyMass, .muscleMass, .pulseWaveVelocity,
             .vascularAge, .visceralFat, .fatMass,
             // v0.14.6 — v1.12.8 WHOOP-native types arrive from the connected
             // WHOOP device.
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23) arrive from a
             // connected Polar / Oura device.
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 manual clinical signals (pain / grip / waist) + the
             // render-only waist-to-height ratio: a manual log is the primary
             // path (none stream from Apple Health on iOS today).
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types. All arrive
             // from a connected device or are server-computed; none of them has
             // a manual-log path, so "connect your device" is the honest CTA.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood is logged via its own capture flow, so
             // "log a measurement" is the honest CTA here (this card rarely shows
             // for mood, which the summary only surfaces once it has entries).
             .mood:
            return String(localized: "Log a \(metric) measurement now — or connect your device.")
        }
    }
}
