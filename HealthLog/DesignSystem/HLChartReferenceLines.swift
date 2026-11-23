import Charts
import SwiftUI

/// **The one way a chart shows a limit or a target range.**
///
/// Every edge is a rule across the plot, never a filled area: an upper edge
/// in `thresholdHigh`, a lower edge in `thresholdLow`, a clinical line dashed,
/// a line the person set themselves solid. The label rides above the line at
/// the trailing edge, where the newest values end and the curve is least
/// likely to run, in caption type; where the plot has no room above the line
/// the label moves down into it instead of being cut. The label stands on
/// the card's surface; put the lines after the series in the chart, so it
/// lies above the curve and not under it. Each line is one VoiceOver element ("Upper edge, 140
/// mmHg, Blutdruck-Grenze").
///
/// Two ways in: the lines the series route delivers (`lines:`, drawn as
/// delivered, nothing placed, moved or dropped here), or a band with a lower
/// and an upper edge (``band(lower:upper:label:source:unit:)``) for a lab
/// reference range or a medication's target. A band is two lines, so the
/// "share inside the band" stays outside the chart, in ``RangeBandRow``.
struct HLChartReferenceLines: ChartContent {
    /// Already in the unit the chart plots in.
    let lines: [SeriesReferenceLine]
    /// The axis unit, spoken after the value.
    let unit: String
    /// Whether an upper and a lower edge take their own tints. A clinical
    /// reference range draws both edges neutral: red over green reads as
    /// bad over good, and either side of a range can be the bad one.
    var tintsEdges = true

    /// Nothing to draw: every chart without lines.
    static let none = HLChartReferenceLines(lines: [], unit: "")

    /// A target or reference band as its two edges. A missing edge (an
    /// open-ended range such as "under 5.7 %") draws only the other one; a
    /// non-finite value draws nothing. Both edges carry the same label, the
    /// upper one draws it, so a narrow band does not stack two labels.
    static func band(
        lower: Double?,
        upper: Double?,
        label: String = "",
        source: SeriesReferenceLine.Source = .clinical,
        unit: String
    ) -> HLChartReferenceLines {
        var lines: [SeriesReferenceLine] = []
        if let lower, lower.isFinite {
            lines.append(SeriesReferenceLine(value: lower, kind: .lower, source: source, label: upper == nil ? label : ""))
        }
        if let upper, upper.isFinite {
            lines.append(SeriesReferenceLine(value: upper, kind: .upper, source: source, label: label))
        }
        return HLChartReferenceLines(lines: lines, unit: unit, tintsEdges: source == .personal)
    }

    /// The values the y-domain has to reach so every line is on screen.
    var values: [Double] {
        lines.map(\.value).filter(\.isFinite)
    }

    var body: some ChartContent {
        ForEach(lines) { line in
            let style = HLReferenceLineStyle(line: line, tintsEdges: tintsEdges)
            RuleMark(y: .value(line.label, line.value))
                .foregroundStyle(style.tint)
                .lineStyle(StrokeStyle(
                    lineWidth: HLChartGrid.thresholdWidth,
                    dash: style.isDashed ? HLChartGrid.thresholdDash : []
                ))
                .annotation(
                    position: .top,
                    alignment: HLReferenceLineStyle.labelAlignment,
                    spacing: HLSpace.xxs,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    if !line.label.isEmpty {
                        // The card's own surface behind the words, so a curve
                        // that runs through the label does not cross them.
                        Text(line.label)
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, HLSpace.xxs)
                            .background(HLSurface.secondary, in: Capsule())
                    }
                }
                .accessibilityLabel(Text(style.accessibilityLabel))
                .accessibilityValue(Text(style.accessibilityValue(unit: unit)))
        }
    }
}

/// The pure half of a reference line's look and speech, so the mapping is
/// testable without a chart host.
struct HLReferenceLineStyle: Equatable {
    enum TintRole: Equatable {
        case upper
        case lower
        case neutral
    }

    let line: SeriesReferenceLine
    /// `false` draws an upper and a lower edge in the neutral tint.
    let tintsEdges: Bool

    /// Spelled out, so `HLReferenceLineStyle.init(line:)` stays a function
    /// value for `map`.
    init(line: SeriesReferenceLine) {
        self.init(line: line, tintsEdges: true)
    }

    init(line: SeriesReferenceLine, tintsEdges: Bool) {
        self.line = line
        self.tintsEdges = tintsEdges
    }

    /// The label stands at the trailing end of its line, above it.
    static let labelAlignment: Alignment = .trailing

    var tintRole: TintRole {
        guard tintsEdges else { return .neutral }
        return switch line.kind {
        case .upper: .upper
        case .lower: .lower
        case .unknown: .neutral
        }
    }

    var tint: Color {
        switch tintRole {
        case .upper: HLChartTints.thresholdHigh
        case .lower: HLChartTints.thresholdLow
        case .neutral: HLText.tertiary
        }
    }

    /// Clinical (and any source this build does not know) dashed; a line the
    /// person set themselves solid.
    var isDashed: Bool {
        line.source != .personal
    }

    var accessibilityLabel: String {
        switch line.kind {
        case .upper: String(localized: "chart.referenceLine.a11y.upper")
        case .lower: String(localized: "chart.referenceLine.a11y.lower")
        case .unknown: String(localized: "chart.referenceLine.a11y.line")
        }
    }

    func accessibilityValue(unit: String) -> String {
        let number = HLValueFormat.number(line.value, fractionDigits: 0 ... 1)
        let value = unit.isEmpty ? number : "\(number) \(unit)"
        return line.label.isEmpty ? value : "\(value), \(line.label)"
    }
}
