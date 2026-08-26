import SwiftUI

/// v0.11 W22-W22 — the canonical **floating Liquid-Glass period control**.
///
/// A segmented `HLRangePicker` (`.inline` — no chrome) hosted inside a
/// monochrome glass capsule, designed to be presented via
/// `safeAreaInset(edge: .bottom)`. It is the single floating glass *control*
/// on a screen — content cards stay flat (glass-discipline §2).
///
/// Extracted from `MoodPeriodControl` (DESIGN-A §1.2) so the Insights per-metric
/// screen and the Mood analysis screen share ONE bottom-floating period control
/// instead of each re-rolling the capsule + glass fallback. Generic over any
/// `HLRangeOption`, so it drives `MoodPeriod`, `ChartDetailStore.Range`, etc.
///
/// **Glass / Reduce-Transparency:** Liquid Glass on iOS 26 (no tint —
/// monochrome) via `hlGlassEffect`; on iOS 18-25 the fallback paints a solid
/// `HLSurface.secondary` capsule. On Reduce-Transparency we skip glass entirely
/// and paint the solid capsule so the control stays fully legible (§2.4).
struct HLFloatingPeriodControl<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option
    /// Localized accessibility label for the control (e.g. "Period",
    /// "Time range").
    var accessibilityLabelText: LocalizedStringKey = "Period"

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Drive the segments through the canonical `HLRangePicker` (`.inline`
        // style — no chrome) so the control behaves identically to every other
        // chart's range control; the floating glass capsule is the only dressing.
        HLRangePicker(selection: $selection, style: .inline)
            .labelsHidden()
            .padding(.horizontal, HLSpace.xs)
            .padding(.vertical, HLSpace.xs)
            .frame(maxWidth: 320)
            .modifier(FloatingCapsuleSurface(reduceTransparency: reduceTransparency))
            .padding(.horizontal, HLSpace.lg)
            .padding(.bottom, HLSpace.sm)
            .accessibilityLabel(Text(accessibilityLabelText))
    }
}

/// The capsule's surface: Liquid Glass on iOS 26 (no tint — monochrome), or a
/// solid `HLSurface.secondary` fill on the iOS 18-25 fallback. On
/// Reduce-Transparency we skip glass entirely and paint the solid capsule so
/// the control stays fully legible (DESIGN-A §2.4).
private struct FloatingCapsuleSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(HLSurface.secondary, in: Capsule())
        } else {
            content.hlGlassEffect(in: Capsule(), fallback: HLSurface.secondary)
        }
    }
}
