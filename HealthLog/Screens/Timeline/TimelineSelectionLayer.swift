import Accessibility
import SwiftUI
import UIKit

/// The chosen period across every row, and the way to choose it: a tap on a
/// moment, a press and drag along the axis, the pointer moving over it on
/// the iPad. Only this layer and the summary follow the choice, the rows
/// stay as they are, so the band moves without a hitch.
///
/// The same layer zooms the axis with two fingers (or a pinch on the
/// trackpad), around the point between them, and moves it with a sideways
/// swipe; an upright swipe stays the page's scroll.
struct TimelineSelectionLayer: View {
    let store: TimelineStore
    let window: TimelineWindow
    let bucket: TimelineBucket
    let width: CGFloat

    /// The window when a pinch or a swipe began; `nil` between gestures.
    @State private var gestureStart: TimelineWindow?
    @State private var isScrubbing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let day = store.summaryDay {
                band(for: day)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { select(at: $0.location.x) })
        // Press, hold and drag scrubs along the axis. A UIKit long press: it
        // fails as soon as the finger moves before the hold, so an upright
        // swipe anywhere over the board stays the page's scroll. The SwiftUI
        // drag with no minimum distance that stood here held every touch
        // and the board only scrolled at its edges (device test of 312).
        .gesture(TimelineHoldScrub { x in
            isScrubbing = true
            select(at: x)
        } onEnd: {
            isScrubbing = false
        })
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard width > 0 else { return }
                    let start = gestureStart ?? window
                    if gestureStart == nil { gestureStart = window }
                    store.zoom(from: start, scale: value.magnification, anchor: value.startLocation.x / width)
                }
                .onEnded { _ in gestureStart = nil }
        )
        // A sideways swipe moves the axis. A UIKit pan that only begins
        // sideways: an upright drag never starts it, so the page scrolls.
        .gesture(TimelineSidewaysPan { distance in
            guard !isScrubbing, width > 0 else { return }
            let start = gestureStart ?? window
            if gestureStart == nil { gestureStart = window }
            store.pan(from: start, days: Self.days(forSwipe: distance, width: width, span: start.span))
        } onEnd: {
            gestureStart = nil
        })
        .onContinuousHover { phase in
            if case let .active(location) = phase { select(at: location.x) }
        }
        .sensoryFeedback(.selection, trigger: store.selectedDay.map { TimelineDay.bucketStart($0, bucket) })
        .accessibilityHidden(true)
    }

    private func band(for day: Int) -> some View {
        let range = Self.bandRange(day: day, bucket: bucket, window: window, width: width)
        return RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
            .fill(HLText.primary.opacity(0.06))
            .frame(width: range.width)
            .frame(maxHeight: .infinity)
            .offset(x: range.minX)
            .allowsHitTesting(false)
    }

    /// The bucket that holds `day`, in points, at least 6 pt wide.
    nonisolated static func bandRange(
        day: Int,
        bucket: TimelineBucket,
        window: TimelineWindow,
        width: CGFloat
    ) -> (minX: CGFloat, width: CGFloat) {
        let start = max(TimelineDay.bucketStart(day, bucket), window.from)
        let end = min(TimelineDay.bucketAfter(TimelineDay.bucketStart(day, bucket), bucket), window.to + 1)
        let left = CGFloat(window.fraction(Double(start))) * width
        let right = CGFloat(window.fraction(Double(end))) * width
        let bandWidth = max(6, right - left)
        return (min(left, width - bandWidth), bandWidth)
    }

    /// A swipe of `distance` points moves the axis the other way, the
    /// content following the finger.
    nonisolated static func days(forSwipe distance: CGFloat, width: CGFloat, span: Int) -> Int {
        guard width > 0 else { return 0 }
        return Int((-distance / width * CGFloat(span)).rounded())
    }

    /// The day under `x`; a move inside the same bucket changes nothing.
    private func select(at x: CGFloat) {
        guard width > 0 else { return }
        let day = window.day(atFraction: Double(x / width))
        if let current = store.selectedDay, TimelineDay.bucketStart(current, bucket) == TimelineDay.bucketStart(day, bucket) {
            return
        }
        store.selectedDay = day
    }
}

// MARK: - VoiceOver

extension View {
    /// A value row as one element: its name, its newest value and the
    /// direction of the last step, with the line as an audio graph.
    func timelineValueAccessibility(_ row: TimelineValueRow, window: TimelineWindow) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.title))
            .accessibilityValue(Text(TimelineAccessibility.value(row)))
            .accessibilityChartDescriptor(TimelineValueChartDescriptor(row: row, window: window))
    }

    /// A lane as one element: its name and what it holds in the window.
    func timelineLaneAccessibility(_ lane: TimelineLaneTrack, wording: TimelineWording, window: TimelineWindow) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(wording.title(forLane: lane.key)))
            .accessibilityValue(Text(TimelineAccessibility.value(lane, window: window)))
    }
}

