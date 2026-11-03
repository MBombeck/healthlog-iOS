import SwiftUI

// MARK: - Chart style tokens (Apple Charts wrappers + sparkline shared)

public enum HLChartStyle {
    public static let lineWidth: CGFloat = 2
    public static let pointSize: CGFloat = 6
    /// **1.4 B4 — the app's two chart heights.** Before this there were
    /// eleven, set by hand per chart (32 to 280 pt). Every chart now takes one
    /// of these; the full-screen chart fills its screen.
    ///
    /// The line without axes: a tile on Heute, a Vitalwerte or recovery card,
    /// the 30-day card's line, a record card.
    public static let heightCompact: CGFloat = 36
    /// Every chart with axes, in a card or as a detail page's main chart.
    /// 220 pt fits five y-axis labels (the mood scale) and was already the
    /// most common height.
    public static let heightRegular: CGFloat = 220
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

    /// Mid-emphasis tint — a secondary line beside the series (the basal
    /// temperature line under its phase dots) or the scrubber rule. ~70% of
    /// `series`.
    public static var seriesMid: Color {
        HLColor.inkGraphite.opacity(0.7)
    }

    /// Low-emphasis tint — the second line of a two-line chart (BP diastolic
    /// under systolic, the mood chart's daily line under its 7-day average).
    /// ~40% so it reads as clearly lighter than the primary line without
    /// disappearing into the 10% grid.
    public static var seriesLow: Color {
        HLColor.inkGraphite.opacity(0.4)
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
    /// overlays. `[4, 3]` reads as discrete dashes at both chart heights
    /// HLChartStyle ships (36 pt compact, 220 pt regular).
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
