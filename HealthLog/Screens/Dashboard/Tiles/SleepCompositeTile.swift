import SwiftUI

/// Sleep tile with a stages strip (Core / REM / Deep / Awake) — used when
/// the caller has per-stage data (typically pulled from `AIInsightResponse.
/// sleepStages` in `InsightsStore.comprehensive`). Falls back to the plain
/// `HLDashboardTile` shape when no stages are provided.
///
/// The dashboard summary endpoint does NOT include stages today (server
/// PR pending — A3 §7.1). Until then, the simple sleep tile renders via
/// `HLDashboardTile`; this composite component exists ready to swap when
/// stages flow on the wire.
public struct SleepCompositeTile: View {
    public struct StagesBreakdown: Sendable, Equatable {
        public let core: Double // minutes
        public let rem: Double // minutes
        public let deep: Double // minutes
        public let awake: Double // minutes

        public init(core: Double, rem: Double, deep: Double, awake: Double) {
            self.core = core
            self.rem = rem
            self.deep = deep
            self.awake = awake
        }

        public var total: Double {
            core + rem + deep + awake
        }
    }

    private let metric: DashboardMetric
    private let stages: StagesBreakdown?
    /// W-IMPL-BACKLOG-CLEANUP (v0.5.5.2) — matched-geometry namespace
    /// forwarded by `DashboardTileRouter`. The composite tile picks the
    /// duration text as the dominant element (mirrors `HLDashboardTile`'s
    /// value-row source) so the sleep tile participates in the same
    /// shared-element transition into `ChartDetailScreen.HeroStrip` that
    /// every other metric tile does. The stages strip + legend stay
    /// behind — they have no destination peer in the chart-detail hero
    /// today. `nil` under reduce-motion or on surfaces without a host
    /// namespace.
    private let matchedNamespace: Namespace.ID?

    @ScaledMetric(relativeTo: .title2) private var primaryValueSize: CGFloat = 28

    public init(
        metric: DashboardMetric,
        stages: StagesBreakdown? = nil,
        matchedNamespace: Namespace.ID? = nil
    ) {
        self.metric = metric
        self.stages = stages
        self.matchedNamespace = matchedNamespace
    }

