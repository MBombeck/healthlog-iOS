import Charts
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// v0.11 — the ONE canonical scrub-to-read primitive for every time-series
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
/// The two existing scrubbable charts (`ChartDetailScreen`, `FullscreenChartCover`)
/// keep their bespoke `SeriesPoint` marks because they carry BP-secondary +
/// personal-record affordances the generic path doesn't; this primitive is the
/// canonical shape every OTHER chart now adopts so the *interaction contract* is
/// identical app-wide.
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
                    // v0.11 #23 — fit the callout vertically inside the chart
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
            .symbolSize(120)
        }
    }

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

/// Canonical floating callout for the generic scrubber — a compact value +
/// caption card with the same Liquid-Glass-on-26 / elevated-surface fallback
/// treatment as `SelectedPointCallout`, so every scrubbable chart reads with
/// one callout vocabulary. Use this where the chart has no `SeriesPoint`
/// (mood, stability, workout HR, trends-raw); charts backed by `SeriesPoint`
/// keep `SelectedPointCallout` (it adds BP-secondary + PR affordances).
struct HLScrubCallout: View {
    let title: String
    let value: String
    let unit: String?

    init(title: String, value: String, unit: String? = nil) {
        self.title = title
        self.value = value
        self.unit = unit
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
            }
        }
        .padding(HLSpace.sm)
        .frame(maxWidth: 220, alignment: .leading)
        .hlGlassBackground(
            in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous),
            fallback: HLColor.surfaceElevated
        )
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .stroke(HLColor.separator, lineWidth: 0.5)
        )
        .hlShadow(HLShadow.cardLight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(value) \(unit ?? "")"))
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
        chartXSelection(value: selectedDate)
            .sensoryFeedback(.selection, trigger: selectedDate.wrappedValue)
            .onChange(of: selectedDate.wrappedValue) { _, newValue in
                #if canImport(UIKit)
                    guard UIAccessibility.isVoiceOverRunning,
                          let newValue, let text = announcement(newValue) else { return }
                    UIAccessibility.post(notification: .announcement, argument: text)
                #endif
            }
    }
}
