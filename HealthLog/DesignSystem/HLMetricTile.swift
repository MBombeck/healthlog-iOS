import SwiftUI

/// v0.10.0 W-Insights (R2 §3) — the descriptor-driven **Insights** metric tile.
///
/// **Scope (W6b, #57-followup resolved):** this is the metric tile used **inside
/// the Insights tab** (`InsightsTargetTileGrid`, `PerKindInsightsBlock`, the
/// W-Mood detail). It collapsed the older Insights-side anatomies
/// (`InsightsTargetTile`, `PerKindInsightCard`) into one descriptor-driven
/// surface.
///
/// **Relationship to `HLDashboardTile` (STANDARDS §7).** The two tiles are
/// **distinct compositions** — the Dashboard tile owns the
/// descriptor/dataState/matched-geometry/cumulative-sum machinery; this tile
/// owns the Insights treatment (context line + range band + status badge +
/// per-tile AI affordance). They are NOT one struct. What they DO share is the
/// per-fragment rendering: both draw their header glyph, title, trend glyph,
/// and mono sparkline through the **single** `HLMetricTileChrome` primitive
/// family (`HLTileHeaderGlyph` / `HLTileTitleLabel` / `HLTileTrendGlyph` /
/// `HLTileSparkline`). There is no longer a second hand-rolled code path for
/// any shared tile fragment — the two read as the same material because they
/// render from the same primitives, expressing their intentional differences
/// (Dashboard has no badge/band/AI; Insights has no matched-geometry) as
/// composition, not as duplicated chrome.
///
/// Renders every metric snapshot at the operator's bar: **value + 30-day
/// context + an optional target/normalcy band + a sparkline + a per-tile AI
/// affordance**, all monochrome with color used only as a status signal
/// (handbook §1.2 / §2.1, the Blood-Pressure tile is the benchmark).
///
/// **Anatomy** (HLCard, padding `HLSpace.lg`, radius `HLRadius.lg`):
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ ◐  Weight                          ↓   ✦      │  header: icon + title + trend + AI
/// │ 72.4 kg                                        │  value (.hlMetric) + unit
/// │ 23 of 30 days in range · Ø 30d 72.8 kg         │  context line (the "deep" line)
/// │ ╱╲╱╲╱                                          │  sparkline (mono, 36 pt)
/// │ ▟▟▟░░▟▟ Target 71–74 kg                        │  OPTIONAL range band (BP-style)
/// │ ● In range                                     │  OPTIONAL status badge (dot only)
/// └──────────────────────────────────────────────┘
/// ```
///
/// **Sendable inputs** so the descriptor can be computed off the view (and
/// unit-tested). The tile renders ONLY with data — `value`-less + `context`-
/// less tiles should not be constructed by the caller (the data-only contract,
/// R2 §3.3; the grid's `hasData` gate enforces this upstream).
///
/// **Reusable by W-Mood:** this primitive is self-contained — it imports no
/// Insights-screen state. The mood-detail surface (W-Mood) constructs an
/// `HLMetricTile` from its own view-model and gets the identical anatomy.
public struct HLMetricTile: View {
    /// SF Symbol for the header glyph (always `HLText.secondary`, never tinted).
    public let icon: String
    /// The header title, pre-resolved to a `Text` so callers can pass either a
    /// `LocalizedStringKey` (string-literal call sites) or a
    /// `LocalizedStringResource` (descriptor-driven call sites, e.g. the
    /// long-tail) without a double-lookup.
    public let title: Text
    /// Plain title String for the combined VoiceOver label + a11y identifiers.
    private let titleAccessibility: String
    /// Pre-formatted value string (`"72.4"`, `"124/81"`). Callers format per
    /// metric/locale. `"—"` is permitted for an atomic-pair dataless half.
    public let value: String
    public let unit: String?
    public let trend: Trend
    /// 7-day strip. `HLSparkline` needs ≥2 points to draw a line; fewer
    /// collapses to the hairline branch.
    public let sparkline: [Double]
    /// One quiet context line under the value ("23 of 30 days in range · Ø 30d
    /// 72.8 kg"). `nil` in compact half-pairs so adjacent tiles align.
    public let context: String?
    /// BP-style normalcy band. `nil` → no band (and no status badge).
    public let range: RangeBand?
    /// "Im Zielbereich" badge state — the only color on the tile aside from an
    /// adverse trend glyph + the range-band fill.
    public let badge: InTargetState
    /// Half-width pair layout (Mood + Stability): drops the context line so the
    /// two tiles align on a single value-row baseline.
    public let compact: Bool
    /// Per-tile AI affordance. When non-nil, a `✦` sparkles glyph renders in
    /// the header; tapping it fires this closure (the parent presents the
    /// explainer sheet — R2 §3.5 / Phase B). `nil` → no `✦` (AI not configured
    /// or no metric mapping), tile stays pure data.
    public let onAIExplainer: (() -> Void)?
    /// Task #36 — the metric whose Insights chart vocabulary this tile's
    /// sparkline mirrors. When set, the sparkline row routes through the SAME
    /// `MetricChartContent` engine + `inkGraphite` ink as the metric's full
    /// Insights page (per-metric line style, thresholds, points). `nil` (the
    /// string-only adapter call sites that carry no `MetricKind`) falls through
    /// to the generic mono `HLSparkline` line — same as before.
    public let chartKind: MetricKind?

