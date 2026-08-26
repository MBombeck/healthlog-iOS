import SwiftUI

/// v0.11 reconcile (MED-2) — the ONE canonical section header for the Insights
/// overview. The iOS twin of the web's section header
/// (`src/components/insights/{trends-row,correlation-row}.tsx`):
/// `flex items-baseline justify-between` → **bold sentence-case title leading +
/// muted caption trailing-baseline**.
///
/// **Why one primitive:** before this, Trends / Notable / Relationships each
/// shipped a different header treatment (uppercase-tracked label vs. caption-
/// only vs. bold-inside-panel) — three visual languages stacked in one scroll
/// column. This unifies them so the overview reads as a single design language
/// (PROJECT_GUIDE.md cross-screen-consistency check).
///
/// **Monochrome:** title is `HLText.primary`, subtitle `HLText.tertiary` — no
/// colour, no glass. Matches the web's `font-semibold` h2 + `text-muted xs`.
struct InsightsSectionHeader: View {
    let title: LocalizedStringKey
    /// Optional trailing caption (the web's muted `xs` subtitle). Omitted when a
    /// section has no subtitle (e.g. the Dynamics "Notable this week" row).
    var subtitle: LocalizedStringKey?
    /// When `true` the header drops its `HLSpace.xs` horizontal inset so its
    /// leading edge sits **flush** with an unpadded prose body beneath it
    /// (I-0 Item 1: the Einschätzung heading must share the left edge of the
    /// assessment prose, which carries no matching inset). Overview sections
    /// keep the default inset because their content (cards / grids) is itself
    /// inset by `HLSpace.xs` — flattening them globally would misalign the
    /// already-correct sections.
    var flush: Bool = false

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, flush: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.flush = flush
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Spacer(minLength: HLSpace.sm)
                Text(subtitle)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, flush ? 0 : HLSpace.xs)
    }
}
