import Charts
import SwiftUI

/// **Shared history line chart — extracted from the mental-health instrument
/// detail (`MentalHealthHistoryChart`) so mental-health and the Vorsorge detail
/// sheet share ONE chart source instead of a parallel bespoke implementation.**
///
/// A calm Swift-Charts line + point series: the most-recent point renders larger
/// and (optionally) annotated, the rest smaller. The Y-domain is caller-supplied
/// — a fixed band (screening: `0…maxScore`) or `nil` for an auto axis (a metric's
/// own value range). Both axis value labels and the accessibility phrasing are
/// injected so each host keeps its own localized wording while sharing the exact
/// same chart chrome (`HLAccent.userBrandTint`, 2-pt line, 55/35-pt symbols,
/// `AxisMarks(.leading)`, 220-pt height, `.ignore`d element with a summarised
/// value).
struct HistoryLineChart: View {
    /// One dated observation. `value` is already the plotted scalar (a screening
    /// sum as `Double`, or a metric's `primaryValue`).
    struct Point: Identifiable, Equatable {
        let id: String
        let date: Date
        let value: Double
    }

    let title: LocalizedStringKey
    let points: [Point]
    /// Fixed Y-domain (screening `0…maxScore`), or `nil` for an auto axis (metric).
    let yDomain: ClosedRange<Double>?
    /// Localized chart-mark axis value labels.
    let xValueLabel: String
    let yValueLabel: String
    /// Annotation text for the MOST-RECENT point only; `nil` ⇒ no annotation.
    let annotation: (Point) -> String?
    /// Per-point phrase, joined into the chart's summarised accessibility value.
    let accessibilityDescription: (Point) -> String

    /// **Pure, `nonisolated`, testable — the point ordering + selection.**
    ///
    /// Oldest → newest (the chart draws left = older → right = newest), so the
    /// most-recent point is `ordered(_:).last` — the one that gets the larger
    /// symbol and the annotation. Kept out of the view so the sort + "last point"
    /// contract can be pinned without a chart host.
    nonisolated static func ordered(_ points: [Point]) -> [Point] {
        points.sorted { $0.date < $1.date }
    }

    private var orderedPoints: [Point] {
        Self.ordered(points)
    }

    var body: some View {
        if !orderedPoints.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(title)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)

                chart
                    .frame(height: 220)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(accessibilityValue))
            }
        }
    }

    private var chart: some View {
        let ordered = orderedPoints
        let lastID = ordered.last?.id
        return Chart(ordered) { point in
            LineMark(
                x: .value(xValueLabel, point.date),
                y: .value(yValueLabel, point.value)
            )
            .foregroundStyle(HLAccent.userBrandTint)
            .lineStyle(StrokeStyle(lineWidth: 2))

            PointMark(
                x: .value(xValueLabel, point.date),
                y: .value(yValueLabel, point.value)
            )
            .foregroundStyle(HLAccent.userBrandTint)
            .symbolSize(point.id == lastID ? 55 : 35)
            .annotation(position: .top, alignment: .trailing) {
                if point.id == lastID, let text = annotation(point) {
                    Text(text)
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .modifier(YDomainModifier(domain: yDomain))
        .chartYAxis { AxisMarks(position: .leading) }
    }

    private var accessibilityValue: String {
        orderedPoints.map(accessibilityDescription).joined(separator: "; ")
    }

    /// Applies a fixed `chartYScale` only when a domain is supplied; a `nil`
    /// domain leaves the axis on its auto range (a metric's own value spread).
    private struct YDomainModifier: ViewModifier {
        let domain: ClosedRange<Double>?

        func body(content: Content) -> some View {
            if let domain {
                content.chartYScale(domain: domain)
            } else {
                content
            }
        }
    }
}
