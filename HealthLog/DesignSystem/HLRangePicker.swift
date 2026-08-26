import SwiftUI

/// v0.11 — the ONE canonical period / time-range control for every chart.
///
/// **Why this exists (AUDIT-FINAL §H2):** before v0.11 there were FOUR bespoke
/// period controls — `ChartDetailScreen.RangePicker`, `FullscreenRangePicker`,
/// `TrendsOverlayCard.picker`, and the mood `MoodPeriodControl` — each with its
/// own styling, a11y label, and placement. The operator wanted "one period
/// control, same options, same look, same behaviour everywhere."
///
/// `HLRangePicker` collapses all four onto one type: a native
/// `Picker(.segmented).tint(HLText.primary)` (the Apple-Health segmented look —
/// full VoiceOver rotor, Dynamic-Type-safe, monochrome chrome per the
/// single-accent doctrine) over any enum conforming to `HLRangeOption`. Every
/// chart with a range now renders the identical control.
protocol HLRangeOption: CaseIterable, Identifiable, Hashable {
    /// Short Apple-Health-style segment label ("W", "M", "6M", "J", …).
    var label: String { get }
    /// Full VoiceOver label for the segment ("Week", "Month", …).
    var rangeAccessibilityLabel: String { get }
}

/// Canonical segmented range control. Two presentation styles:
/// - `.bar` (default) — the sticky chrome treatment used at the top of
///   `ChartDetailScreen` / bottom of `FullscreenChartCover` (horizontal +
///   vertical padding + a translucent material backing so chart content can
///   scroll underneath).
/// - `.inline` — bare segmented control for use inside a card's `VStack`
///   (TrendsOverlayCard), no material backing.
struct HLRangePicker<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    enum Style {
        /// Sticky chrome: padded + material backing. For `safeAreaInset` hosts.
        case bar
        /// Bare control for inline placement inside a card.
        case inline
    }

    @Binding var selection: Option
    var style: Style = .bar

    var body: some View {
        switch style {
        case .bar:
            picker
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.sm)
                .frame(maxWidth: .infinity)
                .background(HLMaterialBackground())
        case .inline:
            picker
        }
    }

    private var picker: some View {
        Picker(String(localized: "Time range"), selection: $selection) {
            ForEach(Array(Option.allCases)) { option in
                Text(option.label)
                    .accessibilityLabel(Text(option.rangeAccessibilityLabel))
                    .tag(option)
            }
        }
        // v0.6.1.6 — Y6 — AP-005: lock the selected segment to the chart-chrome
        // monochrome key (handbook §2.8), independent of the scene-root accent.
        .pickerStyle(.segmented)
        .tint(HLText.primary)
        .accessibilityLabel(Text("Select time range"))
        // Honour reduce-motion at the call-site's chart `.hlAnimation`; the
        // segment-slide here is the system default (already reduce-motion-aware).
        .sensoryFeedback(.selection, trigger: selection)
    }
}
