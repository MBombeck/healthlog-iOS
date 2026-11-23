import Charts
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// The ONE canonical scrub-to-read primitive for every time-series
/// chart in the app.
///
/// **Why this exists (AUDIT-FINAL §H1):** before v0.11 only `ChartDetailScreen`
/// + `FullscreenChartCover` were scrubbable — touch any of the other nine
/// time-series charts (Mood, Stability, Workout-HR, Trends-raw, …) and nothing
/// happened. Same visual vocabulary, totally different interaction contract.
/// That inconsistency *was* the operator's #1 recurring pain ("I couldn't
/// operate the slider; I want ALL charts to work the SAME").
///
/// `HLChartScrubber` extracts the working `chartXSelection` + dashed RuleMark +
/// floating callout + selection-haptic + VoiceOver announcement out of
/// `ChartDetailScreen` into one reusable pair:
///
/// 1. `HLChartScrubber.marks(selectedDate:in:keyPath:value:callout:)` — a
///    `@ChartContentBuilder` that emits the dashed vertical `RuleMark` at the
///    nearest point + an emphasized `PointMark` + a top-pinned callout. Drop it
///    INSIDE a `Chart { … }` after the data marks.
/// 2. `.hlChartScrub(_:)` — a `View` modifier that wires `chartXSelection`
///    (first-class hit-testing, NOT a hand-rolled `DragGesture`, so it coexists
///    with a parent `ScrollView`) + the declarative selection-haptic + a
///    VoiceOver announcement on change.
///
/// Every scrubbable chart shows the same callout (``HLScrubCallout``): the
/// metric chart formats its `SeriesPoint` through ``HLSeriesPointCallout``,
/// which draws the same card. A second series (the diastolic of a blood
/// pressure) gets its own dot through the `secondary:` overload.
enum HLChartScrubber {
    /// Scrub overlay marks for a generic ascending `(date, value)` series.
    ///
    /// Emits nothing when `selectedDate` is `nil` (resting state) or the series
    /// is empty. Otherwise it snaps to the nearest point by absolute time
    /// distance and draws the dashed rule + emphasized dot + callout — visually
    /// identical to the canonical `ChartDetailScreen` scrubber.
    ///
    /// - Parameters:
    ///   - selectedDate: the `chartXSelection` binding's current value.
    ///   - points: the ascending data series (any element type).
    ///   - date: keypath to each element's x-axis `Date`.
    ///   - value: keypath to each element's y-axis `Double`.
    ///   - callout: builds the floating callout for the snapped element.
    @ChartContentBuilder
    static func marks<P>(
        selectedDate: Date?,
        in points: [P],
        date: KeyPath<P, Date>,
        value: KeyPath<P, Double>,
        @ViewBuilder callout: (P) -> some View
    ) -> some ChartContent {
        if let selectedDate, let nearest = nearest(to: selectedDate, in: points, date: date) {
            RuleMark(x: .value(String(localized: "chart.scrubber.selection"), nearest[keyPath: date]))
                .foregroundStyle(HLChartTints.seriesMid)
                .lineStyle(StrokeStyle(
                    lineWidth: HLChartGrid.thresholdWidth,
                    dash: HLChartGrid.thresholdDash
                ))
                .annotation(
                    position: .top,
                    spacing: HLSpace.xs,
                    // Fit the callout vertically inside the chart
                    // bounds too. Previously `y: .disabled` let a `.top`-pinned
                    // callout render above the plot and get clipped by the
                    // enclosing card (operator: value readout cut off / invisible
                    // when scrubbing a high data point).
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    callout(nearest)
                }
            PointMark(
                x: .value(String(localized: "chart.scrubber.selection"), nearest[keyPath: date]),
                y: .value(String(localized: "Value"), nearest[keyPath: value])
            )
            .foregroundStyle(HLChartTints.series)
            .symbolSize(selectionSymbolSize)
        }
    }

    /// Scrub overlay for a two-line series (blood pressure): the same rule,
    /// dot and callout as above, plus a lighter dot on the second value where
    /// the snapped element has one.
    @ChartContentBuilder
    static func marks<P>(
        selectedDate: Date?,
        in points: [P],
        date: KeyPath<P, Date>,
        value: KeyPath<P, Double>,
        secondary: KeyPath<P, Double?>,
        @ViewBuilder callout: (P) -> some View
    ) -> some ChartContent {
        marks(selectedDate: selectedDate, in: points, date: date, value: value, callout: callout)
        if let selectedDate, let nearest = nearest(to: selectedDate, in: points, date: date),
           let second = nearest[keyPath: secondary]
        {
            PointMark(
                x: .value(String(localized: "chart.scrubber.selection"), nearest[keyPath: date]),
                y: .value(String(localized: "Value"), second)
            )
            .foregroundStyle(HLChartTints.seriesLow)
            .symbolSize(selectionSymbolSize)
        }
    }

    /// Area of the emphasised dot under the scrub rule. Larger than any
    /// series symbol, so the dot the callout describes is never ambiguous.
    static let selectionSymbolSize: CGFloat = 120

