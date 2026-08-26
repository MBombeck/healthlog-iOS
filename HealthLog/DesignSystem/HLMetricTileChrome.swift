import SwiftUI

// W6b (#57-followup / STANDARDS §7) — the ONE metric-tile building-block
// family. Before this file the Dashboard tile (`HLDashboardTile`), the
// Insights tile (`HLMetricTile`), and the Sleep composite each hand-rolled
// the same four sub-rows (header glyph, title label, trend glyph, mono
// sparkline) with subtly-drifting literals. This consolidates those rows into
// shared primitives so there is a single code path rendering each shared
// fragment — without forcing the three distinct tile compositions into one
// monolith. Each tile keeps its own `body` (and its own data/layout logic)
// but draws its shared fragments from here.
//
// **Pixel contract (do NOT drift):** these literals are the canonical values
// the three call sites previously duplicated verbatim:
// - header glyph: 14 pt semibold system symbol, `HLText.secondary`
// - title: `.hlCaption.weight(.semibold)`, `HLText.secondary`, 1 line, 0.8 min-scale
// - trend glyph: 11 pt bold system arrow, mono unless adverse → `statusBad`
// - sparkline: `HLSparkline(tint: HLText.tertiary)`, 36 pt tall, leading
//
// The fixed pixel symbol sizes are the sanctioned exception in STANDARDS §1 —
// fixed-frame chrome glyphs pixel-locked across tiles; the title beside them
// carries Dynamic Type (each use is annotated at its call below).

// MARK: - Header glyph

/// The metric icon — fixed-size, monochrome chrome (never tinted).
struct HLTileHeaderGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(HLText.secondary)
    }
}

// MARK: - Title label

/// The metric title beside the glyph. Caption-semibold, secondary, single
/// line with a gentle scale-down so long titles never wrap a tile.
struct HLTileTitleLabel: View {
    let title: Text

    init(_ title: Text) {
        self.title = title
    }

    init(_ key: LocalizedStringKey) {
        title = Text(key)
    }

    var body: some View {
        title
            .font(.hlCaption.weight(.semibold))
            .foregroundStyle(HLText.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - Trend glyph

/// Direction-only trend marker — the single arrow-glyph code path shared by
/// the Dashboard `TrendChip`, the Insights tile, and the Vitals dashboard.
///
/// **Doctrine (STANDARDS §2 / Theme C-5):** flat inline glyph, no filled pill.
/// Monochrome by default; `statusBad` (red) ONLY on an adverse direction so
/// trend stays legible to non-colour-aware users without a green/red duality.
/// Unknown direction renders nothing.
struct HLTileTrendGlyph: View {
    /// `nil` → render nothing (unknown trend suppresses the glyph entirely).
    let symbolName: String?
    /// `true` → adverse direction for this metric's polarity → `statusBad`.
    let isAdverse: Bool

    var body: some View {
        if let symbolName {
            Image(systemName: symbolName)
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isAdverse ? HLColor.statusBad : HLText.secondary)
        }
    }
}

// MARK: - Sparkline row

/// The tile chart row — 36 pt tall, leading aligned. The single chart-row code
/// path for every metric tile (Dashboard + Insights + Sleep composite).
///
/// **Task #36 — unified with the Insights chart.** When a `kind` is supplied,
/// the row renders through `HLTileMetricChart`, which routes the mini-chart
/// through the SAME `MetricChartContent` mark engine + `inkGraphite` data-ink
/// the Insights `ChartCard` uses — so a metric tile preview reads as the same
/// chart, same colour, same per-metric vocabulary (BP thresholds, glucose
/// points, weight baseline) as its full Insights page, just shrunk and
/// non-interactive (axis/scrub/period are carried by the tap-through to
/// `InsightsMetricScreen`).
///
/// **Kind-less fallback.** Non-metric callers (and the chrome unit test) omit
/// the `kind` and get the plain `HLSparkline` mono line — there is no metric
/// vocabulary to apply without a `MetricKind`, so the generic line stays the
/// honest render for those surfaces.
struct HLTileSparkline: View {
    let values: [Double]
    /// The metric whose Insights chart vocabulary this tile mirrors. `nil` →
    /// generic mono `HLSparkline` (non-metric callers).
    var kind: MetricKind?

    var body: some View {
        Group {
            if let kind {
                HLTileMetricChart(kind: kind, values: values)
            } else {
                HLSparkline(values: values, tint: HLText.tertiary)
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header row

/// The canonical tile header: glyph + title + spacer + trailing accessory
/// (trend glyph, and optionally more — the Insights tile slots its `✦` AI
/// affordance after the trend). The trailing closure keeps the row reusable
/// for both the Dashboard (`Spacer()` + trend) and the Insights
/// (`Spacer(minLength:)` + trend + AI) compositions.
struct HLTileHeaderRow<Trailing: View>: View {
    let icon: String
    let title: Text
    /// `HLSpace.xs` spacer min-length on Insights, default `Spacer()` on
    /// Dashboard — both resolve to the same rest layout; expressed as a flag
    /// so the two read identically.
    var spacerMinLength: CGFloat?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            HLTileHeaderGlyph(systemName: icon)
            HLTileTitleLabel(title)
            if let spacerMinLength {
                Spacer(minLength: spacerMinLength)
            } else {
                Spacer()
            }
            trailing()
        }
    }
}
