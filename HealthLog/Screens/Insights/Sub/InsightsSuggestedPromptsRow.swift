import SwiftUI

/// v0.11 W35 — the "Frag mich" suggested-prompts chip strip on the Insights
/// **overview**, the iOS twin of the web `SuggestedPrompts`
/// (`src/components/insights/suggested-prompts.tsx`).
///
/// **What it is:** a horizontal strip of matte capsule chips that sit directly
/// under the briefing hero. Each chip is a single localized prompt; tapping any
/// chip is a Coach affordance — it calls `onPick`, which the overview wires to
/// open the full `AskCoachSheet`. This is the third overview Coach entry
/// (header coin + whole-hero tap + this strip), mirroring the web hero's
/// always-visible quick-prompt row.
///
/// **Prefill (v0.13 WP):** the tapped chip's localized label is threaded into
/// the overview's `onPick`, which opens `AskCoachSheet(seed:)` with the composer
/// pre-filled with that prompt — the iOS equivalent of the web
/// `askCoach(prompt)` prefill. No more blank-coach landing.
///
/// **Monochrome / glass:** the chips are matte content surfaces
/// (`HLSurface.secondary`, `HLRadius.sm`) — ZERO glass (Liquid-Glass discipline
/// reserves glass for chrome, not content rows). The leading glyph is the mono
/// `quote.bubble`; colour stays signal-only (none here).
///
/// **Gating:** the call site already guards on `assistantCoach`; the in-view
/// `@Environment(FeatureFlagsStore.self)` re-check is defence-in-depth so the
/// strip can never leak a Coach surface if a future caller mounts it outside
/// that guard.
struct InsightsSuggestedPromptsRow: View {
    /// Invoked when any chip is tapped, carrying the chip's localized prompt
    /// label. The overview seeds `AskCoachSheet(seed:)` with it and presents.
    let onPick: (String) -> Void

    @Environment(FeatureFlagsStore.self) private var featureFlags
    /// Reduce-motion aware entrance — opacity-only, never a slide, matching the
    /// `InsightsCorrelationsRow` / `MoodAnalysisScreen` stagger language.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The five default prompt keys, mirroring the web `DEFAULT_PROMPT_KEYS`
    /// ordering exactly (whyMonday / weightVsPulse / weekVsMonth / tellMyDoctor
    /// / medicationWorking).
    private static let promptKeys = [
        "insights.suggestedPrompts.whyMonday",
        "insights.suggestedPrompts.weightVsPulse",
        "insights.suggestedPrompts.weekVsMonth",
        "insights.suggestedPrompts.tellMyDoctor",
        "insights.suggestedPrompts.medicationWorking"
    ]

    var body: some View {
        // Defence-in-depth gate — the call site already guards, this re-check
        // ensures the strip can never paint a Coach affordance when the
        // assistant is off.
        if featureFlags.isEnabled(.assistantCoach) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // #57 — Insights header language is the sentence-case
                // `InsightsSectionHeader`, unifying every header in the tab.
                InsightsSectionHeader("insights.suggestedPrompts.label")
                    .accessibilityIdentifier("insights.suggestedPrompts.label")

                // W44 hang-fix — the chips are laid out by a WRAPPING flow
                // `Layout`, NOT a nested horizontal `ScrollView`. The original
                // `ScrollView(.horizontal)` + `.scrollClipDisabled()` sat inside
                // the overview's vertical scroll, which itself sits inside the
                // pager's `.containerRelativeFrame([.horizontal, .vertical])`
                // horizontal paged `ScrollView`. That three-deep nesting fed the
                // pager's `.scrollPosition(id:)` resolver
                // (`ScrollStateRequestTransform.findClosestSubview` →
                // `DynamicLayoutScrollable.forEachVisibleSubview`) an
                // unbounded-width subview whose `AnimatableFrameAttribute` /
                // `CoordinateSpace` never settled, so the AttributeGraph layout
                // pass spun forever → the confirmed main-thread hang on entering
                // Insights (b116; sample at
                // `.planning/v0110-marathon/W44-hang-sample.txt`). A flow layout
                // reports a fully-BOUNDED size (it wraps to the page width
                // instead of exporting an intrinsic horizontal extent), so the
                // pager's scroll-position measurement converges in one pass.
                // Feature is preserved verbatim: the same five coach chips,
                // matte, zero glass, monochrome, gated, reduce-motion aware —
                // only the failing nested scroll is gone.
                SuggestedPromptsChipFlow(spacing: HLSpace.sm) {
                    ForEach(Self.promptKeys, id: \.self) { key in
                        chip(label: String(localized: String.LocalizationValue(key)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.suggestedPrompts")
        }
    }

    /// One matte capsule chip — `quote.bubble` glyph + prompt label. ZERO glass.
    ///
    /// **W52-1:** chip label promoted to `.hlSubhead` (was `.hlCaption`) so the
    /// prompts read at the same scale as the rest of the overview's chip/pill
    /// language; press feedback routed through the reduce-motion-gated
    /// `HLPressableButtonStyle` (was `.plain`, visually inert on tap).
    private func chip(label: String) -> some View {
        Button {
            onPick(label)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "quote.bubble")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .frame(minHeight: 36)
            .background(HLSurface.secondary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
        .hlPressable()
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(String(localized: "Opens the coach")))
        .accessibilityAddTraits(.isButton)
    }
}

/// W44 — a minimal wrapping flow `Layout` for the suggested-prompt chips.
///
/// This replaces the original nested horizontal `ScrollView`: a flow layout
/// reports a fully BOUNDED size (it wraps the chips to the proposed page width
/// rather than exporting an unbounded intrinsic horizontal extent). That is what
/// stops the pager's `.scrollPosition(id:)` resolver from re-measuring forever
/// and breaks the confirmed Insights-entry main-thread layout loop. The chips
/// wrap to fewer-per-row at large Dynamic Type instead of scrolling — the strip
/// stays one calm, self-bounding content row inside the overview's own vertical
/// scroll. Mirrors the proven `TagChipFlow` in `MoodTagInsightSection`.
private struct SuggestedPromptsChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            // Clamp each chip to the available row width so a single long prompt
            // truncates within bounds instead of overflowing the screen gutter
            // (the chip text carries `.lineLimit(1)`).
            let size = chipSize(subview, maxWidth: maxWidth)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = chipSize(subview, maxWidth: maxWidth)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// Measure a chip but never let it exceed the available row width — a long
    /// single prompt then truncates inside its capsule rather than bleeding off
    /// the screen edge.
    private func chipSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let intrinsic = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, intrinsic.width > maxWidth else { return intrinsic }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}
