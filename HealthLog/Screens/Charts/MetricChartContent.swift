import Charts
import SwiftUI

/// Per-`MetricKind` chart-mark builders for the chart detail screen.
///
/// **Why a closed switch?** Each metric needs a slightly different visual
/// vocabulary (BP = dual line + clinical thresholds; weight = line + baseline
/// rule; glucose = line over hypo/hyper threshold rules; etc). Using a single
/// `@ChartContentBuilder` switch on `MetricKind` lets the compiler enforce
/// exhaustiveness when a new kind lands — no silent rendering gaps.
///
/// **Theme-2.0 (T2-3, 2026-05-16) — Tonal-Mono recolor:**
/// every primary LineMark defaults to `HLChartTints.series` (the single
/// Dracula-Purple accent). BP's secondary (diastolic) line is the only
/// per-metric variant, and it routes through `HLChartTints.seriesMid`
/// (same hue, 70% opacity) so the dual-line visual stays parseable without
/// introducing a second hue. Per-metric routing (`HLColor.metric*` defaults,
/// the pink body-temp default, the cyan SpO2 default, the green steps line)
/// is gone — the dashboard reads as a single calm material across every
/// metric.
///
/// **Threshold overlays — dashed RuleMark only:**
/// solid `RectangleMark` traffic-light bands (BP, pulse, glucose) are gone.
/// Each clinical threshold renders as a dashed `RuleMark` at the band
/// boundary using `HLChartTints.thresholdHigh` (red — upper bound, "out of
/// safe range") or `HLChartTints.thresholdLow` (green — lower bound, "out
/// of safe range"). Dash pattern + stroke width come from `HLChartGrid`.
/// No solid fills anywhere; the dashed stroke + axis context communicate
/// the clinical semantic without dominating the foreground line.
enum MetricChartContent {
    /// Builds chart marks tailored to `kind`. Designed to be dropped inside
    /// a `Chart { … }` body alongside other marks (selection-rule overlays etc.).
    ///
    /// **C-10 (2026-05-16) emphasis-tint plumbing:** an optional override
    /// for the *primary* LineMark stroke color. When non-nil, the single
    /// Tonal-Mono accent (`HLChartTints.series`) is replaced by the
    /// caller-supplied emphasis color — sourced from
    /// `SettingsStore.preferredTint` in the chart-detail screen.
    ///
    /// **C-2 (2026-05-16) AreaMark removal:** per R2 visual-design-spec §C
    /// the gradient area-fill under every series line was dropped. Webview
    /// + Apple Health both render line-only; the area-fill cluttered the
    /// lower y-range without communicating anything additional.
    ///
    /// **T2-3 (2026-05-16) single-accent collapse:** per Theme-2.0 spec the
    /// per-metric tints collapse onto `HLChartTints.series`. BP's secondary
    /// (diastolic) line is the one exception — it uses `HLChartTints.seriesMid`
    /// (single accent at 70% opacity) so the dual-line visual stays parseable.
    /// All clinical threshold overlays are dashed `RuleMark`s using
    /// `HLChartTints.thresholdHigh` / `.thresholdLow` with `HLChartGrid`
    /// stroke style. When `emphasisTint == nil` the primary line resolves to
    /// `HLChartTints.series`.
    /// **v0.14.1 §1 (Home tile thresholds) — `includeThresholds` plumbing:**
    /// the Dashboard mini-chart (`HLTileMetricChart`) wants ONLY the trend /
    /// series line — no clinical threshold rules, no personal-baseline rule.
    /// The operator found the red/grey target/ideal lines (BP 140/60, weight
    /// baseline, …) noisy at tile scale. This flag defaults to `true` so the
    /// Insights detail charts (the only other caller) keep their thresholds
    /// unchanged; the tile path passes `false` to suppress every
    /// `ThresholdRule` + the weight baseline `RuleMark`.
    /// **v0.14.3 §A1/§A2 (FW-HOME) — `showsPoints` + `seriesLineWidth`:**
    /// the Home-tile chart variant wants ONE calm, uniform line across every
    /// tile, matching the medication-compliance primitive's quiet graphite.
    /// Two tile-only knobs (same opt-in plumbing as `includeThresholds`):
    /// - `showsPoints` (default `true`) — when `false`, the per-measurement
    ///   dot symbols (BP systolic/diastolic `.symbol(.circle)`, the glucose
    ///   `PointMark`s) are dropped so the tile renders the **series line only**
    ///   (the operator found the dots "too intense" on the Home tiles).
    /// - `seriesLineWidth` (default `nil`) — when set, every primary/secondary
    ///   `LineMark` strokes at that fixed width so all tiles share ONE calm
    ///   line weight. `nil` keeps the Charts default (~2pt) for the Insights
    ///   detail charts, which stay byte-identical to before.
    @ChartContentBuilder
    static func marks(
        for kind: MetricKind,
        points: [SeriesPoint],
        emphasisTint: Color? = nil,
        includeThresholds: Bool = true,
        showsPoints: Bool = true,
        seriesLineWidth: CGFloat? = nil
    ) -> some ChartContent {
        switch kind {
        case .bloodPressure:
            BloodPressureMarks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                showsPoints: showsPoints,
                lineWidth: seriesLineWidth
            )
        case .weight:
            WeightMarks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                lineWidth: seriesLineWidth
            )
        case .pulse:
            PulseMarks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                lineWidth: seriesLineWidth
            )
        case .glucose:
            GlucoseMarks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                showsPoints: showsPoints,
                lineWidth: seriesLineWidth
            )
        case .bodyFat:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        case .bodyTemperature:
            BodyTemperatureMarks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                lineWidth: seriesLineWidth
            )
        case .spo2:
            SPO2Marks(
                points: points,
                primaryTint: emphasisTint ?? HLChartTints.series,
                includeThresholds: includeThresholds,
                lineWidth: seriesLineWidth
            )
        case .bodyWater:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        case .boneMass:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        case .sleep:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        case .steps:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        // v0.5.2 F2 — server-backed additions render as single-series scalar
        // lines. RHR + HRV + VO₂ max each carry their own clinical thresholds
        // long-term (e.g. SpO₂-style normal-range bands); for now the
        // minimal-shape SingleSeriesMarks renderer matches the rest of the
        // tonal-mono dashboard. Per-kind threshold overlays can land
        // additively in a follow-up.
        case .restingHeartRate, .hrv, .vo2Max,
             .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
             .walkingSteadiness,
             .respiratoryRate, .audioExposureEnvironment, .audioExposureHeadphone, .bmi,
             // v0.8.3 W-D — render-backlog activity aggregates render as single-series lines.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — web-parity body-composition + cardio additions render
             // as single-series scalar lines (tonal-mono, no per-kind threshold).
             .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — v1.10.0 additive signals render as single-series
             // scalar lines (tonal-mono, no per-kind threshold).
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native types: single-series scalar lines.
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23): single-series
             // scalar lines (the signed body-temperature deviation charts around
             // zero like any scalar series).
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types render as single-series scalar lines
             // (pain NRS 0–10, grip kg, waist cm, waist-to-height ratio).
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types render as
             // single-series scalar lines. The five categorical events plot
             // their constant `1` at the occurrence timestamp, which reads as
             // an event ladder — the timestamps ARE the information.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood renders as a single-series scalar line
             // if a mood series ever reaches this surface (today the tile reads
             // the summary snapshot; there is no mood `/series` endpoint).
             .mood:
            SingleSeriesMarks(points: points, tint: emphasisTint ?? HLChartTints.series, lineWidth: seriesLineWidth)
        }
    }

    // MARK: - Per-metric content

    /// Two `LineMark`s (sys + dia) plus dashed clinical-threshold `RuleMark`s.
    ///
    /// **T2-3 (Theme-2.0):** solid traffic-light `RectangleMark` bands are
    /// gone. The upper systolic threshold (140 mmHg, stage-1 hypertension)
    /// renders as a dashed red `RuleMark` (`HLChartTints.thresholdHigh`);
    /// the lower diastolic threshold (60 mmHg, hypotension floor) renders
    /// as a dashed green `RuleMark` (`HLChartTints.thresholdLow`). The
    /// 130-140 stage-1-borderline band and the 90-130 normal band are no
    /// longer painted — the absence of any threshold line in a region
    /// conveys "in normal range" without dominating the foreground.
    private struct BloodPressureMarks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        /// v0.14.3 §A1: tile path passes `false` → drop the per-measurement
        /// `.symbol(.circle)` dots (sys + dia) so the tile is line-only.
        var showsPoints: Bool = true
        /// v0.14.3 §A2: tile path passes the calm uniform stroke width.
        var lineWidth: CGFloat?

        var body: some ChartContent {
            // Dashed threshold rules first so the lines paint on top.
            if includeThresholds {
                ThresholdRule(
                    value: 140,
                    label: "Systolisch hoch",
                    tint: HLChartTints.thresholdHigh
                )
                ThresholdRule(
                    value: 60,
                    label: "Diastolisch niedrig",
                    tint: HLChartTints.thresholdLow
                )
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Systolisch", point.value),
                    series: .value("series", "sys")
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlTileSymbol(showsPoints)
                .hlSeriesLineWidth(lineWidth)

                if let diastolic = point.secondary {
                    LineMark(
                        x: .value("Zeit", point.at),
                        y: .value("Diastolisch", diastolic),
                        series: .value("series", "dia")
                    )
                    // T2-3: secondary (diastolic) line uses `seriesMid`
                    // (same single accent at 70% opacity) so the dual-line
                    // visual stays parseable without a second hue.
                    .foregroundStyle(HLChartTints.seriesMid)
                    .interpolationMethod(.catmullRom)
                    .hlTileSymbol(showsPoints)
                    .hlSeriesLineWidth(lineWidth)
                }
            }
        }
    }

    /// Single-series LineMark + dashed personal-baseline rule. The historic
    /// gradient AreaMark was dropped per C-2 / R2 §C — pure line matches the
    /// web reference + Apple Health and removes the lower-y-range clutter.
    private struct WeightMarks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        var lineWidth: CGFloat?

        var body: some ChartContent {
            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Gewicht", point.value)
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)
            }
            // Personal baseline: median of last 90 daily points (≥5 readings required),
            // mirrors web's `computePersonalBaseline` (12-design-system §5.3).
            // T2-3: dashed pattern + width from `HLChartGrid` so it matches
            // the clinical threshold rules; the baseline is informational
            // rather than out-of-range, so it stays on tertiary text rather
            // than the red/green threshold tints.
            if includeThresholds, let baseline = personalBaseline(points) {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(HLText.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: HLChartGrid.thresholdWidth, dash: HLChartGrid.thresholdDash))
            }
        }
    }

    /// Pulse line + dashed bradycardia / tachycardia threshold rules.
    ///
    /// **T2-3 (Theme-2.0):** solid pulse-band `RectangleMark`s are gone.
    /// Tachycardia (>100 bpm resting) renders as a dashed red `RuleMark`,
    /// bradycardia (<60 bpm) as a dashed green `RuleMark` — both lower- and
    /// upper-bound clinical thresholds, no solid fill behind the series.
    private struct PulseMarks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        var lineWidth: CGFloat?

        var body: some ChartContent {
            if includeThresholds {
                ThresholdRule(
                    value: 100,
                    label: "Tachykardie",
                    tint: HLChartTints.thresholdHigh
                )
                ThresholdRule(
                    value: 60,
                    label: "Bradykardie",
                    tint: HLChartTints.thresholdLow
                )
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Puls", point.value)
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)
            }
        }
    }

    /// Line + uniform-tint dots over dashed clinical threshold rules.
    ///
    /// **C-3 (2026-05-16) recolor** per R2 §D: per-point severity dots
    /// (previously coloured by a now-removed `glucoseSeverityColor`
    /// helper — red on every out-of-range sample) are replaced by a
    /// uniform `primaryTint` paint for every dot regardless of value.
    ///
    /// **T2-3 (Theme-2.0):** the solid hypoglycemia / target / hyperglycemia
    /// `RectangleMark` bands are gone. Two dashed `RuleMark`s mark the hard
    /// clinical boundaries:
    ///
    /// - **Hypoglycemia** `< 70 mg/dL` — dashed `HLChartTints.thresholdLow`
    /// - **Hyperglycemia** `> 180 mg/dL` — dashed `HLChartTints.thresholdHigh`
    ///
    /// The 70..140 target range and the 140..180 borderline band are no
    /// longer painted — the absence of any threshold line conveys "in safe
    /// range" without dominating the foreground.
    ///
    /// Apple-Health-style visualization: danger zones are signalled by
    /// thin dashed boundaries, not by recolouring every measurement point.
    private struct GlucoseMarks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        /// v0.14.3 §A1: tile path passes `false` → drop the per-measurement
        /// `PointMark` dots so the tile is line-only.
        var showsPoints: Bool = true
        /// v0.14.3 §A2: tile path passes the calm uniform stroke width.
        var lineWidth: CGFloat?

        var body: some ChartContent {
            // Dashed clinical-boundary rules first so lines + points paint on top.
            if includeThresholds {
                ThresholdRule(
                    value: 70,
                    label: "Hypoglykämie",
                    tint: HLChartTints.thresholdLow
                )
                ThresholdRule(
                    value: 180,
                    label: "Hyperglykämie",
                    tint: HLChartTints.thresholdHigh
                )
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Glukose", point.value)
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)

                if showsPoints {
                    PointMark(
                        x: .value("Zeit", point.at),
                        y: .value("Glukose", point.value)
                    )
                    .foregroundStyle(primaryTint)
                    .symbolSize(40)
                }
            }
        }
    }

    /// Temperature line + 37.5 °C fever threshold rule (dashed red).
    private struct BodyTemperatureMarks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        var lineWidth: CGFloat?

        var body: some ChartContent {
            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Temperatur", point.value)
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)
            }
            // T2-3: fever rule routes through `HLChartTints.thresholdHigh`
            // (dashed red) with `HLChartGrid` stroke style — consistent with
            // every other upper-bound clinical threshold across the app.
            if includeThresholds {
                ThresholdRule(
                    value: 37.5,
                    label: "Fieber",
                    tint: HLChartTints.thresholdHigh
                )
            }
        }
    }

    /// SpO2 line + 95 % hypoxemia threshold (dashed green — lower bound).
    private struct SPO2Marks: ChartContent {
        let points: [SeriesPoint]
        let primaryTint: Color
        var includeThresholds: Bool = true
        var lineWidth: CGFloat?

        var body: some ChartContent {
            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("SpO2", point.value)
                )
                .foregroundStyle(primaryTint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)
            }
            // T2-3: SpO2 95% is a lower-bound clinical threshold — routes
            // through `HLChartTints.thresholdLow` (dashed green) like every
            // other hard floor (BP diastolic 60, bradycardia 60, hypoglycemia 70).
            if includeThresholds {
                ThresholdRule(
                    value: 95,
                    label: "Hypoxämie",
                    tint: HLChartTints.thresholdLow
                )
            }
        }
    }

    /// Dashed-line clinical threshold rule. Shared visual contract for every
    /// upper/lower-bound rule across BP, pulse, glucose, body-temp, SpO2.
    /// Stroke pattern + width route through `HLChartGrid` so all threshold
    /// rules render identically regardless of metric.
    private struct ThresholdRule: ChartContent {
        let value: Double
        let label: String
        let tint: Color

        var body: some ChartContent {
            RuleMark(y: .value(label, value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(
                    lineWidth: HLChartGrid.thresholdWidth,
                    dash: HLChartGrid.thresholdDash
                ))
        }
    }

    /// Generic single-series line. Historic `withArea` gradient was dropped
    /// per C-2 / R2 §C — pure line everywhere (web parity).
    private struct SingleSeriesMarks: ChartContent {
        let points: [SeriesPoint]
        let tint: Color
        var lineWidth: CGFloat?

        var body: some ChartContent {
            ForEach(points) { point in
                LineMark(
                    x: .value("Zeit", point.at),
                    y: .value("Wert", point.value)
                )
                .foregroundStyle(tint)
                .interpolationMethod(.catmullRom)
                .hlSeriesLineWidth(lineWidth)
            }
        }
    }
}

