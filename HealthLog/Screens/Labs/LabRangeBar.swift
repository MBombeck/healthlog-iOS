import SwiftUI

/// Where a reading stands on its reference range, as fractions of a scale.
///
/// Pure, so the rule is tested without a view. The range takes the middle
/// half of the scale, so a value just outside it still has room to stand
/// visibly apart; a value far outside widens the scale until it fits. A
/// one-sided range ("≤ 5") is drawn from the scale's open end to its bound.
enum LabRangeScale {
    /// The fractions (0 at the leading edge, 1 at the trailing) a bar draws.
    struct Placement: Equatable {
        /// The reference range; `nil` ends run to the edge of the scale.
        let bandStart: Double
        let bandEnd: Double
        /// The reading the bar is about.
        let value: Double
        /// Earlier readings, oldest first.
        let previous: [Double]
        /// The bounds as the server gave them, for the labels under the bar.
        let low: Double?
        let high: Double?
    }

    /// The range a marker is judged against: the catalogue's when the
    /// marker is linked and has one, else the reading's printed bounds. The
    /// table row and the marker page both take it from here, so the same
    /// value stands at the same place in both.
    static func bounds(marker: BiomarkerDTO?, latest: LabResultDTO?) -> (low: Double?, high: Double?) {
        (marker?.lowerBound ?? latest?.referenceLow, marker?.upperBound ?? latest?.referenceHigh)
    }

    /// The most earlier readings a bar shows; more turn into a smear.
    static let previousLimit = 5
    /// Room around the readings when one of them widens the scale.
    static let edgeRoom = 0.06

    /// The placement of `value` and its earlier readings on the range from
    /// `low` to `high`; `nil` without any finite bound or without a finite
    /// value (a qualitative result has no place on a scale).
    static func placement(value: Double?, previous: [Double], low: Double?, high: Double?) -> Placement? {
        guard let value, value.isFinite else { return nil }
        let low = low.flatMap { $0.isFinite ? $0 : nil }
        let high = high.flatMap { $0.isFinite ? $0 : nil }
        guard low != nil || high != nil else { return nil }
        let earlier = Array(previous.filter(\.isFinite).suffix(previousLimit))

        var lower: Double
        var upper: Double
        switch (low, high) {
        case let (low?, high?) where high > low:
            let span = high - low
            // A range that starts at or above zero never reaches below it
            // ("0 to 3 mg/L" drew track left of the zero).
            lower = low >= 0 ? max(0, low - span / 2) : low - span / 2
            upper = high + span / 2
        case let (low?, high?):
            // A degenerate range (one point) still gets a visible scale.
            let room = max(abs(low), 1) / 2
            lower = min(low, high) - room
            upper = max(low, high) + room
        case let (nil, high?):
            // "At most": the range runs from zero, or from below zero for a
            // value that can be negative.
            lower = min(0, high)
            upper = high + max(abs(high), 1) / 2
        case let (low?, nil):
            // "At least": the range runs to the open end.
            lower = low - max(abs(low), 1) / 2
            upper = low + max(abs(low), 1)
        case (nil, nil):
            return nil
        }

        // Every reading stands inside the scale, with a little room.
        let readings = earlier + [value]
        if let least = readings.min(), let most = readings.max(), least < lower || most > upper {
            let widened = (min(lower, least), max(upper, most))
            let room = (widened.1 - widened.0) * edgeRoom
            if least < lower { lower = least - room }
            if most > upper { upper = most + room }
        }

        let width = upper - lower
        guard width > 0 else { return nil }
        func fraction(_ number: Double) -> Double {
            min(1, max(0, (number - lower) / width))
        }
        return Placement(
            bandStart: low.map(fraction) ?? 0,
            bandEnd: high.map(fraction) ?? 1,
            value: fraction(value),
            previous: earlier.map(fraction),
            low: low,
            high: high
        )
    }
}

/// A reading on its reference range: a quiet track, the range on it, the
/// earlier readings as faint points and the reading as one firm point, the
/// bounds in small figures under the range.
///
/// Monochrome like every chart of the app: it shows where the value lies,
/// the verdict stays the server's status beside it.
struct LabRangeBar: View {
    let placement: LabRangeScale.Placement
    /// The spoken description: value, range and verdict.
    let accessibilityText: String
    /// The ground the bar stands on (a card, a selected row): the ring that
    /// sets the value point off the range takes its colour.
    var surface: Color = HLSurface.secondary

    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 13

