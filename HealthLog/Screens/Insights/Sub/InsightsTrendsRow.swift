import SwiftUI

/// v0.11 W-C — inline "Trends" mini-chart row on the Insights **overview**, the
/// iOS twin of the web `TrendsRow` (`src/components/insights/trends-row.tsx`).
///
/// **Why this replaces the footer link:** the web overview renders up to three
/// mini charts INLINE — each a small series + a one-sentence annotation —
/// rather than pushing to a separate trends screen. Build 98/99 only offered a
/// footer link (since removed in C2), so the overview felt bare. This brings the
/// glanceable trend strip onto the overview.
///
/// **Web parity contract (`selectTrendCharts`):**
/// - The chart SET is dynamic: it mirrors the briefing's flagged metrics in
///   priority order, deduped on `MetricKind`, capped at 3
///   (`InsightsTrendChartSelector`).
/// - When the briefing is absent / carries no chartable findings, it falls back
///   to the legacy BP / weight / pulse triple, so the row never paints empty.
/// - Each card = a Swift-Charts mini sparkline (`HLSparkline`) + a one-sentence
///   annotation; tapping a card pushes that metric's `ChartDetailScreen`.
///
/// **Charts on-device, sentence from the server (#115 · 1.3):** the charts read
/// from local `measurementsStore.recent`, so the row still renders in BOTH the
/// paired and standalone paths. The one-sentence annotation used to be computed
/// on-device from the first and last point of the series; it now reads the
/// server's 30-day regression direction (`summaries[TYPE].slope30.direction`
/// of the comprehensive digest). No server slope (standalone, offline before
/// the digest landed, a kind the digest does not summarise) → no sentence.
///
/// **Cache-first paint:** while no measurements have resolved yet the row paints
/// shimmer placeholders (`HLSkeleton`) instead of empty cards. It reuses the
/// screen's existing 8-store `.task` fan-out + `isInitialSkeletonVisible` latch —
/// no new top-level skeleton gate. A kind with too few points to chart is
/// dropped (the next selected kind does not back-fill — selection already ran).
///
/// **Monochrome / glass:** each card is a matte `HLCard` (no glass on content);
/// the sparkline uses the single `HLChartTints.series` accent — colour is not
/// signal here, just the chart stroke.
struct InsightsTrendsRow: View {
    /// Pre-selected kinds (priority-ordered, deduped, capped) from
    /// `InsightsTrendChartSelector.select(keyFindings:)`.
    let kinds: [MetricKind]
    /// The local measurement pool the sparklines read from.
    let measurements: [Measurement]
    /// #115 · 1.3 — the comprehensive digest's per-type summaries, source of
    /// the annotation's direction. `nil` → no annotation.
    let digest: ComprehensiveDigest?
    /// True while the screen is still in its cold-launch skeleton window — the
    /// row paints shimmer cards instead of resolving series. Wired from the
    /// screen's `isShowingInitialSkeleton` latch so we never add a second gate.
    let isLoading: Bool
    /// Tap handler — pushes the metric's `ChartDetailScreen`. nil → cards render
    /// but aren't tappable (preview).
    let onSelect: ((MetricKind) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// #115 P2 — the latest value reads in the account's unit.
    @Environment(\.unitPreferences) private var unitPreferences

    /// Window for the overview sparkline — last 30 days keeps the mini chart a
    /// glance, matching the web mini-chart default span. `nonisolated` so the
    /// pure resolver can read it off the main actor.
    private nonisolated static let windowDays = 30

    var body: some View {
        // Resolve each selected kind to a chartable series. A kind with < 2
        // points has no line to draw, so it's dropped (web parity: a slot only
        // paints when it has a series).
        let charts: [Chart] = isLoading
            ? []
            : kinds.compactMap { Self.chart(for: $0, in: measurements, digest: digest, units: unitPreferences) }
        if isLoading {
            section { skeletonGrid }
        } else if !charts.isEmpty {
            section {
                VStack(spacing: HLSpace.sm) {
                    ForEach(charts) { chart in
                        card(for: chart)
                    }
                }
            }
        }
        // Neither loading nor any chartable series → render nothing (calm
        // doctrine; no empty shell).
    }

    // MARK: - Section chrome

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // MED-2/MED-3: one canonical header; subtitle now matches the web
            // (`insights.trendsRow.subtitle`) AND the 30-day window it charts —
            // the old "this week" copy was factually wrong for a 30-day series.
            InsightsSectionHeader(
                "Trends",
                subtitle: "Last 30 days at a glance"
            )
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(reduceMotion ? .identity : .opacity)
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(for chart: Chart) -> some View {
        let body = HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: chart.symbol)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 22)
                    Text(chart.title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    Text(chart.valueText)
                        .font(.hlHeadline)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                // Task #36 — shared `MetricChartContent` engine + inkGraphite
                // ink (same as the metric's Insights detail), not a generic line.
                HLTileMetricChart(kind: chart.kind, values: chart.series)
                    .frame(height: 56)
                if let annotation = chart.annotation {
                    Text(annotation)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let onSelect {
            Button { onSelect(chart.kind) } label: { body }
                .hlPressable() // QOL-AUDIT H1: press feedback
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(chart.accessibilityLabel))
                .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
                .accessibilityIdentifier("insights.trend.\(chart.kind.rawValue)")
        } else {
            body
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(chart.accessibilityLabel))
        }
    }

    private var skeletonGrid: some View {
        VStack(spacing: HLSpace.sm) {
            ForEach(0 ..< min(2, max(1, kinds.count)), id: \.self) { _ in
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSkeleton(.capsule, width: 140, height: 16)
                        HLSkeleton(.rect, height: 56, cornerRadius: 10)
                        HLSkeleton(.capsule, width: 200, height: 12)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(String(localized: "Loading trends")))
    }

    // MARK: - Pure series resolution

    /// One resolved mini-chart slot. `nonisolated` so the pure resolver below
    /// can be exercised off the main actor in unit tests.
    nonisolated struct Chart: Identifiable {
        let kind: MetricKind
        let title: String
        let symbol: String
        let valueText: String
        let series: [Double]
        let annotation: String?
        let accessibilityLabel: String
        var id: String {
            kind.rawValue
        }
    }

    /// Build a chart slot for `kind` from the measurement pool, or `nil` when
    /// there aren't enough points (< 2) to draw a meaningful line.
    nonisolated static func chart(
        for kind: MetricKind,
        in measurements: [Measurement],
        digest: ComprehensiveDigest? = nil,
        units: UnitPreferences = .standard
    ) -> Chart? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())
            ?? Date.distantPast
        let rows = measurements
            .filter { $0.kind == kind && $0.recordedAt >= cutoff }
            .sorted { $0.recordedAt < $1.recordedAt }
        guard rows.count >= 2 else { return nil }
        let series = rows.map(\.primaryValue)
        let descriptor = kind.descriptor
        let title = String(localized: descriptor.title)
        let unit = units.transform(for: kind).suffix ?? String(localized: descriptor.unitLabel)
        let latestRow = rows.last
        let valueText = formattedValue(latestRow, kind: kind, unit: unit, units: units)
        let summary = kind.availabilitySummaryKey.flatMap { digest?.summaries?[$0] }
        let annotation = annotation(serverSlope: summary?.slope30, title: title)
        let axLabel = annotation.map { "\(title), \(valueText). \($0)" } ?? "\(title), \(valueText)"
        return Chart(
            kind: kind,
            title: title,
            symbol: descriptor.sfSymbol,
            valueText: valueText,
            series: series,
            annotation: annotation,
            accessibilityLabel: axLabel
        )
    }

    /// Latest-value string. BP renders the systolic/diastolic compound; every
    /// other kind renders the primary scalar + unit.
    private nonisolated static func formattedValue(
        _ row: Measurement?,
        kind: MetricKind,
        unit: String,
        units: UnitPreferences
    ) -> String {
        guard let row else { return "—" }
        if case let .bloodPressure(sys, dia) = row.value {
            // SWEEP (W-CRASHGUARD) — `Measurement` BP values decode unsanitized
            // (`MeasurementWireDTO.value` is a raw server `Double`); `Int()` of a
            // non-finite OR out-of-range value traps. Route both operands through
            // `Int(safeServer:)` → em-dash placeholder.
            guard let s = Int(safeServer: sys), let d = Int(safeServer: dia) else { return "—" }
            return "\(s)/\(d) \(unit)".trimmingCharacters(in: .whitespaces)
        }
        // #115 P2 — list rows are canonical SI; convert through the one formatter.
        let value = MetricValueFormatter.formatScalar(row.primaryValue, kind: kind, units: units)
        return unit.isEmpty ? value : "\(value) \(unit)"
    }

    /// One-sentence annotation from the server's 30-day regression direction
    /// (`TrendSlope.direction`; the server calls a slope `stable` when
    /// |slope| < 0.01/day). `nil` when the server gave no direction — the card
    /// then shows no sentence rather than one derived from two chart points.
    nonisolated static func annotation(serverSlope: TrendSlope?, title: String) -> String? {
        switch serverSlope?.direction {
        case .up: String(localized: "insights.trendsRow.annotation.up \(title)")
        case .down: String(localized: "insights.trendsRow.annotation.down \(title)")
        case .stable: String(localized: "insights.trendsRow.annotation.stable \(title)")
        case .unknown, nil: nil
        }
    }
}