// MARK: - Tile-variant chart-content modifiers (v0.14.3 §A1/§A2, FW-HOME)

private extension ChartContent {
    /// Conditionally attaches the per-measurement circle symbol.
    ///
    /// **§A1.** The Insights detail charts show a `.symbol(.circle)` /
    /// `.symbolSize(20)` dot on every measurement (BP sys + dia). On the Home
    /// tile (`HLTileMetricChart`, `showsPoints == false`) those dots read "too
    /// intense", so the tile renders the **series line only** — when `shows`
    /// is `false` the symbol is omitted entirely. `@ChartContentBuilder`
    /// branches stay a single opaque return type.
    @ChartContentBuilder
    func hlTileSymbol(_ shows: Bool) -> some ChartContent {
        if shows {
            symbol(.circle).symbolSize(20)
        } else {
            self
        }
    }

    /// Conditionally pins the series line to a fixed stroke width.
    ///
    /// **§A2.** When `width` is non-nil (the Home-tile path passes
    /// `HLChartGrid.tileSeriesWidth`) every series `LineMark` strokes at the
    /// SAME calm width so all tiles share ONE uniform line weight, matching
    /// the medication-compliance primitive's quiet graphite. `nil` (the
    /// Insights detail path) keeps the Charts default (~2pt) — detail charts
    /// stay byte-identical to before.
    @ChartContentBuilder
    func hlSeriesLineWidth(_ width: CGFloat?) -> some ChartContent {
        if let width {
            lineStyle(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        } else {
            self
        }
    }
}

// MARK: - Helpers

/// Median of the last 90 daily-aggregated points; returns `nil` if fewer than
/// 5 readings are available. Pure function so it's testable in isolation.
///
/// Mirrors web's `computePersonalBaseline` (`health-chart.tsx` §289).
func personalBaseline(_ points: [SeriesPoint]) -> Double? {
    let recent = Array(points.suffix(90))
    guard recent.count >= 5 else { return nil }
    let values = recent.map(\.value).sorted()
    let mid = values.count / 2
    if values.count.isMultiple(of: 2) {
        return (values[mid - 1] + values[mid]) / 2
    }
    return values[mid]
}
