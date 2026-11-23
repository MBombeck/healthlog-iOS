import SwiftUI

// W6b (#57-followup / STANDARDS §7) — the ONE metric-tile building-block
// family. Before this file the Dashboard tile (`HLDashboardTile`), the
// Insights tile (`HLMetricTile`), and the Sleep composite each hand-rolled
// the same four sub-rows (header glyph, title label, trend glyph, mono
// sparkline) with subtly-drifting literals. This consolidates those rows into
// shared primitives so there is a single code path rendering each shared
// fragment — without forcing the three distinct tile compositions into one
// monolith. Each tile keeps its own `body` (and its own data/layout logic)
// but draws its shared fragments from here. (`HLMetricTile` itself was never
// mounted after the Insights overview redesign and was deleted in #115 B7;
// the Dashboard tile and the Sleep composite remain.)
//
// **Pixel contract (do NOT drift):** these literals are the canonical values
// the three call sites previously duplicated verbatim:
// - header glyph: semibold system symbol, 14 pt at the standard text size and
//   growing with the title up to 20 pt, `HLText.secondary`
// - title: `.hlCaption.weight(.semibold)`, `HLText.secondary`, 1 line, 0.8 min-scale
// - sparkline: `HLSparkline` in its one tint, 36 pt tall, leading
//
// The header glyph is chrome and the same in every tile; the title beside it
// carries Dynamic Type, and the glyph follows it up to its cap.

// MARK: - Header glyph

/// The metric icon — monochrome chrome (never tinted). It grows with the
/// title beside it and stops at ``largestSize``, so the two stay a pair at
/// large text without the glyph taking the title's room in a narrow tile.
struct HLTileHeaderGlyph: View {
    /// The size at the standard text size.
    static let baseSize: CGFloat = 14
    /// Where the glyph stops growing.
    static let largestSize: CGFloat = HLIconSize.lg

    let systemName: String
    @ScaledMetric(relativeTo: .caption) private var scaledSize: CGFloat = HLTileHeaderGlyph.baseSize

    var body: some View {
        Image(systemName: systemName)
            .font(.hlIcon(min(scaledSize, Self.largestSize)))
            .foregroundStyle(HLText.secondary)
    }
}

// MARK: - Title label

/// The metric title beside the glyph. Caption-semibold, secondary, single
/// line with a gentle scale-down so long titles never wrap a tile.
///
/// At the accessibility sizes one line cut "Medikamenten-T…" and
/// "Sauerstoffsätt…"; there the title wraps instead (Dynamic Type: wrap,
/// never truncate). The standard sizes keep the one line.
struct HLTileTitleLabel: View {
    let title: Text
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
    }
}

// MARK: - Sparkline row

/// The tile chart row — 36 pt tall, leading aligned. The single chart-row code
/// path for every metric tile (Dashboard + Insights + Sleep composite).
///
/// **Unified with the Insights chart.** When a `kind` is supplied,
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
                HLSparkline(values: values)
            }
        }
        .frame(height: HLChartStyle.heightCompact)
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
