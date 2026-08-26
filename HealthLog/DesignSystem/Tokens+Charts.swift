import SwiftUI

// MARK: - Chart style tokens (Apple Charts wrappers + sparkline shared)

public enum HLChartStyle {
    public static let lineWidth: CGFloat = 2
    public static let pointSize: CGFloat = 6
    /// Detail-screen chart height (ChartDetailScreen hero).
    public static let heightDetail: CGFloat = 200
    /// Dashboard tile mini-chart height.
    public static let heightCompact: CGFloat = 80
    /// Mood / emoji-axis chart height — taller to fit five Y-axis labels.
    public static let heightEmojiAxis: CGFloat = 220
}

// MARK: - Theme-2.0 Chart-series ramp + grid (T2-1 Foundation, 2026-05-16)

//
// Operator Theme-2.0 spec: "All metrics render on the single accent. Per-metric
// color routing REMOVED — no more weight=blue, glucose=red, body_temp=orange."
// + "Threshold overlays dashed red/green only — no solid fills, no AreaMarks"
// + "Grid very subtle (~10% primary text opacity), no thick gridlines."
//
// `HLChartTints` is the single namespace every chart series resolves through.
// T2-3 will sweep `MetricChartContent` so its per-kind branches stop carrying
// per-metric Dracula defaults and route here.
// Pre-T2-3, `MetricChartContent.SingleSeriesMarks(tint:)` still accepts an
// arbitrary `Color` argument — the new tokens are intentionally additive.

/// Chart-series tonal ramp — single Dracula-Purple accent at three opacities
/// for primary line + range bands + grid-level emphasis. Per-metric branches
/// resolve **all** through `series` so the dashboard reads as a single calm
/// material across every metric.
///
/// **Threshold overlays:**
/// - `thresholdHigh` — dashed red `#FF5555` for hard upper-bound rule-marks
///   (e.g. BP systolic > 140, body temp > 38.0).
/// - `thresholdLow` — dashed green `#50FA7B` for hard lower-bound rule-marks
///   (e.g. BP diastolic < 60, resting-HR < 50).
/// - **No solid fills.** AreaMarks were removed in C-2 (R2 §C); the
///   `RectangleMark` clinical-band overlays in `MetricChartContent` will be
///   thinned in T2-3 to dashed RuleMarks at the band boundaries.
public enum HLChartTints {
    /// Primary series stroke — the LineMark colour.
    ///
    /// **v0.8.1 monochrome-restore:** previously resolved the persisted
    /// `hl.settings.tint` (default `.purple`), which painted every chart line
    /// purple now that the accent-picker UI is retired. Per the monochrome
    /// direction ("chrome = monochrome, accent is signal-only"), chart series
    /// resolve to a monochrome ink. Threshold overlays
    /// (`thresholdHigh`/`thresholdLow`) keep their real signal red/green.
    ///
    /// **v0.14 light-mode walk:** repointed from `HLText.primary`
    /// (Apple-label parity) to the softer `HLColor.inkGraphite` so dense
    /// data-ink reads as "refined graphite" rather than near-black on white.
    /// v0.14.11 "Warmes Papier": the graphite's light slot is the warm
    /// `#454138` (≈9.6:1 on the `#FAF8F5` card). Text stays on
    /// `HLText.primary` — only chart lines + ring strokes (which default to
    /// `series`) move to the graphite. Dark mode is unchanged
    /// (`inkGraphite` dark == `HLText.primary` dark).
    public static var series: Color {
        HLColor.inkGraphite
    }

    /// Mid-emphasis tint — secondary series (e.g. BP diastolic when the
    /// primary is systolic) or range-band fill. ~70% of `series`.
    public static var seriesMid: Color {
        HLColor.inkGraphite.opacity(0.7)
    }

    /// Low-emphasis tint — tertiary surface (range upper/lower envelope,
    /// 7-day rolling band). ~40% so it sits behind the primary line without
    /// competing.
    public static var seriesLow: Color {
        HLColor.inkGraphite.opacity(0.4)
    }

    // MARK: - Multi-series differentiation (v0.5.2-R1 reconcile)

    //
    // History: Visual-Polish-1 (2026-05-16) shipped a fixed 4-tint
    // Dracula palette (purple / cyan / pink / orange) for the
    // TrendsOverlayCard z-score overlay so 2-4 metrics could be read
    // at a glance. Operator design-QA on v0.5.2 caught a regression:
    // when the user-picked accent collides with one of the Dracula alts
    // (e.g. `.cyan` accent → weight series cyan AND BP series cyan), two
    // overlaid metrics collapsed onto the same hue.
    //
    // Resolution (v0.5.2-R1): lead series = user-picked accent (`series`).
    // Companion series paint in a monochrome graphite ramp derived from
    // `HLText.primary` at three opacities so:
    //   • The accent line always reads as the "headline" series.
    //   • Companion lines stay distinct from the accent regardless of pick.
    //   • Theme-2.0 single-accent contract holds — colour information lives
    //     in the lead line, companion lines differentiate by lightness only.
    //
    // Single-metric callers continue to route through `series` exclusively —
    // the companion ramp activates only when 2+ metrics overlay.

