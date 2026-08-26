import SwiftUI

/// v0.13.1 UX-D8/D2 — the ONE canonical **per-page** header for the Insights
/// pager pages.
///
/// Unifies the header *anatomy* across every page hosted in the Insights pager
/// (`InsightsContainerScreen`): the numeric metric pages (`InsightsMetricScreen.
/// metricHeader`) and the special pages (Mood / Medications / Workouts). Before
/// this, the metric pages rendered a large-title header with an equal-circle
/// trailing action slot, while the special pages rendered a smaller
/// `InsightsSectionHeader` (headline title + trailing caption) — so the
/// top-of-page region visually "jumped" when the operator swiped between a
/// metric page and Mood in the SAME pager (the operator's "gear missing /
/// header different on some Insights pages" report).
///
/// This primitive gives every page the IDENTICAL header shape:
///   - the metric/page title left-aligned in `.hlLargeTitle`,
///   - the equal-sized trailing action circles (`InsightsHeaderActionCircle`)
///     in a slot that stays put across pages,
///   - an optional subtitle/description line rendered BELOW the title.
///
/// **No dead affordances:** the trailing slot only renders circles a caller
/// passes. A page with no meaningful gear/coach passes none, so the slot is
/// empty — but the title anatomy still matches, so the top-right region no
/// longer jumps between pages.
///
/// **Monochrome:** title `HLText.primary`, subtitle `HLText.secondary` — no
/// colour, no glass on the text. Matches `InsightsMetricScreen.metricHeader`.
struct InsightsPageHeader<Actions: View>: View {
    let title: LocalizedStringKey
    /// Optional sub-line rendered below the title (the page's count / window
    /// caption). Mirrors `InsightsMetricScreen.descriptionSlot` placement.
    var subtitle: LocalizedStringKey?
    /// Stable accessibility identifier suffix for the title (e.g. "mood").
    var accessibilityIdentifierSuffix: String?
    /// The trailing equal-circle action slot. Empty for pages with no
    /// meaningful gear/coach — the slot still reserves the canonical anatomy.
    @ViewBuilder var actions: () -> Actions

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        accessibilityIdentifierSuffix: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifierSuffix = accessibilityIdentifierSuffix
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .center, spacing: HLSpace.md) {
                Text(title)
                    .font(.hlLargeTitle)
                    .foregroundStyle(HLText.primary)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(OptionalHeaderIdentifier(suffix: accessibilityIdentifierSuffix))

                Spacer(minLength: 0)

                actions()
            }

            if let subtitle {
                Text(subtitle)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Applies a header accessibility identifier only when a suffix is supplied.
private struct OptionalHeaderIdentifier: ViewModifier {
    let suffix: String?

    func body(content: Content) -> some View {
        if let suffix {
            content.accessibilityIdentifier("insights.page.header.title.\(suffix)")
        } else {
            content
        }
    }
}
