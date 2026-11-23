import Accessibility
import Charts
import SwiftUI

/// Compact sparkline rendered with Apple's Charts framework.
///
/// **Why this exists (v0.4.0 charts marathon — Stream Charlie):**
/// The previous implementation used a hand-rolled `Canvas { … }` path with
/// `GraphicsContext.drawPath(...)` calls (good performance for tiny renders,
/// but no accessibility integration, no animation hooks, no theming consistency
/// with the rest of the chart library). v0.4.0 raises the chart bar across the
/// app to "Apple-Health-tier" — every visualization shares the same Swift
/// Charts substrate so AXChartDescriptor, axis styling, marks, and animation
/// stay coherent screen-to-screen.
///
/// **API contract:** `init(values:mode:smoothing:)` — `values` is the y-series
/// (x is index), `mode` picks line or bar, `smoothing` draws the same curve
/// as the metric charts (monotone, which never overshoots a measured point)
/// instead of straight segments. `minimumSpan` keeps a calm series calm:
/// the value axis spans at least that much, the data centred in it. Every
/// sparkline has the same tint, ``defaultTint``; the `tint:`
/// argument only remains for call sites that have not switched yet, and the
/// lint rule `hl_sparkline_own_tint` lists them.
///
/// **Design notes:**
/// - At sparkline scale (≤ ~80pt height) axis chrome would dominate — `.chartXAxis(.hidden)`
///   and `.chartYAxis(.hidden)` are non-negotiable.
/// - **Default mode is `.line`** (web-parity, R2 §Primitive #3). The web reference
///   uses pure `<Line strokeWidth={1.5}>` for sparklines; Apple Health and
///   Withings dashboard mini-charts mirror this restraint. The `.area` case has
///   been removed in Theme-2.0 — Tonal-Mono restraint kills the area-
///   gradient option permanently; pure line + bar are the only modes.
/// - Animation: bars + line draw-in are spring-animated (`HLMotion.spring`) when
///   the values array changes — reduce-motion swaps to an instant transition via
///   `.hlAnimation`. This matches Apple Health's quick "bloom" on tile-load.
/// - AccessibilityChartDescriptor: built via `HLChartAX.singleSeries` so VoiceOver
///   announces the index + value pair instead of a generic "image".
public struct HLSparkline: View {
    public enum Mode: Sendable {
        case line
        case bar
    }

    private let values: [Double]
    private let mode: Mode
    private let tint: Color
    private let smoothing: Bool
    private let minimumSpan: Double?

    /// The one tint of every sparkline: a step quieter than a detail chart's
    /// line, because a sparkline sits beside a number that carries the card.
    public static var defaultTint: Color {
        HLChartTints.seriesMid
    }

    /// The curve between two points, the one the metric charts draw. A
    /// monotone curve stays between its neighbours, so it never shows a peak
    /// or a dip that was not measured.
    nonisolated static func interpolation(smoothing: Bool) -> InterpolationMethod {
        smoothing ? .monotone : .linear
    }

