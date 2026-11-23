import SwiftUI

/// Cross-episode retrospective insights (v1.18.1 §B). Renders the
/// server-computed summary ("sick N times · typical recovery gap X days"), a
/// per-type breakdown, and a recurrence-by-month tally. The typical gap is
/// withheld below the server's min-sample floor (`typicalRecoveryGapDays ==
/// nil`). **Retrospective only — never a forecast.** Tolerates an empty /
/// not-deployed response with a calm "not enough data yet" state.
struct IllnessInsightsScreen: View {
    let store: IllnessStore

    /// What the screen shows. A failed request with nothing to show is an
    /// error with a retry, never "no analysis yet", and the first request
    /// shows its loading state instead of the empty one.
    enum Phase: Equatable {
        case loading
        case failed
        case empty
        case loaded
    }

    nonisolated static func phase(
        hasEpisodes: Bool,
        hasLoaded: Bool,
        isLoading: Bool,
        loadFailed: Bool
    ) -> Phase {
        if hasEpisodes { return .loaded }
        if !hasLoaded || isLoading { return .loading }
        return loadFailed ? .failed : .empty
    }

    private var loadPhase: HLLoadPhase {
        switch phase {
        case .loading: .loading
        case .failed: .error(retry: { await load() })
        case .empty: .empty
        case .loaded: .loaded
        }
    }

    private var phase: Phase {
        Self.phase(
            hasEpisodes: (store.insights?.episodeCount ?? 0) > 0,
            hasLoaded: store.hasLoadedInsights,
            isLoading: store.isLoadingInsights,
            loadFailed: store.insightsError != nil
        )
    }

    var body: some View {
        HLPage {
            HLStateContainer(loadPhase) {
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSkeleton(.capsule, width: 200, height: 20)
                        HLSkeleton(.capsule, width: 140, height: 14)
                    }
                }
            } empty: {
                HLEmptyState(icon: "chart.bar.xaxis", title: "illness.insights.empty.title")
            } content: {
                if let insights = store.insights {
                    summaryCard(insights)
                    if !insights.byType.isEmpty {
                        byTypeCard(insights)
                    }
                    if !insights.byMonth.isEmpty {
                        byMonthCard(insights)
                    }
                }
            }
        }
        // A refresh that fails over a summary keeps the summary and says so.
        .hlErrorBannerOverlay(error: phase == .loaded ? store.insightsError : nil) {
            Task { await load() }
        }
        .navigationTitle(Text("illness.insights.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await store.loadInsights(includeRecoveryGap: true)
    }

    private func summaryCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard("Overview") {
            HLStatGrid(cells: Self.summaryCells(insights))
            // v1.21.0: name the metric that is typically last to settle
            // across episodes (server's `gapDriverType`). Render-only.
            if insights.typicalRecoveryGapDays != nil, let driver = typicalGapDriverText(insights.gapDriverType) {
                Text(driver)
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 1.0.3 (App Review 1.4.1, audit row 17): the typical recovery
            // gap is the screen's one medical-shaped figure, so the method
            // behind it is cited in the card that states it.
            HLSourcesLink(topic: .illnessRecovery)
        }
    }

    /// The summary's key figures in the statistic raster: episodes, resolved,
    /// and the typical recovery gap where the server shares one. Below the
    /// server's floor the gap is simply absent; no cell says it is withheld.
    static func summaryCells(_ insights: IllnessInsightsDTO) -> [HLStatCell] {
        var cells = [
            HLStatCell(
                label: String(localized: "illness.insights.stat.episodes"),
                value: HLValueFormat.number(Double(insights.episodeCount), fractionDigits: 0 ... 0)
            ),
            HLStatCell(
                label: String(localized: "illness.status.resolved"),
                value: HLValueFormat.number(Double(insights.resolvedCount), fractionDigits: 0 ... 0)
            )
        ]
        if let gap = insights.typicalRecoveryGapDays {
            cells.append(HLStatCell(
                label: String(localized: "illness.correlation.recoveryGap.title"),
                value: HLValueFormat.number(gap, fractionDigits: 0 ... 1),
                unit: String(localized: "illness.insights.stat.days")
            ))
        }
        return cells
    }

    private func byTypeCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard("illness.insights.byType.title", layout: .rows) {
            ForEach(sortedPairs(insights.byType), id: \.0) { key, count in
                HLRow(title: Text(verbatim: typeLabel(key)), value: Text(count, format: .number))
            }
        }
    }

    private func byMonthCard(_ insights: IllnessInsightsDTO) -> some View {
        HLCard("illness.insights.byMonth.title", layout: .rows) {
            ForEach(sortedPairs(insights.byMonth, descending: true), id: \.0) { key, count in
                HLRow(title: Text(verbatim: Self.monthLabel(key)), value: Text(count, format: .number))
            }
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

    /// The server keys the tally by month (`"2026-10"`); the row reads
    /// it as a month in words ("Oktober 2026"). A key that is not a month keeps
    /// itself rather than vanish.
    static func monthLabel(_ key: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard key.split(separator: "-").count == 2,
              let month = ProfileDay.anchor(forKey: key + "-01") else { return key }
        return HLDateFormat.monthYear(month, locale: locale, calendar: ProfileDay.utcCalendar)
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
        // The name sits mid-sentence: English writes it in lower case
        // ("Across episodes, resting heart rate tends..."), German keeps the noun.
        let label = IllnessVitalLabel.label(for: type)
        let keepsCapital = AppLanguage.current == .de
        return String(format: template, keepsCapital ? label : Self.midSentence(label))
    }
}