    /// String-literal / `LocalizedStringKey` call site (the grid + the
    /// `InsightsTargetTile` adapter). Pass `titleText` for the VoiceOver label
    /// (a `LocalizedStringKey` cannot be resolved back to a String); when
    /// omitted, the `✦` a11y label falls back to a generic phrasing.
    public init(
        icon: String,
        title: LocalizedStringKey,
        titleText: String = "",
        value: String,
        unit: String? = nil,
        trend: Trend = .none,
        sparkline: [Double] = [],
        context: String? = nil,
        range: RangeBand? = nil,
        badge: InTargetState = .unknown,
        compact: Bool = false,
        onAIExplainer: (() -> Void)? = nil,
        chartKind: MetricKind? = nil
    ) {
        self.init(
            icon: icon,
            title: Text(title),
            titleAccessibility: titleText,
            value: value,
            unit: unit,
            trend: trend,
            sparkline: sparkline,
            context: context,
            range: range,
            badge: badge,
            compact: compact,
            onAIExplainer: onAIExplainer,
            chartKind: chartKind
        )
    }

    /// Descriptor-driven call site — pass the metric's `LocalizedStringResource`
    /// title directly (no double-lookup), e.g. the long-tail tiles.
    public init(
        icon: String,
        titleResource: LocalizedStringResource,
        value: String,
        unit: String? = nil,
        trend: Trend = .none,
        sparkline: [Double] = [],
        context: String? = nil,
        range: RangeBand? = nil,
        badge: InTargetState = .unknown,
        compact: Bool = false,
        onAIExplainer: (() -> Void)? = nil,
        chartKind: MetricKind? = nil
    ) {
        self.init(
            icon: icon,
            title: Text(titleResource),
            titleAccessibility: String(localized: titleResource),
            value: value,
            unit: unit,
            trend: trend,
            sparkline: sparkline,
            context: context,
            range: range,
            badge: badge,
            compact: compact,
            onAIExplainer: onAIExplainer,
            chartKind: chartKind
        )
    }

    private init(
        icon: String,
        title: Text,
        titleAccessibility: String,
        value: String,
        unit: String?,
        trend: Trend,
        sparkline: [Double],
        context: String?,
        range: RangeBand?,
        badge: InTargetState,
        compact: Bool,
        onAIExplainer: (() -> Void)?,
        chartKind: MetricKind?
    ) {
        self.icon = icon
        self.title = title
        self.titleAccessibility = titleAccessibility
        self.value = value
        self.unit = unit
        self.trend = trend
        self.sparkline = sparkline
        self.context = context
        self.range = range
        self.badge = badge
        self.compact = compact
        self.onAIExplainer = onAIExplainer
        self.chartKind = chartKind
    }

