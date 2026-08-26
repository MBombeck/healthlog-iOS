import Accessibility
import Foundation
import SwiftUI

/// Reusable builders for `AXChartDescriptor` instances. Every chart we ship in
/// v0.4.0 is contractually required to expose a chart descriptor (PROJECT_GUIDE.md
/// + design-audit.md §Befund 3). This file consolidates the boilerplate so
/// downstream charts (Bravo dashboard tiles, Charlie ChartDetailScreen
/// rebuild, Delta GLP-1 PK chart, Golf correlation scatters) get a one-call
/// path to a valid descriptor.
///
/// **Relationship to `ChartsAccessibility.swift`:**
/// `ChartsAccessibility` is the *measurement-series-specific* descriptor
/// builder (handles BP's two-series special case + locale-aware date labels).
/// This file is the *generic* builder for charts that DON'T fit the measurement-
/// series shape — emoji-axis Mood charts, qualitative PK curves with a
/// unit-less Y axis, scatter plots, etc. The two coexist; pick the
/// closer-fit helper at the call-site.
public enum HLChartAX {
    // MARK: - Line / point chart (single series)

    /// Builds a descriptor for a line or point chart with one continuous series.
    ///
    /// - Parameters:
    ///   - title: chart title (already localized).
    ///   - summary: one-sentence summary (already localized). VoiceOver speaks this
    ///     as the chart's introduction.
    ///   - xAxisTitle: localized X-axis label (e.g. "Datum" / "Date").
    ///   - yAxisTitle: localized Y-axis label (e.g. "Stimmung" / "Mood").
    ///   - points: `(x, y, xLabel)` triples — `xLabel` is what VoiceOver speaks
    ///     for that point's x position (so dates can be human-formatted).
    ///   - yValueLabel: closure mapping a y value to its spoken label
    ///     (e.g. emoji + word for Mood, raw number for vitals).
    public static func singleSeries(
        title: String,
        summary: String,
        xAxisTitle: String,
        yAxisTitle: String,
        seriesName: String,
        points: [(x: Double, y: Double, xLabel: String)],
        yValueLabel: @escaping (Double) -> String = { String(Int($0)) }
    ) -> AXChartDescriptor {
        // Guard the axis ranges against degenerate inputs:
        //  - empty series → fixed 0…1 placeholder so AXNumericDataAxisDescriptor
        //    doesn't trip its NaN/Int-conversion sanity check internally
        //  - single point / all-equal values → widen the range by 1 so
        //    `lower < upper` (Apple's runtime rejects lower == upper).
        let xValues = points.map(\.x)
        let yValues = points.map(\.y)
        let xLowerRaw = xValues.min() ?? 0
        let xUpperRaw = xValues.max() ?? 1
        let xLower = xLowerRaw
        let xUpper = xUpperRaw > xLowerRaw ? xUpperRaw : xLowerRaw + 1
        let yLowerRaw = yValues.min() ?? 0
        let yUpperRaw = yValues.max() ?? 1
        let yLower = yLowerRaw
        let yUpper = yUpperRaw > yLowerRaw ? yUpperRaw : yLowerRaw + 1

        // Index-keyed lookup for the x value descriptor — keeps VoiceOver's
        // spoken label aligned with the visible date even when x is a numeric
        // index rather than a Date.
        let xLabels = points.map(\.xLabel)

        let xAxis = AXNumericDataAxisDescriptor(
            title: xAxisTitle,
            range: xLower ... xUpper,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                let idx = Int(value.rounded())
                guard xLabels.indices.contains(idx) else { return "" }
                return xLabels[idx]
            }
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: yAxisTitle,
            range: yLower ... yUpper,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                return yValueLabel(value)
            }
        )

        let series = AXDataSeriesDescriptor(
            name: seriesName,
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.x, y: $0.y) }
        )

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    // MARK: - Multi-series chart (e.g. correlation scatter, BP-style overlays)

    /// Multi-series descriptor — for scatters with two metrics, overlay charts,
    /// or any case where VoiceOver users should be able to rotor between series.
    public static func multiSeries(
        title: String,
        summary: String,
        xAxisTitle: String,
        yAxisTitle: String,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        series: [(name: String, points: [(x: Double, y: Double)], continuous: Bool)],
        xValueLabel: @escaping (Double) -> String = { HLNumberFormat.decimal($0, fractionDigits: 1) },
        yValueLabel: @escaping (Double) -> String = { HLNumberFormat.decimal($0, fractionDigits: 1) }
    ) -> AXChartDescriptor {
        // Same widen-on-equal guard as singleSeries.
        let xUpper = xRange.upperBound > xRange.lowerBound
            ? xRange.upperBound : xRange.lowerBound + 1
        let yUpper = yRange.upperBound > yRange.lowerBound
            ? yRange.upperBound : yRange.lowerBound + 1
        let xAxis = AXNumericDataAxisDescriptor(
            title: xAxisTitle,
            range: xRange.lowerBound ... xUpper,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                return xValueLabel(value)
            }
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: yAxisTitle,
            range: yRange.lowerBound ... yUpper,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                return yValueLabel(value)
            }
        )

        let descriptors = series.map { s in
            AXDataSeriesDescriptor(
                name: s.name,
                isContinuous: s.continuous,
                dataPoints: s.points.map { AXDataPoint(x: $0.x, y: $0.y) }
            )
        }

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: descriptors
        )
    }
}

/// `AXChartDescriptorRepresentable` wrapper for plugging an `AXChartDescriptor`
/// into a SwiftUI `.accessibilityChartDescriptor(_:)` modifier without writing
/// a private representable per chart site.
///
/// Mirrors the in-tree `ChartDescriptor` pattern at
/// `ChartDetailScreen.swift:323-332` — descriptor is built at view-construction
/// time on the main actor (every SwiftUI body call is main-actor-isolated),
/// then handed to UIKit's accessibility runtime via the representable.
///
/// **Usage:**
/// ```swift
/// let descriptor = HLChartAX.singleSeries(...)
/// Chart(entries) { … }
///   .accessibilityChartDescriptor(HLChartDescriptor(descriptor))
/// ```
public struct HLChartDescriptor: AXChartDescriptorRepresentable {
    private let descriptor: AXChartDescriptor

    public init(_ descriptor: AXChartDescriptor) {
        self.descriptor = descriptor
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        descriptor
    }

    public func updateChartDescriptor(_: AXChartDescriptor) {}
}
