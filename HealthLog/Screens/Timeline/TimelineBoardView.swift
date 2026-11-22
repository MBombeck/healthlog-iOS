import SwiftUI

/// The timeline's board: lanes on top, one value line per row under them,
/// all on one time axis with the month grid, the today line and the chosen
/// period across every row.
///
/// It measures its own width and lays itself out from it: from 600 pt the
/// full board with a column of names on the left (iPad, the open Duo), below
/// it every name above its track and the axis scrolling sideways, today in
/// view (iPhone upright).
struct TimelineBoardView: View, Equatable {
    let content: TimelineBoardContent
    let store: TimelineStore
    let wording: TimelineWording
    /// Upright in the turned full screen: one quiet line says to turn back.
    var showsRotateHint = false
    /// Row measures; short when the window is low (a phone held across).
    var density: TimelineDensity = .regular

    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The rows at this density, grown with the text size.
    private var rows: TimelineDensity {
        density.scaled(for: typeSize)
    }

    var body: some View {
        Group {
            if width > 0 {
                switch TimelineLayoutStyle.style(width: width, typeSize: typeSize) {
                case .board: board
                case .stacked: stacked
                }
            } else {
                Color.clear.frame(height: TimelineMetrics.boardValueRowHeight)
            }
        }
        // The width is the offer alone (`minWidth: 0`): a frame with only a
        // maximum takes its content's width when that is wider, and the
        // board's content is built from the measured width, so a fraction
        // of a point too much would feed the measure and grow it again.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if Self.takesWidth(new, over: width) { width = new }
        }
    }

    /// Two boards are the same when they draw the same content in the same
    /// way. The page around the board changes often (a refresh dims it, the
    /// chosen period moves, the summary follows a pick); with `.equatable()`
    /// none of that rebuilds the rows. The chosen moment is not part of it:
    /// the selection layer and the value labels follow it on their own.
    nonisolated static func == (lhs: TimelineBoardView, rhs: TimelineBoardView) -> Bool {
        lhs.content == rhs.content
            && lhs.store === rhs.store
            && lhs.showsRotateHint == rhs.showsRotateHint
            && lhs.density == rhs.density
            && lhs.wording.units == rhs.wording.units
            && lhs.wording.read == rhs.wording.read
    }

    /// Whether a newly measured width replaces the one in use: only a change
    /// of half a point or more, so pixel rounding cannot start a loop.
    static func takesWidth(_ new: CGFloat, over current: CGFloat) -> Bool {
        abs(new - current) >= 0.5
    }

    /// The columns of the board at a width: card inset, names, gap and
    /// plot. Together they never ask for more than `width`.
    static func boardColumns(
        width: CGFloat,
        density: TimelineDensity
    ) -> TimelineBoardColumns {
        let inset = density.labelColumn == nil ? HLLayout.cardInset : 0
        let inner = max(0, width - 2 * inset)
        let label = min(density.labelColumn ?? TimelineLayoutStyle.labelColumnWidth(width: inner), max(0, inner - HLSpace.md))
        let plot = max(0, inner - label - HLSpace.md)
        return TimelineBoardColumns(inset: inset, label: label, plot: plot)
    }

    // MARK: - Board (regular width)

    private var board: some View {
        // A short window drops the card: the board runs edge to edge.
        let columns = Self.boardColumns(width: width, density: density)
        let labelWidth = columns.label
        let plotWidth = columns.plot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HLSpace.md) {
                Color.clear.frame(width: labelWidth, height: TimelineMetrics.axisHeight)
                TimelineAxis(window: content.window, today: content.today, width: plotWidth)
            }
            ForEach(content.lanes) { lane in
                HStack(alignment: .top, spacing: HLSpace.md) {
                    TimelineLaneLabel(title: wording.title(forLane: lane.key), lane: lane.key)
                        .frame(width: labelWidth, alignment: .leading)
                        .padding(.top, rows.rowPadding)
                    laneRows(lane, width: plotWidth)
                }
                .padding(.vertical, rows.rowPadding)
                .timelineLaneAccessibility(lane, wording: wording, window: content.window)
            }
            if !content.lanes.isEmpty, !content.values.isEmpty {
                Divider().padding(.vertical, density == .short ? HLSpace.xs : HLSpace.sm)
            }
            ForEach(content.values) { row in
                HStack(alignment: .center, spacing: HLSpace.md) {
                    TimelineValueLabel(row: row, layout: .column, store: store, wording: wording, bucket: content.bucket)
                        .frame(width: labelWidth, alignment: .leading)
                    valuePlot(row)
                        .frame(width: plotWidth, height: rows.valuePlot)
                }
                .frame(minHeight: rows.valueRow)
                .timelineValueAccessibility(row, window: content.window)
            }
        }
        .background(alignment: .topLeading) {
            TimelineGrid(window: content.window, today: content.today)
                .frame(width: plotWidth)
                .padding(.leading, labelWidth + HLSpace.md)
        }
        .overlay(alignment: .topLeading) {
            TimelineSelectionLayer(store: store, window: content.window, bucket: content.bucket, width: plotWidth)
                .frame(width: plotWidth)
                .padding(.leading, labelWidth + HLSpace.md)
        }
        .modifier(TimelineBoardSurface(isCard: density != .short))
    }

    // MARK: - Stacked (compact width)

    /// Edge to edge: the plot runs under the page margins, the names stand
    /// above their tracks at the margin, a bar running in from before keeps
    /// its name at the margin too.
    private var stacked: some View {
        let margin = HLLayout.pageMargin
        let plotWidth = width + 2 * margin
        return VStack(alignment: .leading, spacing: 0) {
            if showsRotateHint {
                Label("timeline.rotateHint", systemImage: "rectangle.landscape.rotate")
                    .hlText(.note)
                    .padding(.leading, margin)
                    .padding(.bottom, HLSpace.sm)
            }
            TimelineAxis(window: content.window, today: content.today, width: plotWidth, leadingInset: margin)
            ForEach(content.lanes) { lane in
                VStack(alignment: .leading, spacing: 0) {
                    TimelineLaneLabel(title: wording.title(forLane: lane.key), lane: lane.key)
                        .padding(.leading, margin)
                    laneRows(lane, width: plotWidth, labelInset: margin)
                }
                .padding(.vertical, HLSpace.xs)
                .timelineLaneAccessibility(lane, wording: wording, window: content.window)
            }
            if !content.lanes.isEmpty, !content.values.isEmpty {
                Divider().padding(.vertical, HLSpace.xs)
            }
            ForEach(content.values) { row in
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    TimelineValueLabel(row: row, layout: .inline, store: store, wording: wording, bucket: content.bucket)
                        .padding(.horizontal, margin)
                        .frame(width: plotWidth, alignment: .leading)
                    valuePlot(row)
                        .frame(width: plotWidth, height: TimelineMetrics.valuePlotHeight)
                }
                .padding(.vertical, HLSpace.xs)
                .timelineValueAccessibility(row, window: content.window)
            }
        }
        .frame(width: plotWidth, alignment: .leading)
        .background { TimelineGrid(window: content.window, today: content.today) }
        .overlay {
            TimelineSelectionLayer(store: store, window: content.window, bucket: content.bucket, width: plotWidth)
        }
        .clipped()
        .padding(.horizontal, -margin)
    }

    // MARK: - Rows

    private func laneRows(_ lane: TimelineLaneTrack, width plotWidth: CGFloat, labelInset: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lane.rows) { row in
                TimelineLaneRowView(
                    row: row,
                    window: content.window,
                    width: plotWidth,
                    color: TimelinePalette.color(forLane: lane.key),
                    labelInset: labelInset,
                    rowHeight: rows.laneRow
                )
            }
        }
        .frame(width: plotWidth, alignment: .leading)
    }

    @ViewBuilder
    private func valuePlot(_ row: TimelineValueRow) -> some View {
        if row.track.isEmpty {
            TimelineNoValueField(color: row.color)
        } else {
            TimelineValueChart(row: row, window: content.window)
        }
    }
}

