import Charts
import SwiftUI

// The server's reference lines (#135, server v1.43) draw through the design
// system's `HLChartReferenceLines`; these names stay until every chart
// switches over.
typealias ReferenceLineMarks = HLChartReferenceLines
typealias ReferenceLineStyle = HLReferenceLineStyle

extension MetricChartContent {
    /// ``marks(for:points:emphasisTint:includeThresholds:showsPoints:seriesLineWidth:)``
    /// for a detail chart, with the server's reference lines drawn after the
    /// series: a line's label then stands on the plot instead of under the
    /// curve.
    @ChartContentBuilder
    static func marks(
        for kind: MetricKind,
        points: [SeriesPoint],
        emphasisTint: Color?,
        references: ReferenceLineMarks,
        bands: [MetricTargetBand] = []
    ) -> some ChartContent {
        // The pale bands under everything, the measured points on top.
        ForEach(bands) { band in
            RectangleMark(yStart: .value("Lower", band.lower), yEnd: .value("Upper", band.upper))
                .foregroundStyle(MetricTargetBand.fill)
        }
        marks(for: kind, points: points, emphasisTint: emphasisTint, showsPoints: kind.showsMeasuredPoints)
        references
    }
}

extension MetricChartMath {
    /// ``logDomain(for:)`` widened so every reference line is on screen: a
    /// line outside the plotted values would otherwise sit off the chart.
    static func logDomain(for points: [SeriesPoint], including lines: [SeriesReferenceLine]) -> ClosedRange<Double> {
        let base = logDomain(for: points)
        let values = lines.map(\.value).filter { $0.isFinite && $0 > 0 }
        guard let lo = values.min(), let hi = values.max(), !points.isEmpty else { return base }
        let lower = min(base.lowerBound, lo * 0.95)
        let upper = max(base.upperBound, hi * 1.05)
        return lower ... (upper > lower ? upper : lower + 1)
    }
}

extension ChartDetailStore {
    /// The marks for this chart's server reference lines, in the unit the
    /// chart plots in (empty on an older server).
    func referenceLineMarks(units: UnitPreferences) -> ReferenceLineMarks {
        ReferenceLineMarks(lines: plotReferenceLines(units: units), unit: displayUnit(units: units))
    }
}

/// The target range of a chart as a pale band, from the server's reference
/// lines: a lower and an upper line of the same series make one band. It
/// answers "do I stand well?" without a tap; the lines keep their labels.
struct MetricTargetBand: Identifiable, Equatable {
    let lower: Double
    let upper: Double
    let appliesTo: SeriesReferenceLine.AppliesTo

    var id: String {
        appliesTo.rawValue
    }

    /// The warm sage of "in range", faint enough that the points stay in front.
    static var fill: Color {
        HLColor.statusOK.opacity(0.10)
    }

    /// One band per series that has both edges, lower below upper.
    static func bands(from lines: [SeriesReferenceLine]) -> [MetricTargetBand] {
        [SeriesReferenceLine.AppliesTo.value, .secondary].compactMap { series in
            let own = lines.filter { $0.appliesTo == series && $0.value.isFinite }
            guard let lower = own.first(where: { $0.kind == .lower })?.value,
                  let upper = own.first(where: { $0.kind == .upper })?.value,
                  lower < upper else { return nil }
            return MetricTargetBand(lower: lower, upper: upper, appliesTo: series)
        }
    }
}

extension MetricKind {
    /// The kinds whose detail chart shows every reading as a point: spot
    /// measurements, where a smooth curve would invent values between them.
    var showsMeasuredPoints: Bool {
        self == .bloodPressure || self == .glucose
    }
}
