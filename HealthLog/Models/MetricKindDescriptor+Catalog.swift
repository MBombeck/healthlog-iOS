// swiftlint:disable file_length — single indivisible `catalog` data-table literal
// (one entry per `MetricKind` case), split out of MetricKindDescriptor.swift
// (pure move, W-FILELEN). The array cannot be sub-split without changing the decl.
// Registry catalog split out of MetricKindDescriptor.swift (pure move, W-FILELEN).
import Foundation
import SwiftUI

// MARK: - Registry

public extension MetricKindDescriptor {
    /// Static catalogue — every `MetricKind` case **must** appear here.
    /// Exhaustiveness is locked in by `MetricKindDescriptorRegistryTests`.
    static let catalog: [MetricKind: MetricKindDescriptor] = {
        let entries: [MetricKindDescriptor] = [
            .init(
                kind: .weight,
                sfSymbol: "scalemass",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Weight", comment: "Metric title — weight"),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Log your first weigh-in",
                    comment: "Empty state — weight"
                )
            ),
            .init(
                kind: .bloodPressure,
                sfSymbol: "waveform.path.ecg",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Blood pressure", comment: "Metric title — blood pressure"),
                unitLabel: LocalizedStringResource("mmHg", comment: "Unit — millimeters of mercury"),
                trendPolarity: .lowerIsBetter,
                renderHint: .dualValue,
                supportsDrillDown: true,
                formatStyle: .bloodPressureCompound,
                emptyStateCopy: LocalizedStringResource(
                    "Log a blood pressure reading",
                    comment: "Empty state — blood pressure"
                )
            ),
            .init(
                kind: .pulse,
                sfSymbol: "heart.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Pulse", comment: "Metric title — pulse"),
                unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Synced from Apple Watch",
                    comment: "Empty state — pulse"
                )
            ),
            .init(
                kind: .glucose,
                sfSymbol: "drop.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Blood glucose", comment: "Metric title — glucose"),
                unitLabel: LocalizedStringResource("mg/dL", comment: "Unit — milligrams per deciliter"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Log your blood glucose",
                    comment: "Empty state — glucose"
                )
            ),
            .init(
                kind: .bodyFat,
                sfSymbol: "figure.stand",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Body fat", comment: "Metric title — body fat"),
                unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Log your body fat",
                    comment: "Empty state — body fat"
                )
            ),
            .init(
                kind: .bodyTemperature,
                sfSymbol: "thermometer.medium",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Body temperature", comment: "Metric title — body temperature"),
                unitLabel: LocalizedStringResource("°C", comment: "Unit — degrees Celsius"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Measured as needed",
                    comment: "Empty state — body temperature"
                )
            ),
            .init(
                kind: .spo2,
                sfSymbol: "lungs.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Oxygen saturation", comment: "Metric title — oxygen saturation"),
                titleCompact: LocalizedStringResource("SpO\u{2082}", comment: "Compact title — SpO2"),
                unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured via Apple Watch",
                    comment: "Empty state — SpO2"
                )
            ),
            .init(
                kind: .bodyWater,
                sfSymbol: "humidity.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Total body water",
                    comment: "Metric title — total body water"
                ),
                titleCompact: LocalizedStringResource("Body water", comment: "Compact title — body water"),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — total body water"
                )
            ),
            .init(
                kind: .boneMass,
                sfSymbol: "figure",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Bone mass", comment: "Metric title — bone mass"),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — bone mass"
                )
            ),
            .init(
                kind: .sleep,
                sfSymbol: "moon.zzz.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Sleep", comment: "Metric title — sleep"),
                unitLabel: LocalizedStringResource("h", comment: "Unit — hours"),
                trendPolarity: .neutral,
                renderHint: .sleepDuration,
                supportsDrillDown: true,
                formatStyle: .durationHM,
                emptyStateCopy: LocalizedStringResource(
                    "Wear your Apple Watch at night",
                    comment: "Empty state — sleep"
                ),
                secondaryHint: LocalizedStringResource("Last night", comment: "Sleep secondary — last night")
            ),
            .init(
                kind: .steps,
                sfSymbol: "figure.walk",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Steps", comment: "Metric title — steps"),
                unitLabel: LocalizedStringResource("Steps", comment: "Unit — steps"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .groupedInteger,
                emptyStateCopy: LocalizedStringResource(
                    "Enable Steps in the Health app",
                    comment: "Empty state — steps"
                )
            ),

            // MARK: - v0.5.2 F2 HK-completeness additions

            .init(
                kind: .restingHeartRate,
                sfSymbol: "heart.text.square.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Resting heart rate", comment: "Metric title — resting heart rate"),
                unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured via Apple Watch",
                    comment: "Empty state — resting heart rate"
                )
            ),
            .init(
                kind: .hrv,
                sfSymbol: "waveform.path.ecg.rectangle",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("HRV", comment: "Metric title — heart rate variability"),
                unitLabel: LocalizedStringResource("ms", comment: "Unit — milliseconds"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured via Apple Watch",
                    comment: "Empty state — HRV"
                )
            ),
            .init(
                kind: .vo2Max,
                sfSymbol: "lungs.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Cardio fitness", comment: "Metric title — VO2 max"),
                titleCompact: LocalizedStringResource("VO₂ max", comment: "Compact title — VO2 max"),
                unitLabel: LocalizedStringResource("mL/kg·min", comment: "Unit — VO2 max"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Cardio fitness needs an outdoor workout",
                    comment: "Empty state — VO2 max"
                )
            ),
            .init(
                kind: .walkingSpeed,
                sfSymbol: "figure.walk.motion",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking speed",
                    comment: "Metric title — walking speed"
                ),
                unitLabel: LocalizedStringResource("m/s", comment: "Unit — meters per second"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal2,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while walking with iPhone",
                    comment: "Empty state — walking speed"
                )
            ),
            .init(
                kind: .walkingAsymmetry,
                sfSymbol: "figure.walk.diamond",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking asymmetry",
                    comment: "Metric title — walking asymmetry"
                ),
                titleCompact: LocalizedStringResource(
                    "Asymmetry",
                    comment: "Compact title — walking asymmetry"
                ),
                unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while walking with iPhone",
                    comment: "Empty state — walking asymmetry"
                )
            ),
            .init(
                kind: .walkingStepLength,
                sfSymbol: "ruler",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Step length",
                    comment: "Metric title — walking step length"
                ),
                unitLabel: LocalizedStringResource("m", comment: "Unit — meters"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal2,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while walking with iPhone",
                    comment: "Empty state — walking step length"
                )
            ),
            .init(
                kind: .bmi,
                sfSymbol: "figure.arms.open",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("BMI", comment: "Metric title — body mass index"),
                unitLabel: LocalizedStringResource("kg/m²", comment: "Unit — body mass index"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Derived from weight and height",
                    comment: "Empty state — BMI"
                )
            ),

            // MARK: - v0.7.0 HK adopt-and-stream additions

            .init(
                kind: .walkingDoubleSupport,
                sfSymbol: "figure.walk.motion",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking double support",
                    comment: "Metric title — walking double support percentage"
                ),
                titleCompact: LocalizedStringResource(
                    "Double support",
                    comment: "Compact title — walking double support"
                ),
                unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while walking with iPhone",
                    comment: "Empty state — walking double support"
                )
            ),

            // W28d — walking steadiness (Apple fall-risk mobility classifier).
            .init(
                kind: .walkingSteadiness,
                sfSymbol: "figure.walk.motion",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking steadiness",
                    comment: "Metric title — walking steadiness"
                ),
                titleCompact: LocalizedStringResource(
                    "Steadiness",
                    comment: "Compact title — walking steadiness"
                ),
                unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while walking with iPhone",
                    comment: "Empty state — walking steadiness"
                )
            ),

            .init(
                kind: .respiratoryRate,
                sfSymbol: "lungs.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Respiratory rate",
                    comment: "Metric title — respiratory rate"
                ),
                titleCompact: LocalizedStringResource(
                    "Breathing",
                    comment: "Compact title — respiratory rate"
                ),
                unitLabel: LocalizedStringResource("br/min", comment: "Unit — breaths per minute"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured by Apple Watch during sleep",
                    comment: "Empty state — respiratory rate"
                )
            ),

            .init(
                kind: .audioExposureEnvironment,
                sfSymbol: "speaker.wave.2.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Environmental sound level",
                    comment: "Metric title — environmental audio exposure"
                ),
                titleCompact: LocalizedStringResource(
                    "Environment",
                    comment: "Compact title — environmental audio exposure"
                ),
                unitLabel: LocalizedStringResource("dBA", comment: "Unit — A-weighted decibels"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured via Apple Watch",
                    comment: "Empty state — environmental audio exposure"
                )
            ),

            .init(
                kind: .audioExposureHeadphone,
                sfSymbol: "headphones",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Headphone level",
                    comment: "Metric title — headphone audio exposure"
                ),
                titleCompact: LocalizedStringResource(
                    "Headphones",
                    comment: "Compact title — headphone audio exposure"
                ),
                unitLabel: LocalizedStringResource("dBA", comment: "Unit — A-weighted decibels"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured while listening with headphones",
                    comment: "Empty state — headphone audio exposure"
                )
            ),

            // MARK: - v0.8.3 W-D — render-backlog activity aggregates

            .init(
                kind: .activeEnergy,
                sfSymbol: "flame.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Active energy",
                    comment: "Metric title — active energy burned"
                ),
                titleCompact: LocalizedStringResource(
                    "Energy",
                    comment: "Compact title — active energy burned"
                ),
                unitLabel: LocalizedStringResource("kcal", comment: "Unit — kilocalories"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .groupedInteger,
                emptyStateCopy: LocalizedStringResource(
                    "Move to fill your activity ring",
                    comment: "Empty state — active energy burned"
                )
            ),
            .init(
                kind: .flightsClimbed,
                sfSymbol: "figure.stairs",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Flights climbed",
                    comment: "Metric title — flights climbed"
                ),
                titleCompact: LocalizedStringResource(
                    "Flights",
                    comment: "Compact title — flights climbed"
                ),
                unitLabel: LocalizedStringResource("Flights", comment: "Unit — flights climbed"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Take the stairs to record flights",
                    comment: "Empty state — flights climbed"
                )
            ),
            .init(
                kind: .distanceWalkingRunning,
                sfSymbol: "figure.walk",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking + running distance",
                    comment: "Metric title — walking and running distance"
                ),
                titleCompact: LocalizedStringResource(
                    "Distance",
                    comment: "Compact title — walking and running distance"
                ),
                unitLabel: LocalizedStringResource("m", comment: "Unit — meters"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .groupedInteger,
                emptyStateCopy: LocalizedStringResource(
                    "Walk or run to record distance",
                    comment: "Empty state — walking and running distance"
                )
            ),
            .init(
                kind: .timeInDaylight,
                sfSymbol: "sun.max.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Time in daylight",
                    comment: "Metric title — time in daylight"
                ),
                titleCompact: LocalizedStringResource(
                    "Daylight",
                    comment: "Compact title — time in daylight"
                ),
                unitLabel: LocalizedStringResource("min", comment: "Unit — minutes"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Spend time outdoors in daylight",
                    comment: "Empty state — time in daylight"
                )
            ),

            // MARK: - v0.11 W21 — web-parity body-composition + cardio additions

            //
            // Server/Withings-sourced read-only kinds (see `MetricKind` v0.11
            // W21 block). All use the monochrome `HLSurface.secondary` tint and
            // the existing SF-Symbol language. Empty-state copy nods to the
            // Withings smart-scale / Body-Scan as the source, matching the web.

            .init(
                kind: .fatFreeMass,
                sfSymbol: "figure",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Fat-free mass",
                    comment: "Metric title — fat-free mass"
                ),
                titleCompact: LocalizedStringResource(
                    "Fat-free",
                    comment: "Compact title — fat-free mass"
                ),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — fat-free mass"
                )
            ),
            .init(
                kind: .leanBodyMass,
                sfSymbol: "figure.arms.open",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Lean body mass",
                    comment: "Metric title — lean body mass"
                ),
                titleCompact: LocalizedStringResource(
                    "Lean mass",
                    comment: "Compact title — lean body mass"
                ),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — lean body mass"
                )
            ),
            .init(
                kind: .muscleMass,
                sfSymbol: "figure.strengthtraining.functional",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Muscle mass",
                    comment: "Metric title — muscle mass"
                ),
                titleCompact: LocalizedStringResource(
                    "Muscle",
                    comment: "Compact title — muscle mass"
                ),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — muscle mass"
                )
            ),
            .init(
                kind: .skinTemperature,
                sfSymbol: "thermometer.medium",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Skin temperature",
                    comment: "Metric title — skin temperature"
                ),
                titleCompact: LocalizedStringResource(
                    "Skin temp",
                    comment: "Compact title — skin temperature"
                ),
                unitLabel: LocalizedStringResource("°C", comment: "Unit — degrees Celsius"),
                trendPolarity: .neutral,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Captured by a wrist-temperature sensor",
                    comment: "Empty state — skin temperature"
                )
            ),
            .init(
                kind: .pulseWaveVelocity,
                sfSymbol: "waveform.path",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Pulse-wave velocity",
                    comment: "Metric title — pulse-wave velocity"
                ),
                titleCompact: LocalizedStringResource(
                    "PWV",
                    comment: "Compact title — pulse-wave velocity"
                ),
                unitLabel: LocalizedStringResource("m/s", comment: "Unit — meters per second"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Measured by your smart scale",
                    comment: "Empty state — pulse-wave velocity"
                )
            ),
            .init(
                kind: .vascularAge,
                sfSymbol: "heart.text.square",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Vascular age",
                    comment: "Metric title — vascular age"
                ),
                unitLabel: LocalizedStringResource("years", comment: "Unit — years"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Measured by your smart scale",
                    comment: "Empty state — vascular age"
                )
            ),
            .init(
                kind: .visceralFat,
                sfSymbol: "figure.stand",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Visceral fat",
                    comment: "Metric title — visceral fat"
                ),
                titleCompact: LocalizedStringResource(
                    "Visceral",
                    comment: "Compact title — visceral fat"
                ),
                unitLabel: LocalizedStringResource("rating", comment: "Unit — visceral-fat rating"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Measured by your smart scale",
                    comment: "Empty state — visceral fat"
                )
            ),
            .init(
                kind: .walkingHeartRate,
                sfSymbol: "heart.fill",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Walking heart rate",
                    comment: "Metric title — walking heart-rate average"
                ),
                titleCompact: LocalizedStringResource(
                    "Walking HR",
                    comment: "Compact title — walking heart-rate average"
                ),
                unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .integer,
                emptyStateCopy: LocalizedStringResource(
                    "Captured via Apple Watch",
                    comment: "Empty state — walking heart rate"
                )
            ),
            // v0.11 reconcile (F3) — 9th W21 type: Withings FAT_MASS (kg), the
            // mass form of body-fat (pairs with fat-free mass to total weight).
            .init(
                kind: .fatMass,
                sfSymbol: "scalemass",
                tint: HLSurface.secondary,
                title: LocalizedStringResource(
                    "Fat mass",
                    comment: "Metric title — fat mass"
                ),
                titleCompact: LocalizedStringResource(
                    "Fat mass",
                    comment: "Compact title — fat mass"
                ),
                unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
                trendPolarity: .lowerIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Weigh in with your smart scale",
                    comment: "Empty state — fat mass"
                )
            ),

            // MARK: - Build 7 / item 7.3 — mood dashboard tile

            // Mood is the one dashboard metric that is not a `Measurement` (server
            // derives it from `buildMoodDailySeries`). It renders as a plain scalar
            // score tile; higher is better. Unit is empty (the summary carries its
            // own `unitKey`). No manual-entry / series path — the tile reads the
            // summary snapshot; a tap opens the generic chart-detail which honestly
            // shows the no-series empty state (mood has its own capture flow).
            .init(
                kind: .mood,
                sfSymbol: "face.smiling",
                tint: HLSurface.secondary,
                title: LocalizedStringResource("Mood", comment: "Metric title — mood"),
                unitLabel: LocalizedStringResource("", comment: "Unit — mood (unitless score)"),
                trendPolarity: .higherIsBetter,
                renderHint: .scalar,
                supportsDrillDown: true,
                formatStyle: .decimal1,
                emptyStateCopy: LocalizedStringResource(
                    "Log how you're feeling",
                    comment: "Empty state — mood"
                )
            )
        ]
            // v0.13.1 IC — the v1.10.0 additive descriptors live in
            // `MetricKindDescriptor+IC.swift` (keeps this file under the 1000-line
            // budget). Concatenated here so the catalog stays the single dict.
            + additiveV1100Descriptors
            // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
            + sourceFixedV1171Descriptors
            // v0158 — v1.25 clinical measurement types (pain / grip / waist / WtH).
            + v125ClinicalDescriptors
            // Build 3 / item 3.3 — the 21 kinds added with the decoder catch-up
            // (screener sums, wearable scores, sleep sub-scores, categorical
            // events). See `MetricKindDescriptor+B3Decoder.swift`.
            + b3DecoderDescriptors
        var dict: [MetricKind: MetricKindDescriptor] = [:]
        for entry in entries {
            dict[entry.kind] = entry
        }
        return dict
    }()

    /// Convenience lookup — always returns a descriptor (every enum case is
    /// represented in `catalog`; the test suite locks in exhaustiveness).
    /// On the (impossible) miss we fall through to a neutral scalar shape so
    /// callers don't have to deal with optionality.
    static func descriptor(for kind: MetricKind) -> MetricKindDescriptor {
        if let hit = catalog[kind] { return hit }
        // Defensive fallback — should never fire, exhaustiveness test guards it.
        return MetricKindDescriptor(
            kind: kind,
            sfSymbol: "questionmark.circle",
            tint: HLText.tertiary,
            title: LocalizedStringResource("Unknown metric", comment: "Fallback title"),
            unitLabel: LocalizedStringResource("", comment: "Empty unit"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: false,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource("No data yet", comment: "Fallback empty state")
        )
    }
}
