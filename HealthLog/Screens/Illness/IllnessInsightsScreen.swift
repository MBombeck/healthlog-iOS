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
                }
                // 1.4 B2 — below the server's floor the gap is simply absent;
                // no line says it is withheld.
                let resolvedTemplate = String(localized: "illness.insights.resolvedCount")
                Text(String(format: resolvedTemplate, insights.resolvedCount, insights.episodeCount))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                // 1.0.3 (App Review 1.4.1, audit row 17) — the typical recovery
                // gap is the screen's one medical-shaped figure, so the method
                // behind it is cited in the card that states it (1.4 B2: at
                // its foot, not between the cards).
                HLSourcesLink(topic: .illnessRecovery)
            }
        }
    }

    private func byTypeCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // 1.4 B4 — the canonical label instead of a hand-set footnote.
                HLSectionLabel("illness.insights.byType.title")
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
                HLSectionLabel("illness.insights.byMonth.title")
                ForEach(sortedPairs(insights.byMonth, descending: true), id: \.0) { key, count in
                    HStack {
                        Text(verbatim: Self.monthLabel(key))
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

    /// 1.4 B2 — the lockup on the page itself, not in a ghost card, and
    /// without the sentence promising a summary later.
    private var emptyState: some View {
        HLEmptyState(icon: "chart.bar.xaxis", title: "illness.insights.empty.title")
            .padding(.top, HLSpace.xxl)
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

    /// 1.4 B4 — the server keys the tally by month (`"2026-10"`); the row reads
    /// it as a month in words ("Oktober 2026"). A key that is not a month keeps
    /// itself rather than vanish.
    static func monthLabel(_ key: String, locale: Locale = .autoupdatingCurrent) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM"
        guard let month = parser.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: month)
    }

    private func typeLabel(_ key: String) -> String {
        IllnessType(rawValue: key)?.localizedLabel ?? key.capitalized
    }

    /// The first letter in lower case, the rest as written: the English vital
    /// labels are sentence case ("Resting heart rate", "Blood oxygen").
    nonisolated static func midSentence(_ label: String) -> String {
        label.prefix(1).lowercased() + label.dropFirst()
    }

    /// "Usually your resting heart rate is last to settle." — names the server's
    /// cross-episode `gapDriverType`. Returns `nil` when no driver was surfaced.
    private func typicalGapDriverText(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        if type.uppercased() == "FUNCTIONAL_IMPACT" {
            return String(localized: "illness.insights.typicalGap.driver.symptom")
        }
        let template = String(localized: "illness.insights.typicalGap.driver")
        // 1.4 B4 — the name sits mid-sentence: English writes it in lower case
        // ("Across episodes, resting heart rate tends..."), German keeps the noun.
        let label = IllnessVitalLabel.label(for: type)
        let keepsCapital = AppLanguage.current == .de
        return String(format: template, keepsCapital ? label : Self.midSentence(label))
    }
}
