import Charts
import SwiftUI

/// **The two axes of every chart with axes.**
///
/// The value axis stands on the leading edge, as on the reference metric
/// page: a hairline grid in the chart grid tokens, the labels in caption type
/// and secondary ink, the unit level above the axis where it reads like any
/// other word ("kg", "h"), never turned on its side. The date axis is
/// ``HLChartDateAxis``: at most four labels, none cut at the plot's edge.
///
/// A chart takes both with one call:
/// ```swift
/// Chart { … }
///     .hlChartAxes(dates: points.map(\.at), unit: "bpm")
/// ```
/// A chart whose values are words (the mood scale) passes `label:`.
enum HLChartAxis {
    /// The side the value axis stands on. One side for every chart, so the
    /// eye finds the numbers in the same place on each page.
    static var valuePosition: AxisMarkPosition {
        .leading
    }

    /// Where the unit of the value axis stands.
    enum UnitPlacement: Equatable {
        /// Level, above the top of the value axis.
        case aboveAxis
        /// Turned along the axis.
        case alongAxis
    }

    /// One place for every chart: level above the axis, readable at a
    /// glance.
    static let unitPlacement: UnitPlacement = .aboveAxis

    /// Gap between the unit and the top of the plot. The top value label is
    /// centred on the plot's upper edge and reaches half a line above it, so
    /// the unit keeps clear of it.
    static let unitGap: CGFloat = HLSpace.md

    /// The value ticks a chart gets when it names none: about five, three
    /// from the first accessibility size on, where the larger labels would
    /// otherwise run into each other.
    static func automaticValues(at typeSize: DynamicTypeSize) -> AxisMarkValues {
        typeSize.isAccessibilitySize ? .automatic(desiredCount: accessibilityTickCount) : .automatic
    }

    /// Ticks on the value axis from the first accessibility size on.
    static let accessibilityTickCount = 3

    /// The value axis: leading, hairline grid, caption labels. Numbers read
    /// through ``HLValueFormat`` unless the chart names its own words.
    /// Without `values` the axis thins itself out at `typeSize`
    /// (``automaticValues(at:)``); ``SwiftUI/View/hlChartAxes(dates:unit:values:label:)``
    /// and ``SwiftUI/View/hlChartValueAxis(_:label:)`` pass the reader's size.
    static func values(
        _ values: AxisMarkValues? = nil,
        at typeSize: DynamicTypeSize = .large,
        label: ((Double) -> String)? = nil
    ) -> some AxisContent {
        AxisMarks(position: valuePosition, values: values ?? automaticValues(at: typeSize)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: HLChartGrid.lineWidth))
                .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
            AxisTick()
                .foregroundStyle(HLText.tertiary)
            AxisValueLabel {
                Text(verbatim: valueLabel(value.as(Double.self), label: label))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    /// The value axis at fixed ticks, for a scale of words (the mood levels):
    /// a tick only where a word stands, never a bare one between.
    static func values(at ticks: [Double], label: ((Double) -> String)? = nil) -> some AxisContent {
        AxisMarks(position: valuePosition, values: ticks) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: HLChartGrid.lineWidth))
                .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
            AxisTick()
                .foregroundStyle(HLText.tertiary)
            AxisValueLabel {
                Text(verbatim: valueLabel(value.as(Double.self), label: label))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    /// The words under one value tick: the chart's own, or the number.
    static func valueLabel(_ number: Double?, label: ((Double) -> String)?) -> String {
        guard let number else { return "" }
        return label?(number) ?? HLValueFormat.number(number, fractionDigits: 0 ... 1)
    }

    /// The date axis for a chart plotting `dates` (``HLChartDateAxis``).
    static func dates(_ dates: [Date]) -> some AxisContent {
        HLChartDateAxis.marks(for: dates)
    }
}

/// The unit above the value axis, in the caption face.
struct HLChartUnitLabel: View {
    let unit: String

    var body: some View {
        Text(verbatim: unit)
            .font(.hlCaption.weight(.semibold))
            .foregroundStyle(HLText.secondary)
    }
}

extension View {
    /// Both axes of a time-series chart: values on the leading edge with the
    /// unit level above them, dates underneath. An empty `unit` draws no unit.
    /// Without `values` the value axis thins itself out at the accessibility
    /// sizes.
    func hlChartAxes(
        dates: [Date],
        unit: String,
        values: AxisMarkValues? = nil,
        label: ((Double) -> String)? = nil
    ) -> some View {
        modifier(HLChartValueAxis(values: values, label: label))
            .chartXAxis { HLChartAxis.dates(dates) }
            .hlChartUnit(unit)
    }

    /// Both axes, the value axis at fixed `ticks` (``HLChartAxis/values(at:label:)``).
    func hlChartAxes(dates: [Date], unit: String, ticks: [Double], label: ((Double) -> String)? = nil) -> some View {
        chartYAxis { HLChartAxis.values(at: ticks, label: label) }
            .chartXAxis { HLChartAxis.dates(dates) }
            .hlChartUnit(unit)
    }

    /// The value axis alone, for a chart that draws its own date axis. It
    /// thins itself out at the accessibility sizes unless `values` is named.
    func hlChartValueAxis(_ values: AxisMarkValues? = nil, label: ((Double) -> String)? = nil) -> some View {
        modifier(HLChartValueAxis(values: values, label: label))
    }

    /// The unit of the value axis, level above it. For a chart that draws
    /// its own axes; ``hlChartAxes(dates:unit:values:label:)`` brings it.
    func hlChartUnit(_ unit: String) -> some View {
        chartYAxisLabel(position: .top, alignment: .leading, spacing: HLChartAxis.unitGap) {
            if !unit.isEmpty {
                HLChartUnitLabel(unit: unit)
            }
        }
    }
}

/// Reads the reader's text size for the value axis.
private struct HLChartValueAxis: ViewModifier {
    let values: AxisMarkValues?
    let label: ((Double) -> String)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.chartYAxis { HLChartAxis.values(values, at: dynamicTypeSize, label: label) }
    }
}