enum TimelineAccessibility {
    static func value(_ row: TimelineValueRow) -> String {
        guard let latest = row.latest else { return String(localized: "timeline.values.noneInWindow") }
        return [latest, row.trend, range(row.track.band)].compactMap { $0 }.joined(separator: ", ")
    }

    /// The reference range of a lab line in words: "Referenzbereich bis 60".
    static func range(_ band: TimelineLabBand?) -> String? {
        let number = { (value: Double) in HLNumberFormat.decimal(value, maximumFractionDigits: 2) }
        switch (band?.low, band?.high) {
        case let (low?, high?): return String(localized: "timeline.labs.rangeBetween \(number(low)) \(number(high))")
        case let (nil, high?): return String(localized: "timeline.labs.rangeUpTo \(number(high))")
        case let (low?, nil): return String(localized: "timeline.labs.rangeFrom \(number(low))")
        default: return nil
        }
    }

    /// "Trulicity 5 mg, seit 3. Sept.; Lisinopril 5 mg, seit …"
    static func value(_ lane: TimelineLaneTrack, window: TimelineWindow) -> String {
        lane.rows.flatMap { row -> [String] in
            let bars = row.bars.filter { !$0.isPause }.map { bar -> String in
                "\(name(of: bar, in: row)), \(span(bar))"
            }
            let marks = row.marks.map { "\($0.label ?? ""), \(day($0.day))" }
            return bars + marks
        }
        .joined(separator: "; ")
    }

    /// A later dose piece says only its dose: the medication's name goes first.
    private static func name(of bar: TimelineBar, in row: TimelineLaneRow) -> String {
        guard let label = bar.label else { return row.title ?? "" }
        guard let title = row.title, !label.hasPrefix(title) else { return label }
        return "\(title) \(label)"
    }

    private static func span(_ bar: TimelineBar) -> String {
        if bar.open { return String(localized: "timeline.selection.since \(day(bar.start))") }
        return String(localized: "timeline.selection.range \(day(bar.start)) \(day(bar.endExclusive - 1))")
    }

    static func day(_ number: Int) -> String {
        HLDateFormat.date(TimelineDay.date(number), style: .abbreviated)
    }
}

/// The audio graph of a value line: days on the x axis, the values on y.
struct TimelineValueChartDescriptor: AXChartDescriptorRepresentable {
    let row: TimelineValueRow
    let window: TimelineWindow

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = row.track.points
        let low = row.track.domain.lowerBound
        let high = row.track.domain.upperBound
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "timeline.chart.day"),
            range: Double(window.from) ... Double(window.to + 1),
            gridlinePositions: []
        ) { TimelineAccessibility.day(Int($0)) }
        let yAxis = AXNumericDataAxisDescriptor(
            title: row.title,
            range: low ... max(high, low + 1),
            gridlinePositions: []
        ) { HLNumberFormat.decimal($0, maximumFractionDigits: 1) }
        let series = AXDataSeriesDescriptor(
            name: row.title,
            isContinuous: row.track.source != .lab,
            dataPoints: points.map { AXDataPoint(x: $0.day, y: $0.value) }
        )
        return AXChartDescriptor(
            title: row.title,
            summary: TimelineAccessibility.value(row),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

/// A pan that begins only when the finger moves sideways, so an upright drag
/// over the board stays the page's scroll.
struct TimelineSidewaysPan: UIGestureRecognizerRepresentable {
    /// The distance moved since the pan began, in points.
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        switch recognizer.state {
        case .changed: onChange(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed: onEnd()
        default: break
        }
    }

    /// Whether a movement of `velocity` reads as sideways.
    nonisolated static func isSideways(_ velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * 1.5
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return TimelineSidewaysPan.isSideways(pan.velocity(in: pan.view))
        }
    }
}

/// Press, hold and drag: after a short hold without moving, the finger
/// scrubs along the axis. Moving before the hold fails the press, so the
/// scroll view takes an upright swipe and the sideways pan a sideways one.
struct TimelineHoldScrub: UIGestureRecognizerRepresentable {
    /// The finger's position along the layer, in its own points.
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    /// How long the finger rests before scrubbing starts.
    static let holdDuration: TimeInterval = 0.25
    /// How far the finger may drift during the hold; more is a scroll.
    static let allowableMovement: CGFloat = 10

    func makeUIGestureRecognizer(context _: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = Self.holdDuration
        recognizer.allowableMovement = Self.allowableMovement
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(context.converter.localLocation.x)
        case .ended, .cancelled, .failed: onEnd()
        default: break
        }
    }
}