    /// Multi-series companion #1 — graphite at ~80% primary text. Reads as
    /// the second-headline series (still strong, but visibly behind the
    /// accent-coloured lead line).
    public static var seriesAlt1: Color {
        HLColor.inkGraphite.opacity(0.80)
    }

    /// Multi-series companion #2 — graphite at ~55%. Reads as a tertiary
    /// peer line; clearly distinct from companion #1 by lightness step.
    public static var seriesAlt2: Color {
        HLColor.inkGraphite.opacity(0.55)
    }

    /// Multi-series companion #3 — graphite at ~35%. The lightest step,
    /// sits behind the other three without disappearing into the gridlines
    /// (`HLChartGrid.lineOpacity` = 0.10, so 0.35 stays clearly above the
    /// grid noise floor).
    public static var seriesAlt3: Color {
        HLColor.inkGraphite.opacity(0.35)
    }

    /// Ordered ramp consumed by multi-series charts for deterministic
    /// per-series colour assignment. Index 0 maps to `series` (the
    /// user-picked accent), 1→alt1, 2→alt2, 3→alt3; consumers cycle via
    /// modulo when more than 4 series are active.
    ///
    /// v0.5.2-R1 reconcile: companions are graphite shades (no longer
    /// fixed Dracula hues) so the user accent never collides with a
    /// companion regardless of which `HLTint` the operator picks.
    public static var multiSeriesRamp: [Color] {
        [series, seriesAlt1, seriesAlt2, seriesAlt3]
    }

    /// Dashed threshold overlay — hard upper bound (hypertensive systolic,
    /// fever, etc.). Red signals "out of safe range — clinical attention".
    /// Routes through `statusBad` so the dashed rule de-neons on white in
    /// light mode while keeping the Dracula red in dark (W-LIGHT v0.8.0).
    public static let thresholdHigh = HLColor.statusBad

    /// Dashed threshold overlay — hard lower bound (bradycardia, hypotensive
    /// diastolic, etc.). Green signals "below safe range — clinical attention".
    /// Routes through `statusOK`; the dashed stroke + axis context
    /// disambiguate it from a solid status pill (W-LIGHT v0.8.0).
    public static let thresholdLow = HLColor.statusOK
}

/// Chart grid + axis tokens — Tonal-Mono ultra-subtle treatment per operator
/// Theme-2.0 spec ("Grid very subtle, ~10% primary text opacity, no thick
/// gridlines"). Used by `MetricChartContent.AxisStyleModifier` post-T2-3.
public enum HLChartGrid {
    /// Grid-line stroke opacity — derives from `HLText.primary`. ~10%.
    public static let lineOpacity: Double = 0.10

    /// Grid-line stroke width — hairline only, no chunky 1pt+ grids.
    public static let lineWidth: CGFloat = 0.5

    /// Axis-label opacity — slightly stronger than gridlines so tick labels
    /// stay legible without becoming chart-noise. ~40% of primary text.
    public static let labelOpacity: Double = 0.40

    /// Threshold-rule stroke style — dashed pattern for both high + low
    /// overlays. `[4, 3]` reads as discrete dashes at every chart height
    /// HLChartStyle ships (80pt compact through 220pt emoji-axis).
    public static let thresholdDash: [CGFloat] = [4, 3]

    /// Threshold-rule stroke width — heavier than gridlines so the dashed
    /// red/green pops above the series, but still thinner than the primary
    /// LineMark (2pt) so it doesn't shout over the data.
    public static let thresholdWidth: CGFloat = 1.5

    /// **v0.14.3 §A2 (FW-HOME) — Home-tile series stroke width.**
    /// The Dashboard mini-chart (`HLTileMetricChart`) renders one calm,
    /// uniform line across EVERY tile (Blutdruck, Schritte, Puls, Gewicht, …)
    /// so the Home surface reads as a single quiet material — matching the
    /// calm graphite of the medication-compliance primitive
    /// (`HLComplianceBar` / `ComplianceBand.good` = `HLText.primary` graphite).
    /// v0.14.7 A1 — pinned to `HLChartStyle.lineWidth` (2.0), the EXACT stroke the
    /// medication-compliance `HLSparkline` and the Insights detail chart use, so
    /// every Home tile reads identically to the compliance line the operator
    /// anchored on. (It briefly went to 2.1 in v0.14.6 FW-QUICK, which read
    /// "thicker/whiter" than the compliance line — the real fix for the felt
    /// mismatch was the dark-mode tint (`HLText.tertiary`, see HLTileMetricChart),
    /// not a heavier weight.) The colour stays monochrome (`HLText.tertiary`), no
    /// per-metric hue. The Insights detail charts keep the default width (the tile
    /// flag is opt-in: `MetricChartContent.marks(seriesLineWidth:)` is `nil` for
    /// detail).
    public static let tileSeriesWidth: CGFloat = HLChartStyle.lineWidth
}
