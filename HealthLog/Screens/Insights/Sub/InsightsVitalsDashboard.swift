import SwiftUI

/// W52 (v0.11 overview rework) — the **Vitals at a glance** block on the
/// Insights overview, the iOS twin of the web `VitalsDashboard`
/// (`src/components/insights/derived/vitals-dashboard.tsx`).
///
/// **Why this exists:** the web overview renders a dedicated vital-signs
/// summary section — the key vitals at a glance, each with its latest value +
/// trend. The iOS overview once folded vitals into the generic target-tile
/// grid (driven by the user's CONFIGURED *targets*, not by the vital
/// SIGNS), so a vital the user tracks but hasn't set a target for never
/// surfaced at a glance. This block closes that gap: it reads the same
/// `DashboardSummary.metrics` the dashboard tiles already read (NO new server
/// contract) and renders one compact tile per available vital sign.
///
/// **Web parity contract (`SECTION_VITALS`):** the web charts resting HR / HRV
/// / respiratory rate / SpO₂ / body temperature / blood glucose / weight. This
/// block mirrors that set in the same order, dropping any vital the user has no
/// reading for. Each tile = the metric icon + label, the latest value + unit
/// (big mono), the monochrome `TrendChip` (direction-only, polarity-aware), and
/// an inline `HLSparkline` of the server's daily-rollup series — exactly the
/// grammar of the web `SparklineDeltaTile`.
///
/// **What iOS does NOT mirror (deferred — documented in the W52 report):** the
/// web tiles also carry DERIVED re-frames (personal-typical-range band,
/// cardio-fitness age, vascular-age delta, HRV balance band, BMI category).
/// Those read the web-only `/api/insights/derived` route, which iOS does not
/// consume. Fabricating a "typical range" client-side would be dishonest, so
/// the iOS tile surfaces the honest latest-value + trend + series only. BMI
/// already has its own dedicated overview card.
///
/// **On-device ((A) — survives standalone):** the dashboard summary is part of
/// the W2 read-union, so this block renders in BOTH the paired and standalone
/// paths. It is pure data — no AI gate, no glass, monochrome.
///
/// **Self-suppression:** when no vital sign carries a value the whole section
/// renders NOTHING (no header, no shell, no apologetic empty card) — matching
/// the web's per-tile data-availability gate collapsing the section.
struct InsightsVitalsDashboard: View {
    /// The dashboard summary metrics (kind / latestValue / unit / trend /
    /// sparkline). Sourced from `DashboardStore.summary?.metrics` at the call
    /// site — the same array the dashboard tiles + target grid already read, so
    /// this block costs no extra round-trip.
    let metrics: [DashboardMetric]
    /// W5-1 (v0.12 W5a) — kinds already rendered by another overview surface
    /// (originally the target-tile grid, gone since #115 B7). The overview must show each metric
    /// EXACTLY ONCE: a vital that already lives as a target tile (e.g. weight,
    /// resting-HR) is dropped from this Vitals block so the two surfaces never
    /// double-render the same graphic. Defaults to empty (previews / non-grid
    /// hosts render every vital). The target grid is the canonical home for a
    /// metric the user configured a target for; the Vitals block carries the
    /// rest (HRV / SpO₂ / temp / respiratory / glucose) at-a-glance.
    var excludedKinds: Set<MetricKind> = []
    /// Tap handler — pushes that vital's `InsightsMetricScreen` chart detail.
    /// nil → tiles render but aren't tappable (preview).
    let onSelect: ((MetricKind) -> Void)?
    /// v0.14.1 D — the app container, threaded so each at-a-glance vital tile can
    /// re-attach the "pin to home" long-press affordance the v0.14 redesign
    /// dropped. `nil` (previews / tests) → the modifier is a no-op.
    var container: AppContainer?
    /// 1.5 VERDICTS — the server's verdicts the arrows are coloured from, the
    /// same as on Today (``TileTrendVerdicts``).
    var trendVerdicts: TileTrendVerdicts = .none

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// #115 P2 — weight, temperature and glucose read in the account's unit.
    @Environment(\.unitPreferences) private var unitPreferences

    /// Web `SECTION_VITALS` order, mapped onto the iOS `MetricKind` enum.
    /// `nonisolated` so the pure resolver can read it off the main actor in
    /// unit tests.
    private nonisolated static let vitalOrder: [MetricKind] = [
        .restingHeartRate,
        .hrv,
        .respiratoryRate,
        .spo2,
        .bodyTemperature,
        .glucose,
        .weight
    ]

