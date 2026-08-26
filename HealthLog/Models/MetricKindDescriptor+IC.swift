import Foundation

/// v0.13.1 IC — v1.10.0 web-parity additive HealthKit signal descriptors.
///
/// Split out of `MetricKindDescriptor.swift` to keep that file under the
/// 1000-line `file_length` budget. `MetricKindDescriptor.catalog` concatenates
/// this array onto its main `entries` list, so these seven kinds are part of the
/// SAME single catalog dict (exhaustiveness is still locked by
/// `MetricKindDescriptorRegistryTests`).
///
/// Read/display-only parity: all seven arrive from Apple Health via server
/// ingest (no manual-entry surface, not collected through the iOS HK observer
/// registry). Units + favourable direction mirror the server registry
/// (`src/lib/insights/metric-status-registry.ts` + the `measurementTypeEnum`
/// unit map). Monochrome doctrine: every tint is `HLSurface.secondary`, matching
/// the rest of the catalog (chrome stays mono; chart series resolve to the
/// single accent at render time).
extension MetricKindDescriptor {
    static let additiveV1100Descriptors: [MetricKindDescriptor] = [
        .init(
            kind: .falls,
            sfSymbol: "figure.fall",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Falls", comment: "Metric title — fall count"),
            unitLabel: LocalizedStringResource("", comment: "Unit — count (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Detected automatically by Apple Watch",
                comment: "Empty state — falls"
            )
        ),
        .init(
            kind: .sixMinuteWalk,
            sfSymbol: "figure.walk",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Six-minute walk",
                comment: "Metric title — six-minute walk distance"
            ),
            titleCompact: LocalizedStringResource(
                "6-min walk",
                comment: "Compact title — six-minute walk distance"
            ),
            unitLabel: LocalizedStringResource("m", comment: "Unit — meters"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Estimated from your daily walks",
                comment: "Empty state — six-minute walk distance"
            )
        ),
        .init(
            kind: .stairAscentSpeed,
            sfSymbol: "figure.stairs",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Stair ascent speed",
                comment: "Metric title — stair ascent speed"
            ),
            titleCompact: LocalizedStringResource(
                "Stair up",
                comment: "Compact title — stair ascent speed"
            ),
            unitLabel: LocalizedStringResource("m/s", comment: "Unit — meters per second"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal2,
            emptyStateCopy: LocalizedStringResource(
                "Captured while climbing stairs with iPhone",
                comment: "Empty state — stair ascent speed"
            )
        ),
        .init(
            kind: .stairDescentSpeed,
            sfSymbol: "figure.stairs",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Stair descent speed",
                comment: "Metric title — stair descent speed"
            ),
            titleCompact: LocalizedStringResource(
                "Stair down",
                comment: "Compact title — stair descent speed"
            ),
            unitLabel: LocalizedStringResource("m/s", comment: "Unit — meters per second"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal2,
            emptyStateCopy: LocalizedStringResource(
                "Captured while descending stairs with iPhone",
                comment: "Empty state — stair descent speed"
            )
        ),
        .init(
            kind: .breathingDisturbances,
            sfSymbol: "lungs",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Breathing disturbances",
                comment: "Metric title — sleep breathing disturbances"
            ),
            titleCompact: LocalizedStringResource(
                "Breathing",
                comment: "Compact title — sleep breathing disturbances"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — count (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Measured overnight by Apple Watch",
                comment: "Empty state — breathing disturbances"
            )
        ),
        .init(
            kind: .cardioRecovery,
            sfSymbol: "heart.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Cardio recovery",
                comment: "Metric title — cardio recovery"
            ),
            titleCompact: LocalizedStringResource(
                "Recovery",
                comment: "Compact title — cardio recovery"
            ),
            unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Measured after a workout by Apple Watch",
                comment: "Empty state — cardio recovery"
            )
        ),
        .init(
            kind: .wristTemperature,
            sfSymbol: "thermometer.medium",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Wrist temperature",
                comment: "Metric title — wrist temperature"
            ),
            titleCompact: LocalizedStringResource(
                "Wrist temp",
                comment: "Compact title — wrist temperature"
            ),
            unitLabel: LocalizedStringResource("°C", comment: "Unit — degrees Celsius"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Measured overnight by Apple Watch",
                comment: "Empty state — wrist temperature"
            )
        ),
        // v0.14.6 — v1.12.8 WHOOP-native types (read-only display parity).
        .init(
            kind: .averageHeartRate,
            sfSymbol: "heart",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Average heart rate", comment: "Metric title — average heart rate"),
            titleCompact: LocalizedStringResource("Avg HR", comment: "Compact title — average heart rate"),
            unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by WHOOP",
                comment: "Empty state — average heart rate"
            )
        ),
        .init(
            kind: .maxHeartRate,
            sfSymbol: "heart.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Max heart rate", comment: "Metric title — max heart rate"),
            titleCompact: LocalizedStringResource("Max HR", comment: "Compact title — max heart rate"),
            unitLabel: LocalizedStringResource("bpm", comment: "Unit — beats per minute"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by WHOOP",
                comment: "Empty state — max heart rate"
            )
        ),
        .init(
            kind: .sleepDisturbanceCount,
            sfSymbol: "moon.zzz",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep disturbances", comment: "Metric title — sleep disturbance count"),
            titleCompact: LocalizedStringResource("Disturbances", comment: "Compact title — sleep disturbance count"),
            unitLabel: LocalizedStringResource("", comment: "Unit — count (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by WHOOP",
                comment: "Empty state — sleep disturbance count"
            )
        )
    ]

    // MARK: - v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23)

    //
    // Four new server-stored `MeasurementType`s LIVE in v1.17.1, all SOURCE-
    // FIXED + RENDER-ONLY on iOS (no manual entry, no HK write). Monochrome
    // doctrine: every tint is `HLSurface.secondary`. ANS-charge / cardio-load /
    // sleep-score are unitless scores; body-temperature DEVIATION is a SIGNED
    // °C offset from baseline (`.signedDecimal1` format + an explicit
    // "deviation from baseline" secondary hint so it is NEVER mistaken for an
    // absolute body temperature).
    static let sourceFixedV1171Descriptors: [MetricKindDescriptor] = [
        .init(
            kind: .ansCharge,
            sfSymbol: "bolt.heart",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Autonomic charge", comment: "Metric title — ANS charge"),
            titleCompact: LocalizedStringResource("ANS charge", comment: "Compact title — ANS charge"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by Polar",
                comment: "Empty state — ANS charge"
            )
        ),
        .init(
            kind: .cardioLoad,
            sfSymbol: "figure.run",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Cardio load", comment: "Metric title — cardio load"),
            titleCompact: LocalizedStringResource("Cardio load", comment: "Compact title — cardio load"),
            unitLabel: LocalizedStringResource("", comment: "Unit — load score (no label)"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by Polar",
                comment: "Empty state — cardio load"
            )
        ),
        .init(
            kind: .sleepScore,
            sfSymbol: "moon.stars.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep score", comment: "Metric title — sleep score"),
            titleCompact: LocalizedStringResource("Sleep score", comment: "Compact title — sleep score"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by your sleep tracker",
                comment: "Empty state — sleep score"
            )
        ),
        .init(
            kind: .bodyTemperatureDeviation,
            sfSymbol: "thermometer.variable",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Body temperature deviation",
                comment: "Metric title — body temperature deviation (signed offset from baseline)"
            ),
            titleCompact: LocalizedStringResource(
                "Temp deviation",
                comment: "Compact title — body temperature deviation"
            ),
            unitLabel: LocalizedStringResource("°C", comment: "Unit — degrees Celsius"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            // W-B189 (#23) — SIGNED format: the value is an offset from
            // baseline, rendered with an explicit +/− sign, NEVER as an
            // absolute reading.
            formatStyle: .signedDecimal1,
            emptyStateCopy: LocalizedStringResource(
                "Recorded by Oura",
                comment: "Empty state — body temperature deviation"
            ),
            // Make the "offset from baseline" semantics explicit so the value
            // is never read as an absolute body temperature.
            secondaryHint: LocalizedStringResource(
                "Deviation from baseline",
                comment: "Secondary hint — body temperature deviation from baseline"
            )
        )
    ]

    /// W-B189 (#23) — formats a SIGNED 1-decimal value with an explicit sign,
    /// for the `.signedDecimal1` style (`bodyTemperatureDeviation`: Oura's
    /// signed °C offset from baseline). Positives get a `+`, negatives the
    /// Unicode MINUS SIGN (U+2212, typographic minus), zero a plain `0.0`. The
    /// magnitude is rounded to 1 fraction digit FIRST so a value like `-0.04`
    /// reads as `0.0` (not `−0.0`). Single source of truth for the three
    /// `FormatStyle` switch sites (descriptor / `MetricDisplay` / `HLDashboardTile`).
    static func formatSignedDecimal1(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(1)))
        if rounded > 0 { return "+\(magnitude)" }
        if rounded < 0 { return "\u{2212}\(magnitude)" } // U+2212 MINUS SIGN
        return magnitude
    }
}
