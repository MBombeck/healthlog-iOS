import SwiftUI

/// Cross-episode retrospective insights (v1.18.1 §B). Renders the
/// server-computed summary ("sick N times · typical recovery gap X days"), a
/// per-type breakdown, and a recurrence-by-month tally. The typical gap is
/// withheld below the server's min-sample floor (`typicalRecoveryGapDays ==
/// nil`). **Retrospective only — never a forecast.** Tolerates an empty /
/// not-deployed response with a calm "not enough data yet" state.
struct IllnessInsightsScreen: View {
    let store: IllnessStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                if let insights = store.insights, insights.episodeCount > 0 {
                    summaryCard(insights)
                    if !insights.byType.isEmpty {
                        byTypeCard(insights)
                    }
                    if !insights.byMonth.isEmpty {
                        byMonthCard(insights)
                    }
                    // UI-Standard R15 (U1) — die pauschale Fußzeile
                    // `illness.insights.retrospectiveDisclaimer` ist ersatzlos
                    // entfallen. Der Bildschirm heißt „Rückblick", jede Karte
                    // zählt Vergangenes; der Satz sagte nichts, was die Zahlen
                    // darüber nicht schon sagen.
                } else {
                    emptyState
                }
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationTitle(Text("illness.insights.title"))
        .navigationBarTitleDisplayMode(.large)
        .task { await store.loadInsights(includeRecoveryGap: true) }
        .refreshable { await store.loadInsights(includeRecoveryGap: true) }
    }

    private func summaryCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                let sickTemplate = String(localized: "illness.insights.sickCount")
                Text(String(format: sickTemplate, insights.episodeCount))
                    .font(.hlTitle3)
                    .foregroundStyle(HLText.primary)
                if let gap = insights.typicalRecoveryGapDays {
                    let gapValue = gap.formatted(.number.precision(.fractionLength(0 ... 1)))
                    let gapTemplate = String(localized: "illness.insights.typicalGap")
                    Text(String(format: gapTemplate, gapValue))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    // v1.21.0: name the metric that is typically last to settle
                    // across episodes (server's `gapDriverType`). Render-only.
                    if let driver = typicalGapDriverText(insights.gapDriverType) {
                        Text(driver)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("illness.insights.gapWithheld")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                let resolvedTemplate = String(localized: "illness.insights.resolvedCount")
                Text(String(format: resolvedTemplate, insights.resolvedCount, insights.episodeCount))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }

    private func byTypeCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("illness.insights.byType.title")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                ForEach(sortedPairs(insights.byType), id: \.0) { key, count in
                    HStack {
                        Text(typeLabel(key))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                        Spacer()
                        Text(verbatim: "\(count)")
                            .font(.hlSubhead.monospacedDigit())
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
    }

    private func byMonthCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("illness.insights.byMonth.title")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                ForEach(sortedPairs(insights.byMonth, descending: true), id: \.0) { key, count in
                    HStack {
                        Text(verbatim: key)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                        Spacer()
                        Text(verbatim: "\(count)")
                            .font(.hlSubhead.monospacedDigit())
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HLCard(style: .ghost) {
            // Audit-01 M6 — title/subtitle colour drift (secondary/tertiary vs the
            // sibling primary/secondary) fixed by routing through `HLEmptyState`.
            HLEmptyState(
                icon: "chart.bar.xaxis",
                title: "illness.insights.empty.title",
                message: "illness.insights.empty.subtitle"
            )
        }
    }

    /// Sort `{key: count}` by count desc, then key asc; `descending` sorts by
    /// key (month) descending instead (newest months first).
    private func sortedPairs(_ map: [String: Int], descending: Bool = false) -> [(String, Int)] {
        if descending {
            return map.sorted { $0.key > $1.key }
        }
        return map.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
    }

    private func typeLabel(_ key: String) -> String {
        IllnessType(rawValue: key)?.localizedLabel ?? key.capitalized
    }

    /// "Usually your resting heart rate is last to settle." — names the server's
    /// cross-episode `gapDriverType`. Returns `nil` when no driver was surfaced.
    private func typicalGapDriverText(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        if type.uppercased() == "FUNCTIONAL_IMPACT" {
            return String(localized: "illness.insights.typicalGap.driver.symptom")
        }
        let template = String(localized: "illness.insights.typicalGap.driver")
        return String(format: template, IllnessVitalLabel.label(for: type))
    }
}