    var body: some View {
        let tiles = Self.tiles(from: metrics, excluding: excludedKinds, units: unitPreferences, verdicts: trendVerdicts)
        // Self-suppress: no vital with a value → render nothing (calm doctrine).
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // One canonical header (sentence-case, monochrome) — matches the
                // web `insights.derived.vitals.sectionTitle` h2.
                InsightsSectionHeader("Vitals")
                VStack(spacing: HLSpace.sm) {
                    ForEach(tiles) { tile in
                        card(for: tile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.vitals")
        }
    }

    // MARK: - Tile chrome

    @ViewBuilder
    private func card(for tile: VitalTile) -> some View {
        let body = HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: tile.symbol)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(tile.title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    TrendChip(trend: tile.trend, mode: tile.mode)
                    Text(tile.valueText)
                        .font(.hlHeadline)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                if tile.series.count >= 2 {
                    // W6b (v0.12 W5a) — conform to the unified tile grammar
                    // (STANDARDS §7). Task #36 — route through the shared
                    // `HLTileMetricChart` (same `MetricChartContent` engine +
                    // inkGraphite ink as the metric's Insights page) so the
                    // Vitals block reads as the same chart material as the
                    // target-grid tiles below it AND the per-metric detail.
                    HLTileMetricChart(kind: tile.kind, values: tile.series)
                        .frame(height: HLChartStyle.heightCompact)
                }
            }
        }
        if let onSelect {
            Button { onSelect(tile.kind) } label: { body }
                .hlPressable() // QOL-AUDIT H1: press feedback
                // v0.14.1 D — re-attach the pin affordance the redesign dropped:
                // every at-a-glance vital tile is long-press-pinnable to Home.
                .pinToHomeContextMenu(kind: tile.kind, container: container)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(tile.accessibilityLabel))
                .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
                .accessibilityIdentifier("insights.vital.\(tile.kind.rawValue)")
        } else {
            body
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(tile.accessibilityLabel))
        }
    }

    // MARK: - Pure tile resolution

    /// One resolved vital tile. `nonisolated` so the pure resolver below can be
    /// exercised off the main actor in unit tests.
    nonisolated struct VitalTile: Identifiable {
        let kind: MetricKind
        let title: String
        let symbol: String
        let valueText: String
        let trend: TrendIndicator
        /// 1.5 VERDICTS — the server's verdict on this card, or neutral.
        var mode: TrendChip.Mode = .neutral
        let series: [Double]
        let accessibilityLabel: String
        var id: String {
            kind.rawValue
        }
    }

    /// Build the ordered, value-bearing vital tiles from the dashboard metric
    /// pool. A vital with no `latestValue` is dropped (web parity: the tile only
    /// renders when the vital has a reading). `nonisolated static` so the
    /// self-suppress gate is unit-testable without instantiating the view.
    nonisolated static func tiles(
        from metrics: [DashboardMetric],
        excluding excludedKinds: Set<MetricKind> = [],
        units: UnitPreferences = .standard,
        verdicts: TileTrendVerdicts = .none
    ) -> [VitalTile] {
        let byKind = Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        return vitalOrder.compactMap { kind -> VitalTile? in
            // W5-1 — a vital already shown as a configured-target tile is dropped
            // here so the overview renders the metric exactly once.
            guard !excludedKinds.contains(kind) else { return nil }
            guard let metric = byKind[kind], let latest = metric.latestValue else { return nil }
            let descriptor = kind.descriptor
            let title = String(localized: descriptor.title)
            // #115 P2 — the summary value is canonical SI; a converted family
            // reads in the account's unit (the identity branch keeps the
            // summary's own label and the 0…1-dp text).
            let unit = units.transform(for: kind).suffix
                ?? (metric.unit.isEmpty ? String(localized: descriptor.unitLabel) : metric.unit)
            let value = MetricValueFormatter.formatScalar(latest, kind: kind, units: units)
            let valueText = unit.isEmpty ? value : "\(value) \(unit)"
            return VitalTile(
                kind: kind,
                title: title,
                symbol: descriptor.sfSymbol,
                valueText: valueText,
                trend: metric.trend,
                mode: verdicts.mode(for: metric),
                series: metric.sparkline,
                accessibilityLabel: [title, valueText, metric.spokenTrendWithVerdict(verdicts)].compactMap(\.self).joined(separator: ", ")
            )
        }
    }
}