    public var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                headerRow
                valueRow
                if !compact, let context, !context.isEmpty {
                    Text(context)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(1)
                }
                sparklineRow
                if !compact, let range {
                    RangeBandRow(band: range)
                }
                if let badge = badge.badge {
                    badgeRow(badge)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The tile combines into one spoken label for the parent
        // NavigationLink. The `✦` button would be flattened away by `.combine`,
        // so we re-expose it as a VoiceOver custom action — the assistant
        // explainer stays reachable without a second focus stop (R2 §6.6).
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onAIExplainer {
                Button(aiAffordanceLabel, action: onAIExplainer)
            }
        }
    }

    private var headerRow: some View {
        // W6b — header glyph + title + trend now route through the shared
        // `HLMetricTileChrome` primitives (the single tile-fragment code path).
        // The `✦` AI affordance is the Insights-only trailing accessory.
        HLTileHeaderRow(icon: icon, title: title, spacerMinLength: HLSpace.xs) {
            trendGlyph
            if let onAIExplainer {
                aiAffordance(onAIExplainer)
            }
        }
    }

    private var trendGlyph: some View {
        // Adverse direction is the only colour signal; mono otherwise (the
        // shared `HLTileTrendGlyph` owns the 11pt / colour rules).
        HLTileTrendGlyph(symbolName: trend.symbolName, isAdverse: trend == .adverse)
    }

    /// `✦` sparkles — mono `HLText.secondary`, NOT purple (handbook §9: ✦ is
    /// secondary, color stays a signal). Own a11y element so VoiceOver reads
    /// "AI insight for <title>, double-tap to open".
    private func aiAffordance(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Fixed-size affordance glyph inside a 28pt tap target.
            Image(systemName: "sparkles")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HLText.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hidden from the combined tile label — surfaced instead as a VoiceOver
        // custom action on the tile (see `body`) so it isn't flattened into the
        // spoken text yet stays reachable.
        .accessibilityHidden(true)
    }

    private var aiAffordanceLabel: String {
        titleAccessibility.isEmpty
            ? String(localized: "AI insight")
            : String(localized: "AI insight for \(titleAccessibility)")
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(value)
                // Audit-01 H3 — semantic metric style (28pt @ Large) instead of
                // the pixel-locked escape hatch, so the tile value scales with
                // Dynamic Type / accessibility text sizes.
                .font(.hlMetric(.title))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .hlAnimation(.snappy(duration: 0.25), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var sparklineRow: some View {
        // W6b — the single chart-row code path (36pt).
        // Task #36 — when `chartKind` is set, the row renders through the same
        // `MetricChartContent` engine + `inkGraphite` ink as the metric's
        // Insights page; the string-only adapter callers leave it `nil` and get
        // the generic mono `HLSparkline` line.
        HLTileSparkline(values: sparkline, kind: chartKind)
    }

    private func badgeRow(_ badge: InTargetState.Badge) -> some View {
        HStack(spacing: HLSpace.xs) {
            Circle()
                .fill(badge.dotColor)
                .frame(width: 6, height: 6)
            Text(badge.label)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(badge.dotColor)
                .lineLimit(1)
        }
        .padding(.top, HLSpace.xxs)
    }
}

public extension HLMetricTile {
    /// Direction-only trend marker. Mirrors `HLDashboardTile.TrendChip` rules
    /// (handbook §2.1) — monochrome by default, red only on adverse direction,
    /// hidden entirely when unknown.
    enum Trend: Equatable, Sendable {
        case favorable
        case adverse
        case stable
        case none

        var symbolName: String? {
            switch self {
            case .favorable: "arrow.up"
            case .adverse: "arrow.down"
            case .stable: "minus"
            case .none: nil
            }
        }

        var color: Color {
            switch self {
            case .adverse: HLColor.statusBad
            default: HLText.secondary
            }
        }
    }

    /// "Im Zielbereich" state. The latest non-nil consistency bucket wins —
    /// the operator's mental model is "where am I right now", not "where was
    /// my week".
    enum InTargetState: Equatable, Sendable {
        case unknown
        case inBand
        case nearBand
        case outBand

        public struct Badge: Equatable {
            let label: String
            let dotColor: Color
        }

        var badge: Badge? {
            switch self {
            case .inBand:
                Badge(label: String(localized: "In range"), dotColor: HLColor.statusOK)
            case .nearBand:
                Badge(label: String(localized: "Near range"), dotColor: HLColor.statusWarn)
            case .outBand:
                Badge(label: String(localized: "Out of range"), dotColor: HLColor.statusBad)
            case .unknown:
                nil
            }
        }
    }
}

#Preview("HLMetricTile — Weight, full, ranged + AI") {
    HLMetricTile(
        icon: "scalemass",
        title: "Weight",
        value: "72.4",
        unit: "kg",
        trend: .favorable,
        sparkline: [73.4, 73.2, 73.0, 72.9, 72.7, 72.5, 72.4],
        context: "23 of 30 days in range · Ø 30d 72.8 kg",
        range: RangeBand(lowerLabel: "71", upperLabel: "74", unit: "kg", pctInRange: 77),
        badge: .inBand,
        onAIExplainer: {}
    )
    .padding()
    .background(HLSurface.primary)
}

#Preview("HLMetricTile — Mood half-pair") {
    HStack(spacing: HLSpace.md) {
        HLMetricTile(
            icon: "face.smiling",
            title: "Stimmung",
            value: "3.8",
            trend: .favorable,
            sparkline: [3.0, 3.4, 3.6, 3.8, 3.7, 3.9, 3.8],
            badge: .inBand,
            compact: true
        )
        HLMetricTile(
            icon: "waveform.path.ecg",
            title: "Stabilität",
            value: "82",
            unit: "%",
            trend: .stable,
            sparkline: [78, 79, 80, 81, 82, 82, 82],
            badge: .nearBand,
            compact: true
        )
    }
    .padding()
    .background(HLSurface.primary)
}
