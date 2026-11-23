import Charts
import SwiftUI

// MARK: - Grid and axis

/// The grid behind every row at the axis step of the window (days, weeks,
/// months, quarters or years), the stretch after today set a shade apart,
/// and the today line. Drawn once for the whole board in one pass.
struct TimelineGrid: View, Equatable {
    let window: TimelineWindow
    let today: Int

    var body: some View {
        Canvas { context, size in
            let x = { (day: Int) in CGFloat(window.fraction(Double(day))) * size.width }
            let step = TimelineAxisStep.step(window: window, width: size.width)
            for start in step.starts(in: window) where start > window.from {
                var line = Path()
                line.move(to: CGPoint(x: x(start), y: 0))
                line.addLine(to: CGPoint(x: x(start), y: size.height))
                context.stroke(line, with: .color(HLText.primary.opacity(HLChartGrid.lineOpacity)), lineWidth: HLChartGrid.lineWidth)
            }
            if today < window.to {
                let left = x(today + 1)
                context.fill(
                    Path(CGRect(x: left, y: 0, width: size.width - left, height: size.height)),
                    with: .color(HLText.primary.opacity(0.03))
                )
            }
            if window.contains(today) {
                var line = Path()
                let todayX = x(today + 1)
                line.move(to: CGPoint(x: todayX, y: 0))
                line.addLine(to: CGPoint(x: todayX, y: size.height))
                context.stroke(line, with: .color(HLText.secondary.opacity(0.7)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The names of the axis steps over the plot, and "Heute" over the today line.
/// Which names stand is ``TimelineAxisLabels``: none touches another.
struct TimelineAxis: View, Equatable {
    let window: TimelineWindow
    let today: Int
    let width: CGFloat
    /// Where the visible plot begins: a name left of it would be cut.
    var leadingInset: CGFloat = 0

    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.window == rhs.window && lhs.today == rhs.today && lhs.width == rhs.width && lhs.leadingInset == rhs.leadingInset
    }

    var body: some View {
        let todayText = String(localized: "timeline.today")
        let todayWidth = TimelineAxisLabels.measurer(.caption2, weight: .medium, typeSize: typeSize)(todayText)
        let labels = TimelineAxisLabels.labels(
            window: window, today: today, width: width, leadingInset: leadingInset, todayWidth: todayWidth,
            measure: TimelineAxisLabels.measurer(.caption1, weight: .regular, typeSize: typeSize)
        )
        ZStack(alignment: .topLeading) {
            ForEach(labels, id: \.day) { label in
                Text(label.text)
                    .hlText(.chartAxis)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, label.x + TimelineAxisLabels.lineInset)
            }
            if let span = TimelineAxisLabels.todaySpan(window: window, today: today, width: width, todayWidth: todayWidth) {
                Text(todayText)
                    .hlText(.chartMark)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, span.lowerBound)
            }
        }
        .frame(width: width, height: TimelineMetrics.axisHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Lanes

/// One bar row of a lane: thin rounded bars with their name above, a gap
/// where a pause lies, an arrow where the bar is still running, a dot for a
/// single day.
struct TimelineLaneRowView: View, Equatable {
    let row: TimelineLaneRow
    let window: TimelineWindow
    let width: CGFloat
    let color: Color
    /// Where the visible plot begins: a bar that runs in from before keeps
    /// its name at this edge.
    var labelInset: CGFloat = 0
    /// One bar row; shorter on a short window (a phone held across).
    var rowHeight: CGFloat = TimelineMetrics.laneRowHeight

    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.window == rhs.window && lhs.width == rhs.width && lhs.color == rhs.color
            && lhs.labelInset == rhs.labelInset && lhs.rowHeight == rhs.rowHeight
    }

    var body: some View {
        let bars = placedBars
        ZStack(alignment: .topLeading) {
            ForEach(Array(bars.enumerated()), id: \.element.bar.id) { _, placed in
                bar(placed)
            }
            ForEach(row.marks) { mark in
                markView(mark)
            }
            ForEach(labels(bars), id: \.id) { label in
                labelView(label)
            }
        }
        .frame(width: width, height: rowHeight, alignment: .topLeading)
        .clipped()
    }

    /// The names of the row's bars and marks, each whole or cut only as the
    /// row's own name (``TimelineRowLabels``).
    private func labels(_ bars: [PlacedBar]) -> [TimelineRowLabel] {
        var candidates: [TimelineRowLabels.Candidate] = []
        for placed in bars where !placed.bar.isPause {
            guard let text = placed.bar.label else { continue }
            let isName = row.title.map { !$0.isEmpty && text.hasPrefix($0) } ?? false
            candidates.append(TimelineRowLabels.Candidate(
                id: placed.bar.id, anchor: placed.labelX, text: text,
                short: isName && row.title != text ? row.title : nil, isRowName: isName
            ))
        }
        for mark in row.marks {
            guard let text = mark.label else { continue }
            let center = markCenter(mark)
            candidates.append(TimelineRowLabels.Candidate(
                id: mark.id, anchor: max(0, center - 3), text: text, isMark: true, endAnchor: center + 3
            ))
        }
        return TimelineRowLabels.place(
            candidates, width: width, leadingInset: labelInset,
            measure: TimelineAxisLabels.measurer(.caption2, weight: .medium, typeSize: typeSize)
        )
    }

    private func labelView(_ label: TimelineRowLabel) -> some View {
        let barTop = rowHeight - TimelineMetrics.barHeight - HLSpace.xxs
        return Text(label.text)
            .hlText(.chartMark)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: label.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Right above its own bar or dot, so it never reads as the name of the row above.
            .frame(height: label.isMark ? rowHeight - 10 : barTop - 1, alignment: .bottomLeading)
            // Padding, not an offset: the pin reads the laid-out position.
            .padding(.leading, label.x)
    }

    private func markCenter(_ mark: TimelineMark) -> CGFloat {
        x(mark.day) + (x(mark.day + 1) - x(mark.day)) / 2
    }

    private struct PlacedBar {
        let bar: TimelineBar
        let left: CGFloat
        let right: CGFloat
        /// Where the name starts: the bar's start, or the visible edge for a
        /// bar that runs in from before it.
        let labelX: CGFloat
    }

    private var placedBars: [PlacedBar] {
        let visible = row.bars.filter { !$0.isPause }.sorted { $0.start < $1.start }
        let pauses = row.bars.filter(\.isPause)
        var out: [PlacedBar] = []
        for bar in visible {
            let left = max(0, x(bar.start))
            let right = min(width, x(bar.endExclusive))
            let labelX = min(max(left, labelInset), max(left, right - 24))
            out.append(PlacedBar(
                bar: bar, left: left, right: max(left + 2, right), labelX: labelX
            ))
        }
        for pause in pauses {
            let left = max(0, x(pause.start))
            out.append(PlacedBar(
                bar: pause, left: left, right: max(left + 2, min(width, x(pause.endExclusive))), labelX: left
            ))
        }
        return out
    }

    @ViewBuilder
    private func bar(_ placed: PlacedBar) -> some View {
        let barTop = rowHeight - TimelineMetrics.barHeight - HLSpace.xxs
        if placed.bar.isPause {
            // A pause cuts the bar under it: the card's own surface, a dotted rule.
            Rectangle()
                .fill(HLSurface.primary)
                .frame(width: placed.right - placed.left, height: TimelineMetrics.barHeight + 2)
                .overlay {
                    Rectangle()
                        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(height: 0.5)
                }
                .offset(x: placed.left, y: barTop - 1)
        } else {
            HStack(spacing: 0) {
                Capsule()
                    .fill(color.opacity(placed.bar.beginsWithChange ? 0.95 : 0.8))
                    .frame(width: max(2, placed.right - placed.left - (placed.bar.open ? 5 : 0)), height: TimelineMetrics.barHeight)
                if placed.bar.open {
                    TimelineArrowHead()
                        .fill(color)
                        .frame(width: 5, height: 7)
                }
            }
            .offset(x: placed.left, y: barTop)
        }
    }

    private func markView(_ mark: TimelineMark) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .offset(x: markCenter(mark) - 3.5, y: rowHeight - 9)
    }

    private func x(_ day: Int) -> CGFloat {
        CGFloat(window.fraction(Double(day))) * width
    }
}

// MARK: - Value lines

/// One value line as a Swift Chart on the board's shared time axis: the
/// solid runs, dashed bridges over short gaps, a point per bucket (hollow
/// from fewer than three readings), the newest one ringed, and for a lab
/// marker its reference range as a band behind the points.
struct TimelineValueChart: View, Equatable {
    let row: TimelineValueRow
    let window: TimelineWindow

    private struct LinePoint: Identifiable {
        let id: String
        let series: String
        let point: TimelinePlotPoint
    }

    var body: some View {
        let track = row.track
        Chart {
            // The reference range: a quiet field where both ends are known,
            // a faint rule at each known end.
            if let band = track.band, let low = band.low, let high = band.high {
                RectangleMark(
                    xStart: .value("timeline.chart.day", Double(window.from)),
                    xEnd: .value("timeline.chart.day", Double(window.to + 1)),
                    yStart: .value(row.title, low),
                    yEnd: .value(row.title, high)
                )
                .foregroundStyle(row.color.opacity(0.06))
            }
            ForEach(track.band.map { [$0.low, $0.high].compactMap { $0 } } ?? [], id: \.self) { bound in
                // A faint solid rule: dashes on this board mean a gap between
                // two readings, so a bound never borrows them.
                RuleMark(y: .value(row.title, bound))
                    .foregroundStyle(row.color.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            ForEach(lines) { line in
                LineMark(
                    x: .value("timeline.chart.day", line.point.day),
                    y: .value(row.title, line.point.value),
                    series: .value("timeline.chart.run", line.series)
                )
                .foregroundStyle(row.color)
                .lineStyle(line.series.hasPrefix("bridge")
                    ? StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3])
                    : StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
            ForEach(track.points) { point in
                PointMark(x: .value("timeline.chart.day", point.day), y: .value(row.title, point.value))
                    .symbol { symbol(for: point) }
            }
        }
        .chartXScale(domain: Double(window.from) ... Double(window.to + 1), range: .plotDimension(padding: 0))
        .chartYScale(domain: track.domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    private var lines: [LinePoint] {
        let runs = row.track.runs.enumerated().flatMap { index, run in
            run.map { LinePoint(id: "run\(index)-\($0.id)", series: "run\(index)", point: $0) }
        }
        let bridges = row.track.bridges.enumerated().flatMap { index, pair in
            pair.map { LinePoint(id: "bridge\(index)-\($0.id)", series: "bridge\(index)", point: $0) }
        }
        return runs + bridges
    }

    @ViewBuilder
    private func symbol(for point: TimelinePlotPoint) -> some View {
        let isLatest = point.id == row.track.latest?.id
        let tint = point.isOutOfRange ? HLColor.statusWarn : row.color
        let size: CGFloat = isLatest ? 10 : (point.isThin || point.isOutOfRange ? 6 : 5)
        // Diastolic shares the systolic colour and is told apart by its
        // diamond, as on the metric page.
        let shape = row.id == "BLOOD_PRESSURE_DIA" ? AnyShape(TimelineDiamond()) : AnyShape(Circle())
        if isLatest {
            shape
                .stroke(tint, lineWidth: 1.5)
                .background(shape.fill(HLSurface.primary))
                .overlay(shape.fill(tint).padding(HLSpace.xxs))
                .frame(width: size, height: size)
        } else if point.isThin {
            shape
                .stroke(tint, lineWidth: 1.25)
                .background(shape.fill(HLSurface.primary))
                .frame(width: size, height: size)
        } else {
            shape
                .fill(tint)
                .frame(width: size, height: size)
        }
    }
}

/// The diastolic point: a small upright square turned on its corner.
struct TimelineDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// A line without a point in the window: a quiet tinted field with a
/// dashed edge, so the row keeps its place and says so.
struct TimelineNoValueField: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
            .fill(color.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
                    .strokeBorder(color.opacity(0.25), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            }
            .padding(.vertical, HLSpace.xs)
            .accessibilityHidden(true)
    }
}

/// The small arrow at the end of a bar that is still running: drawn, so it
/// keeps the bar's 4 pt measure at every text size.
struct TimelineArrowHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
