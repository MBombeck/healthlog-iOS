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
/// **API contract (preserve back-compat for Bravo's dashboard tiles + MoodScreen):**
/// `init(values:mode:tint:smoothing:)` — `values` is the y-series (x is index),
/// `mode` picks line/area/bar, `tint` drives the foreground color,
/// `smoothing` requests `catmullRom` interpolation (vs straight segments).
///
/// **Design notes:**
/// - At sparkline scale (≤ ~80pt height) axis chrome would dominate — `.chartXAxis(.hidden)`
///   and `.chartYAxis(.hidden)` are non-negotiable.
/// - **Default mode is `.line`** (web-parity, R2 §Primitive #3). The web reference
///   uses pure `<Line strokeWidth={1.5}>` for sparklines; Apple Health and
///   Withings dashboard mini-charts mirror this restraint. The `.area` case has
///   been removed in Theme-2.0 (T2-2) — Tonal-Mono restraint kills the area-
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

    public init(
        values: [Double],
        mode: Mode = .line,
        tint: Color = HLChartTints.series,
        smoothing: Bool = true
    ) {
        self.values = values
        self.mode = mode
        self.tint = tint
        self.smoothing = smoothing
    }

    public var body: some View {
        chart
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Snug y-domain — guard the degenerate min == max case so the line
            // doesn't collapse to the top/bottom edge. Adds 5% padding above + below.
            .chartYScale(domain: yDomain)
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
                .interpolationMethod(smoothing ? .catmullRom : .linear)
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

    /// Pad y-domain by 5% so the line never grazes the top/bottom edge.
    /// Degenerate case (all-equal or single value) widens by ±0.5.
    private var yDomain: ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0 ... 1 }
        guard hi > lo else { return lo - 0.5 ... lo + 0.5 }
        let pad = (hi - lo) * 0.05
        return (lo - pad) ... (hi + pad)
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
                return "\(values.count) Werte, \(trend) von \(format(first)) auf \(format(last))"
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
            .frame(height: 60)
        HLSparkline(values: [120, 122, 118, 130, 126, 124, 122])
            .frame(height: 60)
        HLSparkline(values: [4500, 7200, 8100, 5400, 9300, 11200, 6800], mode: .bar)
            .frame(height: 60)
        // Edge: single value → hairline
        HLSparkline(values: [3])
            .frame(height: 60)
    }
    .padding()
    .background(HLSurface.primary)
}