    public var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                value
                if let stages, stages.total > 0 {
                    // Stages strip + legend remain coloured: they are
                    // chart-content (data visualization), not tile chrome.
                    stagesStrip(stages: stages)
                    stagesLegend(stages: stages)
                } else {
                    // C-1 + C-6 + Theme-2.0 (T2-2): fallback sparkline goes
                    // monochrome at rest (HLText.tertiary) and pure `.line`
                    // (HLSparkline default per R2 §Primitive #3). W6b — routes
                    // through the shared `HLTileSparkline` (single sparkline-row
                    // code path). Task #36 — pass `.sleep` so the fallback chart
                    // shares the Insights engine + `inkGraphite` ink.
                    HLTileSparkline(values: metric.sparkline, kind: .sleep)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedLabel)
    }

    private var header: some View {
        let descriptor = MetricKind.sleep.descriptor
        // W6b — the glyph + title route through the shared `HLMetricTileChrome`
        // primitives (the single tile-fragment code path). The Sleep header
        // keeps its OWN composition: the trailing accessory is the descriptor's
        // `secondaryHint` (e.g. "letzte Nacht"), not a trend glyph — so it does
        // not use `HLTileHeaderRow` (which is trend-shaped), but it does share
        // the glyph + title rendering so the chrome reads identically.
        return HStack(spacing: HLSpace.xs) {
            HLTileHeaderGlyph(systemName: descriptor.sfSymbol)
            HLTileTitleLabel(Text(descriptor.title))
            Spacer()
            if let secondary = descriptor.secondaryHint {
                Text(secondary)
                    .font(.hlCaption2.weight(.medium))
                    .foregroundStyle(HLText.tertiary)
            }
            TrendChip(
                trend: metric.dashboardTrend,
                polarity: descriptor.trendPolarity,
                mode: .dashboardDirection
            )
        }
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(metric.formattedPrimary())
                .font(.hlMetric(primaryValueSize))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
                // W-IMPL-BACKLOG-CLEANUP (v0.5.5.2) — shared-element source
                // matching the chart-detail hero. The destination already
                // exists in `ChartDetailScreen.HeroStrip` keyed by
                // `MetricKind.sleep`, so the matched id resolves without
                // a destination-side change. `matchedNamespace == nil`
                // (reduce-motion / preview / non-dashboard host) routes
                // through the identity branch of `matchedTileGeometry`.
                .matchedTileGeometry(
                    id: DashboardMatchedGeometryID.value(for: .sleep),
                    in: matchedNamespace
                )
        }
    }

    /// Theme-2.0 (T2-2): the four sleep stages now paint a single-accent ramp
    /// built from `HLChartTints` — deep = full series accent, REM = seriesMid
    /// (70% accent), core = seriesLow (40% accent), awake = `HLColor.statusWarn`
    /// (the awake stage is the only clinically-meaningful stage signal — a
    /// long awake band reads as fragmented sleep, so it keeps its warning hue).
    /// Pre-T2-2 used a four-colour rainbow (purpleDeep/metricBP=pink/cyan/
    /// statusWarn=yellow) — that's now collapsed to the accent-ramp +
    /// warning-only-on-awake pattern.
    private func stagesStrip(stages: StagesBreakdown) -> some View {
        let total = stages.total
        return GeometryReader { proxy in
            HStack(spacing: HLSpace.hair) {
                segment(width: proxy.size.width * CGFloat(stages.deep / total), color: HLChartTints.series)
                segment(width: proxy.size.width * CGFloat(stages.rem / total), color: HLChartTints.seriesMid)
                segment(width: proxy.size.width * CGFloat(stages.core / total), color: HLChartTints.seriesLow)
                segment(width: proxy.size.width * CGFloat(stages.awake / total), color: HLColor.statusWarn)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 8)
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width))
    }

    private func stagesLegend(stages: StagesBreakdown) -> some View {
        // swiftlint:disable:next large_tuple
        let entries: [(LocalizedStringResource, Color, Double)] = [
            (LocalizedStringResource("sleep.stage.deep"), HLChartTints.series, stages.deep),
            (LocalizedStringResource("sleep.stage.rem"), HLChartTints.seriesMid, stages.rem),
            (LocalizedStringResource("sleep.stage.core"), HLChartTints.seriesLow, stages.core),
            (LocalizedStringResource("sleep.stage.awake"), HLColor.statusWarn, stages.awake)
        ]
        return HStack(spacing: HLSpace.sm) {
            ForEach(entries.indices, id: \.self) { idx in
                let entry = entries[idx]
                HStack(spacing: HLSpace.xs) {
                    Circle()
                        .fill(entry.1)
                        .frame(width: 6, height: 6)
                    Text(entry.0)
                        .font(.hlCaption2.weight(.medium))
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    private var combinedLabel: Text {
        let title = String(localized: MetricKind.sleep.descriptor.title)
        let trend: String? = switch metric.dashboardTrend {
        case .up: String(localized: "Trend rising")
        case .down: String(localized: "Trend falling")
        case .flat: String(localized: "Trend stable")
        case .unknown: nil
        }
        if let stages, stages.total > 0 {
            let stageDescription = String(
                localized:
                "\(title) letzte Nacht: \(metric.formattedPrimary()). Tief \(Int(stages.deep)) Minuten, REM \(Int(stages.rem)), Kern \(Int(stages.core)), wach \(Int(stages.awake))."
            )
            return Text([stageDescription, trend].compactMap { $0 }.joined(separator: " "))
        }
        let valueDescription = "\(title): \(metric.formattedPrimary())"
        return Text([valueDescription, trend].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Previews

#Preview("Sleep — with stages") {
    let metric = DashboardMetric(
        id: "sleep",
        kind: .sleep,
        title: "Sleep",
        latestValue: 7.5,
        secondaryValue: nil,
        unit: "h",
        trend: .flat,
        sparkline: [7.0, 7.25, 7.5, 7.0, 7.75, 7.5, 7.5],
        updatedAt: Date()
    )
    SleepCompositeTile(
        metric: metric,
        stages: .init(core: 240, rem: 90, deep: 60, awake: 10)
    )
    .padding()
    .hlScreenBackground()
}

#Preview("Sleep — no stages (fallback)") {
    let metric = DashboardMetric(
        id: "sleep",
        kind: .sleep,
        title: "Sleep",
        latestValue: 7.5,
        secondaryValue: nil,
        unit: "h",
        trend: .flat,
        sparkline: [7.0, 7.25, 7.5, 7.0, 7.75, 7.5, 7.5],
        updatedAt: Date()
    )
    SleepCompositeTile(metric: metric, stages: nil)
        .padding()
        .hlScreenBackground()
}
