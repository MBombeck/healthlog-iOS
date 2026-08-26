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
/// **On-device ((A) — survives standalone):** the charts read from local
/// `measurementsStore.recent` and the annotation is computed on-device from the
/// series direction, so this row renders in BOTH the paired and standalone
/// paths (unlike the server-derived correlations row).
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
    /// True while the screen is still in its cold-launch skeleton window — the
    /// row paints shimmer cards instead of resolving series. Wired from the
    /// screen's `isShowingInitialSkeleton` latch so we never add a second gate.
    let isLoading: Bool
    /// Tap handler — pushes the metric's `ChartDetailScreen`. nil → cards render
    /// but aren't tappable (preview).
    let onSelect: ((MetricKind) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            : kinds.compactMap { Self.chart(for: $0, in: measurements) }
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
                Text(chart.annotation)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        let annotation: String
        let accessibilityLabel: String
        var id: String {
            kind.rawValue
        }
    }

    /// Build a chart slot for `kind` from the measurement pool, or `nil` when
    /// there aren't enough points (< 2) to draw a meaningful line.
    nonisolated static func chart(for kind: MetricKind, in measurements: [Measurement]) -> Chart? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())
            ?? Date.distantPast
        let rows = measurements
            .filter { $0.kind == kind && $0.recordedAt >= cutoff }
            .sorted { $0.recordedAt < $1.recordedAt }
        guard rows.count >= 2 else { return nil }
        let series = rows.map(\.primaryValue)
        let descriptor = kind.descriptor
        let title = String(localized: descriptor.title)
        let unit = String(localized: descriptor.unitLabel)
        let latestRow = rows.last
        let valueText = formattedValue(latestRow, kind: kind, unit: unit)
        let annotation = annotation(for: kind, series: series, title: title)
        let axLabel = "\(title), \(valueText). \(annotation)"
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
    private nonisolated static func formattedValue(_ row: Measurement?, kind: MetricKind, unit: String) -> String {
        guard let row else { return "—" }
        if case let .bloodPressure(sys, dia) = row.value {
            // SWEEP (W-CRASHGUARD) — `Measurement` BP values decode unsanitized
            // (`MeasurementWireDTO.value` is a raw server `Double`); `Int()` of a
            // non-finite OR out-of-range value traps. Route both operands through
            // `Int(safeServer:)` → em-dash placeholder.
            guard let s = Int(safeServer: sys), let d = Int(safeServer: dia) else { return "—" }
            return "\(s)/\(d) \(unit)".trimmingCharacters(in: .whitespaces)
        }
        let value = row.primaryValue.formatted(.number.precision(.fractionLength(0 ... 1)))
        return unit.isEmpty ? value : "\(value) \(unit)"
    }

    /// On-device one-sentence annotation — direction + magnitude over the
    /// window. Pure + signal-free copy (no LLM); survives standalone. Mirrors
    /// the web's per-card caption slot without needing a server annotation.
    nonisolated static func annotation(for kind: MetricKind, series: [Double], title: String) -> String {
        guard let first = series.first, let last = series.last, series.count >= 2 else {
            return String(localized: "Not enough data for a trend yet.")
        }
        let delta = last - first
        let base = abs(first) > 0.0001 ? abs(first) : 1
        let pct = abs(delta) / base * 100
        if pct < 1.5 {
            return String(localized: "\(title) has held steady over the last weeks.")
        }
        let magnitude = pct.formatted(.number.precision(.fractionLength(0)))
        if delta > 0 {
            return String(localized: "\(title) trended up about \(magnitude)% recently.")
        }
        return String(localized: "\(title) trended down about \(magnitude)% recently.")
    }
}