    /// The haptic every scrub plays when the snapped point changes.
    static let haptic: SensoryFeedback = .selection

    /// Nearest element to `date` by absolute time distance. `nil` for an empty
    /// series. Pure + `nonisolated` so the snap contract is unit-testable.
    nonisolated static func nearest<P>(
        to date: Date,
        in points: [P],
        date keyPath: KeyPath<P, Date>
    ) -> P? {
        points.min(by: {
            abs($0[keyPath: keyPath].timeIntervalSince(date)) < abs($1[keyPath: keyPath].timeIntervalSince(date))
        })
    }
}

/// The one floating callout of every scrubbable chart: the date in caption
/// type, the value in the rounded metric face, the unit beside it.
///
/// An opaque raised surface, not glass: the callout lies on the plot, and
/// glass over a coloured curve takes up its colours in patches, so the
/// value would stand on yellow and red. No rim and no shadow of its own.
/// `marksRecord` adds the star of a personal best.
struct HLScrubCallout: View {
    let title: String
    let value: String
    let unit: String?
    let marksRecord: Bool

    /// The callout's surface, in light and dark.
    static let surface: Color = HLColor.surfaceElevated

    /// Widest the callout grows, so it never covers more than half a plot.
    static let maxWidth: CGFloat = 220

    init(title: String, value: String, unit: String? = nil, marksRecord: Bool = false) {
        self.title = title
        self.value = value
        self.unit = unit
        self.marksRecord = marksRecord
    }

    /// What VoiceOver reads: date, value and unit, then the record note.
    static func spokenText(title: String, value: String, unit: String?, marksRecord: Bool) -> String {
        let reading = [value, unit].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        let record = marksRecord ? ", " + String(localized: "Personal best") : ""
        return "\(title), \(reading)\(record)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(title)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                Text(value)
                    .font(.hlMetric(.title3))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
                if marksRecord {
                    Image(systemName: "star.fill")
                        .font(.hlIcon(HLIconSize.xs, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(HLSpace.sm)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spokenText(title: title, value: value, unit: unit, marksRecord: marksRecord)))
    }
}

extension View {
    /// Wires the canonical chart-scrub interaction: `chartXSelection`
    /// (scroll-safe first-class hit-testing) + the declarative selection-haptic
    /// + a VoiceOver announcement when the snapped point changes. Apply to the
    /// `Chart` view; pair with `HLChartScrubber.marks(…)` inside its content.
    ///
    /// - Parameters:
    ///   - selectedDate: the selection binding (also drives the overlay marks).
    ///   - announcement: optional VoiceOver string for the newly-snapped point;
    ///     return `nil` to skip (e.g. when nothing is under the cursor).
    func hlChartScrub(
        _ selectedDate: Binding<Date?>,
        announcement: @escaping (Date) -> String? = { _ in nil }
    ) -> some View {
        modifier(HLChartScrubModifier(selectedDate: selectedDate, announcement: announcement))
    }
}

/// The scrub interaction behind ``SwiftUI/View/hlChartScrub(_:announcement:)``.
/// Touch selects through `chartXSelection`; a pointer (iPad trackpad or mouse)
/// selects by hovering, with the same rule, dot and callout.
private struct HLChartScrubModifier: ViewModifier {
    let selectedDate: Binding<Date?>
    let announcement: (Date) -> String?

    /// Where the pointer stands over the chart, `nil` when it is elsewhere.
    @State private var hoverLocation: CGPoint?

    func body(content: Content) -> some View {
        content
            .chartXSelection(value: selectedDate)
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
            // The overlay only translates the pointer into a date; it takes no
            // touches, so the touch selection underneath keeps working.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .allowsHitTesting(false)
                        .onChange(of: hoverLocation) { _, location in
                            selectedDate.wrappedValue = HLChartScrubber.hoverDate(
                                at: location,
                                plotFrame: proxy.plotFrame.map { geometry[$0] }
                            ) { proxy.value(atX: $0, as: Date.self) }
                        }
                }
            }
            .sensoryFeedback(HLChartScrubber.haptic, trigger: selectedDate.wrappedValue)
            .onChange(of: selectedDate.wrappedValue) { _, newValue in
                #if canImport(UIKit)
                    guard UIAccessibility.isVoiceOverRunning,
                          let newValue, let text = announcement(newValue) else { return }
                    UIAccessibility.post(notification: .announcement, argument: text)
                #endif
            }
    }
}

extension HLChartScrubber {
    /// The date under the pointer: `nil` when the pointer has left or stands
    /// outside the plot, else the date at its x position inside the plot.
    /// `dateAtX` reads the chart's scale and is handed in, so the rule is
    /// testable without a chart.
    static func hoverDate(
        at location: CGPoint?,
        plotFrame: CGRect?,
        dateAtX: (CGFloat) -> Date?
    ) -> Date? {
        guard let location, let plotFrame, plotFrame.contains(location) else { return nil }
        return dateAtX(location.x - plotFrame.minX)
    }
}