// MARK: - Labels

/// The name of a lane with its symbol.
struct TimelineLaneLabel: View {
    let title: String
    let lane: TimelineLaneKey

    var body: some View {
        Label {
            Text(title)
                .hlText(.rowTitle)
        } icon: {
            Image(systemName: TimelineWording.symbol(forLane: lane))
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(TimelinePalette.color(forLane: lane))
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(2)
    }
}

/// The name of a value line and its newest value: two lines in the board's
/// name column, one line above the track when the names stand inline.
struct TimelineValueLabel: View {
    enum Layout {
        case column
        case inline
    }

    let row: TimelineValueRow
    let layout: Layout
    /// The chosen period: its value stands here instead of the newest one.
    let store: TimelineStore
    let wording: TimelineWording
    let bucket: TimelineBucket

    var body: some View {
        switch layout {
        case .column:
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                tick
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    title
                    value
                }
            }
        case .inline:
            // One line where it fits, else the value under the name: a long
            // name in Dutch or a large text size never pushes the value off.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    tick
                    title.fixedSize()
                    value.fixedSize()
                }
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                        tick
                        title
                    }
                    value
                }
            }
        }
    }

    /// The line's value in the bucket that holds `day`: the bucket's mean,
    /// or a lab marker's last reading in it.
    nonisolated static func value(of track: TimelineValueTrack, inBucketOf day: Int, bucket: TimelineBucket) -> Double? {
        reading(of: track, at: day, bucket: bucket).flatMap { $0.isInBucket ? $0.value : nil }
    }

    /// What a line says at a chosen day.
    struct Reading: Equatable {
        let value: Double
        /// The day the point stands on.
        let day: Int
        /// The point lies in the chosen bucket; otherwise it is the last one before.
        let isInBucket: Bool
    }

    /// The point in the bucket that holds `day`, else the last point before
    /// it: a line never says "no value" next to a point it draws, and an
    /// older value says from when it is.
    nonisolated static func reading(of track: TimelineValueTrack, at day: Int, bucket: TimelineBucket) -> Reading? {
        let start = TimelineDay.bucketStart(day, bucket)
        let end = TimelineDay.bucketAfter(start, bucket)
        if let point = track.points.last(where: { Double(start) <= $0.day && $0.day < Double(end) }) {
            return Reading(value: point.value, day: Int(point.day.rounded(.down)), isInBucket: true)
        }
        guard let earlier = track.points.last(where: { $0.day < Double(start) }) else { return nil }
        return Reading(value: earlier.value, day: Int(earlier.day.rounded(.down)), isInBucket: false)
    }

    static func text(_ reading: Reading?, key: String, wording: TimelineWording) -> String {
        guard let reading else { return String(localized: "timeline.values.noValue") }
        let value = wording.value(reading.value, key: key)
        guard !reading.isInBucket else { return value }
        return String(localized: "timeline.values.onDay \(value) \(TimelineAccessibility.day(reading.day))")
    }

    /// The value under a line's name, with or without a chosen period: one
    /// quiet style, so picking a moment changes the number, not its weight.
    static let valueRole: HLTextRole = .rowSubtitle

    private var tick: some View {
        Capsule()
            .fill(row.color)
            .frame(width: 10, height: 3)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    private var title: some View {
        Text(row.title)
            .hlText(.rowTitle)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var value: some View {
        if let day = store.selectedDay {
            let reading = Self.reading(of: row.track, at: day, bucket: bucket)
            Text(Self.text(reading, key: row.id, wording: wording))
                .hlText(Self.valueRole)
                .lineLimit(1)
                .contentTransition(.numericText())
        } else if let latest = row.latest {
            Text(latest)
                .hlText(Self.valueRole)
                .lineLimit(1)
        } else {
            Text("timeline.values.noneInWindow")
                .hlText(.footnote)
                .lineLimit(layout == .column ? 2 : 1)
        }
    }
}

/// The board's card, or none on a short window.
/// The board's columns at a width: card inset, name column and plot.
struct TimelineBoardColumns: Equatable {
    let inset: CGFloat
    let label: CGFloat
    let plot: CGFloat
}

private struct TimelineBoardSurface: ViewModifier {
    let isCard: Bool

    func body(content: Content) -> some View {
        if isCard {
            HLCard { content }
        } else {
            content
        }
    }
}