    /// The value axis of a series: 5 % room above and below, at least
    /// `minimumSpan` tall with the data in its middle, never below zero for
    /// a series that is not. Pure, so the rule is tested without a chart.
    nonisolated static func yDomain(values: [Double], minimumSpan: Double? = nil) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return 0 ... 1 }
        let pad = (hi - lo) * 0.05
        var lower = lo - pad
        var upper = hi + pad
        let least = max(minimumSpan ?? 0, upper > lower ? 0 : 1)
        if upper - lower < least {
            let middle = (lo + hi) / 2
            lower = middle - least / 2
            upper = middle + least / 2
            if lo >= 0, lower < 0 {
                upper -= lower
                lower = 0
            }
        }
        return lower ... upper
    }

    public init(
        values: [Double],
        mode: Mode = .line,
        tint: Color = HLSparkline.defaultTint,
        smoothing: Bool = true,
        minimumSpan: Double? = nil
    ) {
        self.values = values
        self.mode = mode
        self.tint = tint
        self.smoothing = smoothing
        self.minimumSpan = minimumSpan
    }

    public var body: some View {
        chart
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Snug y-domain — guard the degenerate min == max case so the line
            // doesn't collapse to the top/bottom edge. Adds 5% padding above + below.
            .chartYScale(domain: Self.yDomain(values: values, minimumSpan: minimumSpan))
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary)
            .accessibilityChartDescriptor(HLChartDescriptor(makeAXDescriptor()))
            .hlAnimation(HLMotion.spring, value: values)
    }

    // MARK: - Chart body (mode-driven marks)

    @ChartContentBuilder
    private var chartBody: some ChartContent {
        switch mode {
        case .line:
            ForEach(indexed) { entry in
                LineMark(
                    x: .value(String(localized: "chart.axis.index"), entry.x),
                    y: .value(String(localized: "Value"), entry.y)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(
                    lineWidth: HLChartStyle.lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .interpolationMethod(Self.interpolation(smoothing: smoothing))
            }
        case .bar:
            ForEach(indexed) { entry in
                BarMark(
                    x: .value(String(localized: "chart.axis.index"), entry.x),
                    y: .value(String(localized: "Value"), entry.y)
                )
                .foregroundStyle(tint)
                .clipShape(.rect(cornerRadius: 2))
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if values.count < 2 {
            // Single-point or empty: render a hairline so the tile still has
            // visual continuity (no jarring empty-rectangle), and the
            // descriptor below describes the no-data state to VoiceOver.
            emptyHairline
        } else {
            Chart { chartBody }
        }
    }

    /// Hairline placeholder when the series can't render meaningfully (≤1 point).
    /// Mirrors the prior `drawEmpty` behavior — a thin centered tertiary-color line.
    private var emptyHairline: some View {
        GeometryReader { proxy in
            Path { path in
                let mid = proxy.size.height / 2
                path.move(to: CGPoint(x: 0, y: mid))
                path.addLine(to: CGPoint(x: proxy.size.width, y: mid))
            }
            .stroke(HLText.tertiary, lineWidth: 1)
        }
    }

    // MARK: - Derived

    private struct Indexed: Identifiable, Hashable {
        let x: Int
        let y: Double
        var id: Int {
            x
        }
    }

    private var indexed: [Indexed] {
        values.enumerated().map { Indexed(x: $0.offset, y: $0.element) }
    }

    // MARK: - Accessibility

    private var accessibilitySummary: Text {
        guard let first = values.first, let last = values.last else {
            return Text(String(localized: "Sparkline without data"))
        }
        let trend = last >= first ? String(localized: "rising") : String(localized: "falling")
        let countLabel = String(localized: "\(values.count) values")
        return Text("Sparkline, \(countLabel), \(trend) from \(format(first)) to \(format(last))")
    }

    private func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    private func makeAXDescriptor() -> AXChartDescriptor {
        let points = values.enumerated().map { idx, v in
            (x: Double(idx), y: v, xLabel: String(localized: "chart.axis.point \(idx + 1)"))
        }
        let summary: String = {
            if values.isEmpty {
                return String(localized: "No data")
            }
            if let first = values.first, let last = values.last {
                let trend = last >= first ? String(localized: "rising") : String(localized: "falling")
                return String(localized: "chart.sparkline.summary \(values.count) \(trend) \(format(first)) \(format(last))")
            }
            return String(localized: "chart.series.sparkline")
        }()
        return HLChartAX.singleSeries(
            title: String(localized: "chart.series.sparkline"),
            summary: summary,
            xAxisTitle: String(localized: "chart.axis.index"),
            yAxisTitle: String(localized: "Value"),
            seriesName: String(localized: "Values"),
            points: points,
            yValueLabel: { v in v.formatted(.number.precision(.fractionLength(0 ... 1))) }
        )
    }
}

#Preview("HLSparkline — Apple Charts") {
    VStack(spacing: HLSpace.lg) {
        // Default `.line` mode — Theme-2.0 single accent via HLChartTints.series.
        HLSparkline(values: [70, 71.2, 70.8, 70.1, 69.5, 69.8, 69.2])
            .frame(height: HLChartStyle.heightCompact)
        HLSparkline(values: [120, 122, 118, 130, 126, 124, 122])
            .frame(height: HLChartStyle.heightCompact)
        HLSparkline(values: [4500, 7200, 8100, 5400, 9300, 11200, 6800], mode: .bar)
            .frame(height: HLChartStyle.heightCompact)
        // Edge: single value → hairline
        HLSparkline(values: [3])
            .frame(height: HLChartStyle.heightCompact)
    }
    .padding()
    .background(HLSurface.primary)
}