    /// The measures of the bar.
    enum Metrics {
        static let trackHeight: CGFloat = 6
        static let valueDot: CGFloat = 10
        static let previousDot: CGFloat = 5
        /// The ring that sets the value point off the range under it.
        static let valueRing: CGFloat = 2
        static let labelGap: CGFloat = HLSpace.xxs
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: Metrics.valueDot + Metrics.labelGap + labelHeight)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset = Metrics.valueDot / 2
        let width = max(0, size.width - 2 * inset)
        let midY = Metrics.valueDot / 2
        func x(_ fraction: Double) -> CGFloat {
            inset + width * fraction
        }
        let track = CGRect(x: inset, y: midY - Metrics.trackHeight / 2, width: width, height: Metrics.trackHeight)
        // The track in the faint ink of a chart grid, so the whole scale
        // shows on a card as on a selected row.
        context.fill(Capsule().path(in: track), with: .color(HLText.primary.opacity(HLChartGrid.lineOpacity)))

        let band = CGRect(
            x: x(placement.bandStart),
            y: track.minY,
            width: max(Metrics.trackHeight, x(placement.bandEnd) - x(placement.bandStart)),
            height: Metrics.trackHeight
        )
        context.fill(Capsule().path(in: band), with: .color(HLChartTints.seriesLow))

        for earlier in placement.previous {
            let dot = CGRect(
                x: x(earlier) - Metrics.previousDot / 2,
                y: midY - Metrics.previousDot / 2,
                width: Metrics.previousDot,
                height: Metrics.previousDot
            )
            context.fill(Circle().path(in: dot), with: .color(HLChartTints.seriesMid))
        }

        let point = CGRect(
            x: x(placement.value) - Metrics.valueDot / 2,
            y: 0,
            width: Metrics.valueDot,
            height: Metrics.valueDot
        )
        context.fill(Circle().path(in: point.insetBy(dx: -Metrics.valueRing, dy: -Metrics.valueRing)), with: .color(surface))
        context.fill(Circle().path(in: point), with: .color(HLChartTints.series))

        drawBounds(in: &context, labelTop: Metrics.valueDot + Metrics.labelGap, width: size.width, x: x)
    }

    /// The bounds under the ends of the range; one line in the middle of the
    /// range where the two would touch.
    private func drawBounds(
        in context: inout GraphicsContext,
        labelTop: CGFloat,
        width: CGFloat,
        x: (Double) -> CGFloat
    ) {
        let role = HLTextRole.chartMark
        func label(_ string: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: string).font(role.font).foregroundStyle(role.color))
        }
        func place(_ text: GraphicsContext.ResolvedText, centredAt center: CGFloat) {
            let size = text.measure(in: CGSize(width: width, height: labelHeight * 2))
            let left = min(max(0, center - size.width / 2), max(0, width - size.width))
            context.draw(text, in: CGRect(x: left, y: labelTop, width: size.width, height: size.height))
        }
        let low = placement.low.map { LabRangeBar.number($0) }
        let high = placement.high.map { LabRangeBar.number($0) }
        switch (low, high) {
        case let (low?, high?):
            let lowText = label(low)
            let highText = label(high)
            let lowWidth = lowText.measure(in: CGSize(width: width, height: labelHeight * 2)).width
            let highWidth = highText.measure(in: CGSize(width: width, height: labelHeight * 2)).width
            let start = x(placement.bandStart)
            let end = x(placement.bandEnd)
            if end - start >= (lowWidth + highWidth) / 2 + Metrics.valueDot {
                place(lowText, centredAt: start)
                place(highText, centredAt: end)
            } else {
                place(label(String(localized: "labs.rangeBar.span \(low) \(high)")), centredAt: (start + end) / 2)
            }
        case let (nil, high?):
            place(label(String(localized: "labs.rangeBar.atMost \(high)")), centredAt: x(placement.bandEnd))
        case let (low?, nil):
            place(label(String(localized: "labs.rangeBar.atLeast \(low)")), centredAt: x(placement.bandStart))
        case (nil, nil):
            break
        }
    }

    /// A bound as the figures under the bar show it.
    nonisolated static func number(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 0 ... 2)
    }
}

extension LabRangeBar {
    /// The bar for a reading, its earlier values and its range; `nil` where
    /// there is no range or no number to place.
    init?(
        value: Double?,
        previous: [Double] = [],
        low: Double?,
        high: Double?,
        accessibilityText: String,
        surface: Color = HLSurface.secondary
    ) {
        guard let placement = LabRangeScale.placement(value: value, previous: previous, low: low, high: high) else {
            return nil
        }
        self.init(placement: placement, accessibilityText: accessibilityText, surface: surface)
    }
}
