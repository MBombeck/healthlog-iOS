import SwiftUI

/// W-FILELEN (v0153 I2/I3) — the Insights tab-strip pill view-builders, split out
/// of `InsightsMetricTabStrip.swift` to keep that file under the length ceiling.
/// These are the `pill` / `customizePill` builders the strip body calls (the
/// category pill is now an inline native `Menu`, so the v0153 accordion
/// `headerPill` / `childPill` builders are gone).
extension InsightsMetricTabStrip {
    /// The trailing "customise the strip" affordance. A quiet,
    /// circular, monochrome pencil pill that sits after the last metric pill so
    /// the operator can reorder + show/hide the strip tabs. Matches the
    /// unselected-pill treatment (recessed well + hairline) so it reads as
    /// chrome, not a metric.
    func customizePill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous).fill(HLSurface.tertiary)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.hlRow)
        .accessibilityLabel(String(localized: "Customize tab strip"))
        .accessibilityHint(String(localized: "Reorder or show and hide metrics"))
        .accessibilityIdentifier("insights.tabStrip.customize")
    }

    /// The widest a pill's title may get: the strip's width less the
    /// strip's margins, the capsule's padding and anything else in the pill
    /// (`trailing`, such as the chevron of a category). `nil` until the
    /// strip has been measured, so the first layout is unconstrained.
    nonisolated static func pillTitleMaxWidth(stripWidth: CGFloat, trailing: CGFloat = 0) -> CGFloat? {
        let width = stripWidth - 2 * HLSpace.lg - 2 * HLSpace.md - trailing
        return width > 0 ? width : nil
    }

    /// How far a pill's title may shrink: a little at the standard sizes,
    /// down to half where a single word can outgrow the screen.
    nonisolated static func pillTitleScale(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 0.5 : 0.8
    }

    func pill(
        title: String,
        accessibilityTitle: String? = nil,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.hlSubhead.weight(.semibold))
                // Keep the pill single-line so a multi-word
                // category label can't wrap to two lines inside the capsule at
                // large Dynamic Type and break the uniform pill height.
                .lineLimit(1)
                // At the largest sizes a long name ("Sauerstoffsättigung") is
                // wider than the screen; it shrinks into the strip instead of
                // pushing the capsule past both edges.
                .minimumScaleFactor(Self.pillTitleScale(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize))
                .modifier(InsightsPillTitleCap(width: Self.pillTitleMaxWidth(stripWidth: stripWidth)))
                // W22-W22 (operator felt-refine #4) — on the canonical mono
                // scale every sibling surface uses. Selected: an inverted label
                // (`HLSurface.primary`) on a filled `HLText.primary` capsule;
                // unselected: `HLText.secondary` on a recessed `HLSurface
                // .tertiary` well. Replaces the off-doctrine `HLColor.background`
                // / `backgroundEleva` fills that read a hair off neighbouring
                // cards (audit P1-3).
                .foregroundStyle(isSelected ? HLSurface.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(HLSurface.tertiary))
                }
                .overlay {
                    if !isSelected {
                        Capsule(style: .continuous)
                            .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.hlRow)
        // VoiceOver hears the page's full name behind a shortened pill.
        .accessibilityLabel(Text(verbatim: accessibilityTitle ?? title))
        // One tick from the strip in view, not one from every page's strip.
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected && isOnVisiblePage }
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Caps a pill title at `width`. A plain `.frame(maxWidth:)` does not do it in
/// a horizontal scroll view: the scroll view proposes no width, the frame
/// passes that on, and the title lays out at its full length.
struct InsightsPillTitleCap: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        InsightsCappedWidthLayout(cap: width) { content }
    }
}

/// Proposes the smaller of the child's natural width and the cap.
struct InsightsCappedWidthLayout: Layout {
    let cap: CGFloat?

    nonisolated static func width(natural: CGFloat, cap: CGFloat?) -> CGFloat {
        guard let cap else { return natural }
        return min(natural, cap)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = Self.width(natural: child.sizeThatFits(.unspecified).width, cap: cap)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let child = subviews.first else { return }
        child.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
