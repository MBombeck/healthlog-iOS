import SwiftUI

/// **C1 (walkthrough 2026-08-22) — the one follow-up shape for a discovered
/// correlation, rendered in place.**
///
/// The operator's complaint was not that the block is wrong; it is that some of
/// its entries end where the question begins („Einträge, denen man nicht weiter
/// nachgehen kann"). The card states a relationship, an interpretation and two
/// numbers, and then stops. Two of its three footer affordances are conditional
/// — the coach link on the coach surface being available, the relevance control
/// on the server having handed over a pattern handle — so a card could
/// legitimately render with no way out of it at all.
///
/// This section is the way out, and it is the SAME way out for every pair. The
/// uniformity is the design, not a shortcut: an affordance that appeared only
/// for the pairs with a metric page would teach the reader that some rows are
/// inert, which is exactly the impression C1 is about. So every card carries one
/// disclosure, it always opens this, and the difference between a pair that can
/// be pursued deeper and one that cannot is stated **here, in words**.
///
/// **Why in place rather than as a sheet.** A sheet was the first shape and it
/// was withdrawn on a hard constraint, not on taste: `.sheet` is a presentation
/// the frozen Phase-06 PHI-presentation inventory counts, that inventory is
/// fail-closed against NEW hits under `HealthLog/App` and `HealthLog/Screens`,
/// and 06-06 owns every privacy disposition in it. A later plan may record that
/// a presentation went away; it may not mint one. Hiding the presentation in a
/// file the scanner does not sample would have satisfied the gate by leaving the
/// census rather than by respecting it. An inline disclosure adds no
/// presentation at all — and for four lines of explanation it is the calmer
/// answer anyway.
///
/// **Nothing is recomputed.** The drill-in targets come from the block's own
/// `drillIns(for:)`, so this section and the card can never disagree about what
/// a pair reaches.
struct InsightsCorrelationFollowUpSection: View {
    let pair: DiscoveredCorrelation
    /// Deep-links a channel into its own Insights page. `nil` (no host wiring)
    /// leaves only the explanation, which is still an honest follow-up.
    var onSelectMetric: ((MetricKind) -> Void)?

    private var drillIns: [MetricKind] {
        InsightsCorrelationsDiscoveryBlock.drillIns(for: pair)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if drillIns.isEmpty || onSelectMetric == nil {
                Text("insights.correlations.detail.noPage")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.correlations.detail.noPage")
            } else {
                ForEach(drillIns, id: \.self) { kind in
                    metricLink(kind)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HLSpace.xs)
    }

    private func metricLink(_ kind: MetricKind) -> some View {
        Button {
            onSelectMetric?(kind)
        } label: {
            HStack(spacing: HLSpace.sm) {
                Text(verbatim: String(
                    format: String(localized: "insights.correlations.detail.openMetric"),
                    kind.displayName
                ))
                .font(.hlSubhead)
                Spacer(minLength: HLSpace.sm)
                Image(systemName: "chevron.right")
                    .font(.hlIcon(HLIconSize.sm))
            }
            .foregroundStyle(HLText.primary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights.correlations.detail.metric.\(kind.rawValue)")
    }
}
