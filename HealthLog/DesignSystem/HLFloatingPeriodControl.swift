import SwiftUI

/// The canonical **floating Liquid-Glass period control**.
///
/// The periods as glass segments (``HLGlassPeriodSegments``) on one
/// monochrome glass capsule, the chosen one under a springing lens. Every
/// chart page puts it at its bottom edge with
/// ``SwiftUI/View/hlPeriodBar(selection:label:isShown:)``, which lets it
/// float free, without a band under it, and gives the last content room
/// above it. It is the single
/// floating glass *control* on a screen — content cards stay flat
/// (glass-discipline §2).
///
/// From the first accessibility size on the capsule is compact: only the
/// chosen period and the menu sign, as wide as they are, so the bar does not
/// take a quarter of the screen.
///
/// Extracted from `MoodPeriodControl` so the Insights per-metric
/// screen and the Mood analysis screen share ONE bottom-floating period control
/// instead of each re-rolling the capsule + glass fallback. Generic over any
/// `HLRangeOption`, so it drives `MoodPeriod`, `ChartDetailStore.Range`, etc.
///
/// **Glass / Reduce-Transparency:** Liquid Glass (no tint — monochrome) via
/// `hlGlassEffect`. On Reduce-Transparency we skip glass entirely and paint a
/// solid `HLSurface.secondary` capsule so the control stays fully legible.
struct HLFloatingPeriodControl<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option
    /// Localized accessibility label for the control (e.g. "Period",
    /// "Time range").
    var accessibilityLabelText: LocalizedStringKey = "Period"

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Spelled out: the private environment reads would keep the memberwise
    /// initializer inside this file, and a page may host the capsule itself.
    init(selection: Binding<Option>, accessibilityLabelText: LocalizedStringKey = "Period") {
        _selection = selection
        self.accessibilityLabelText = accessibilityLabelText
    }

    /// A segmented control keeps its small type at every text size. From the
    /// first accessibility size on the control is a menu instead, which
    /// names the chosen period in full at the reader's size.
    static func usesMenu(at typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize
    }

    /// The widest the segmented capsule grows.
    static var maxWidth: CGFloat {
        320
    }

    /// Whether the capsule takes only the width of its content: the menu
    /// form, from the first accessibility size on.
    static func isCompact(at typeSize: DynamicTypeSize) -> Bool {
        usesMenu(at: typeSize)
    }

    var body: some View {
        control
            .padding(.horizontal, Self.isCompact(at: dynamicTypeSize) ? HLSpace.md : HLSpace.xs)
            .padding(.vertical, Self.isCompact(at: dynamicTypeSize) ? HLSpace.xs : 0)
            .frame(maxWidth: Self.isCompact(at: dynamicTypeSize) ? nil : Self.maxWidth)
            .modifier(FloatingCapsuleSurface(reduceTransparency: reduceTransparency))
            .padding(.horizontal, HLSpace.lg)
            .padding(.bottom, HLSpace.sm)
            .accessibilityLabel(Text(accessibilityLabelText))
    }

    @ViewBuilder
    private var control: some View {
        if Self.usesMenu(at: dynamicTypeSize) {
            Picker(selection: $selection) {
                ForEach(Array(Option.allCases)) { option in
                    Text(option.rangeAccessibilityLabel).tag(option)
                }
            } label: {
                Text(accessibilityLabelText)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(HLText.primary)
            .frame(minHeight: HLHitTarget.minimum)
            .fixedSize()
            .sensoryFeedback(.selection, trigger: selection)
        } else {
            // The segments stand directly on the glass, no track of their
            // own: the chosen one is a soft lens that glides over on a spring.
            HLGlassPeriodSegments(selection: $selection)
        }
    }
}

/// The segments of the floating period control: one button per period on the
/// capsule's glass, the chosen one under a soft lens that springs from segment
/// to segment (`matchedGeometryEffect`), with the selection haptic. A label
/// never wraps; at the larger standard sizes it shrinks a little, from the
/// first accessibility size on the control is a menu instead.
struct HLGlassPeriodSegments<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option

    @Namespace private var lens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of a segment: the hit target, so every period is easy to hit.
    /// The lens stands inside it with the capsule's side inset all round,
    /// so lens and capsule are concentric.
    static var segmentHeight: CGFloat {
        HLHitTarget.minimum
    }

    /// The glide of the lens; without motion it moves at once.
    static func lensAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Option.allCases)) { option in
                segment(option)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Select time range"))
        .accessibilityIdentifier("hl.periodBar")
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            withAnimation(Self.lensAnimation(reduceMotion: reduceMotion)) { selection = option }
        } label: {
            Text(option.label)
                .font(.hlSubhead.weight(isSelected ? .semibold : .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? HLText.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.xs)
                .frame(maxWidth: .infinity, minHeight: Self.segmentHeight)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(HLText.primary.opacity(0.1))
                            .overlay(Capsule().strokeBorder(HLText.primary.opacity(0.12), lineWidth: 0.5))
                            .matchedGeometryEffect(id: "lens", in: lens)
                            .padding(.vertical, HLSpace.xs)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.rangeAccessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The capsule's surface: Liquid Glass (no tint — monochrome). On
/// Reduce-Transparency we skip glass entirely and paint a solid
/// `HLSurface.secondary` capsule so the control stays fully legible.
private struct FloatingCapsuleSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(HLSurface.secondary, in: Capsule())
        } else {
            content.hlGlassEffect(in: Capsule(), interactive: true, fallback: HLSurface.secondary)
        }
    }
}

extension View {
    /// The period bar of a detail page: the floating period control at the
    /// bottom edge, on the phone and the pad alike. The capsule floats free
    /// over the page, as in 1.5: a `safeAreaInset`, not a bar, so the system
    /// lays no scroll edge band or backdrop under it and only the glass
    /// capsule stands over the content. The inset is the page's bottom
    /// room: the scroll content ends above the capsule, so scrolled to its
    /// end no chart or card stays under it. The capsule is at most
    /// ``HLFloatingPeriodControl/maxWidth`` wide and centred in the page, so
    /// on a wide page it stands over the content column, not across the
    /// window.
    /// `isShown` hides the bar where there is nothing to choose a period
    /// for (the mood page without entries).
    func hlPeriodBar<Option: HLRangeOption>(
        selection: Binding<Option>,
        label: LocalizedStringKey = "Period",
        isShown: Bool = true
    ) -> some View where Option.AllCases: RandomAccessCollection {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isShown {
                // 8 pt of room above the capsule, so the last card ends
                // clear of it.
                HLFloatingPeriodControl(selection: selection, accessibilityLabelText: label)
                    .padding(.top, HLSpace.sm)
            }
        }
        // The same periods in the menu bar's "Period" menu, with shortcuts,
        // from the page that is on screen only.
        .modifier(HLPeriodCommandPublisher(command: HLPeriodCommand(selection: selection), isShown: isShown))
    }
}
