import SwiftUI

struct CycleInsightsSection: View {
    let store: CycleStore

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            if store.isLoadingInsights, store.insights == nil {
                ProgressView("cycle.insights.loading")
                    .frame(maxWidth: .infinity)
            } else if store.insightsError != nil {
                HLSettingsCard(icon: "chart.dots.scatter", title: "cycle.insights.title") {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        Text("cycle.insights.error")
                            .font(.hlBody)
                            .foregroundStyle(HLText.secondary)
                        Button("Retry") { Task { await store.loadInsights(force: true) } }
                            .buttonStyle(.bordered)
                    }
                }
            } else if let insights = store.insights {
                if insights.isLearning {
                    HLSettingsCard(icon: "chart.dots.scatter", title: "cycle.insights.title") {
                        Text("cycle.insights.learning")
                            .font(.hlBody)
                            .foregroundStyle(HLText.secondary)
                    }
                } else {
                    if let headline = insights.headline {
                        CycleInsightHeadlineCard(row: headline)
                    }
                    if !insights.rows.isEmpty {
                        CyclePhaseVitalRows(rows: insights.rows)
                    }
                    if !insights.symptomPatterns.isEmpty {
                        CycleSymptomPatternCard(
                            patterns: insights.symptomPatterns,
                            customSymptoms: store.customSymptoms
                        )
                    }
                }
            }
        }
        .task {
            await store.loadCustomSymptoms()
            await store.loadInsights()
        }
    }
}

private struct CycleInsightHeadlineCard: View {
    let row: CyclePhaseMetricRow

    var body: some View {
        HLSettingsCard(icon: "sparkles", title: "cycle.insights.headline.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(CycleInsightFormatting.metricLabel(row.metricKey))
                    .font(.hlHeadline)
                Text(CycleInsightFormatting.comparison(row))
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                Text(CycleInsightFormatting.evidence(row))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct CyclePhaseVitalRows: View {
    let rows: [CyclePhaseMetricRow]

    var body: some View {
        HLSettingsCard(icon: "waveform.path.ecg", title: "cycle.insights.vitals.title") {
            VStack(spacing: HLSpace.md) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(CycleInsightFormatting.metricLabel(row.metricKey))
                                .font(.hlSubhead)
                            Spacer()
                            Text(CycleInsightFormatting.delta(row))
                                .font(.hlSubhead.monospacedDigit())
                        }
                        Text(CycleInsightFormatting.comparison(row))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                        Text(CycleInsightFormatting.evidence(row))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
    }
}

private struct CycleSymptomPatternCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let patterns: [CycleSymptomPhasePattern]
    let customSymptoms: [CycleCustomSymptomDTO]

    var body: some View {
        HLSettingsCard(icon: "square.stack.3d.up", title: "cycle.insights.symptoms.title") {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                ForEach(patterns) { pattern in
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(symptomLabel(pattern.symptomKey)).font(.hlSubhead)
                            Spacer()
                            Text(topPhaseLabel(pattern))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                        }
                        GeometryReader { proxy in
                            HStack(spacing: 1) {
                                ForEach(CyclePhaseValue.allCases, id: \.self) { phase in
                                    let count = pattern.counts[phase]
                                    if count > 0 {
                                        Rectangle()
                                            .fill(CyclePhasePalette.tint(for: palette(phase), scheme: colorScheme))
                                            .frame(width: max(1, proxy.size.width * CGFloat(count) / CGFloat(max(1, pattern.total))))
                                    }
                                }
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 10)
                        .accessibilityLabel(Text("cycle.insights.symptoms.distribution"))
                        .accessibilityValue(Text(distributionValue(pattern)))
                    }
                }
            }
        }
    }

    private func symptomLabel(_ key: String) -> String {
        if let labelKey = CycleSymptomCatalog.labelsByKey[key] {
            return String(localized: String.LocalizationValue(labelKey))
        }
        if key.hasPrefix("custom:") {
            return customSymptoms.first(where: { $0.key == key })?.displayLabel
                ?? String(localized: "cycle.insights.symptoms.customFallback")
        }
        return String(localized: "cycle.insights.symptoms.unknownFallback")
    }

    private func topPhaseLabel(_ pattern: CycleSymptomPhasePattern) -> String {
        guard let phase = pattern.topPhaseValue else { return String(localized: "cycle.insights.phase.unknown") }
        return String(
            format: String(localized: "cycle.insights.symptoms.topPhase"),
            phaseLabel(phase),
            pattern.topShare * 100
        )
    }

    private func distributionValue(_ pattern: CycleSymptomPhasePattern) -> String {
        CyclePhaseValue.allCases.map { phase in
            "\(phaseLabel(phase)): \(pattern.counts[phase])"
        }.joined(separator: ", ")
    }

    private func phaseLabel(_ phase: CyclePhaseValue) -> String {
        String(localized: String.LocalizationValue("cycle.phase.\(phase.rawValue.lowercased()).name"))
    }

    private func palette(_ phase: CyclePhaseValue) -> CyclePhasePalette.Phase {
        switch phase {
        case .menstrual: .menstrual
        case .follicular: .follicular
        case .ovulatory: .ovulatory
        case .luteal: .luteal
        }
    }
}

private enum CycleInsightFormatting {
    static func metricLabel(_ key: String) -> String {
        let localizationKey = "cycle.insights.metric.\(key)"
        let value = String(localized: String.LocalizationValue(localizationKey))
        guard value == localizationKey else { return value }
        return key
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    static func comparison(_ row: CyclePhaseMetricRow) -> String {
        String(
            format: String(localized: "cycle.insights.comparison"),
            formatted(row.lutealAvg, display: row.displayValue),
            formatted(row.follicularAvg, display: row.displayValue)
        )
    }

    static func delta(_ row: CyclePhaseMetricRow) -> String {
        let sign = row.delta > 0 ? "+" : ""
        return sign + formatted(row.delta, display: row.displayValue)
    }

    static func evidence(_ row: CyclePhaseMetricRow) -> String {
        String(
            format: String(localized: "cycle.insights.evidence"),
            row.lutealDays,
            row.follicularDays,
            row.qValue
        )
    }

    private static func formatted(_ value: Double, display: CycleInsightDisplay) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)))
        switch display {
        case .hours: return String(format: String(localized: "cycle.insights.unit.hours"), number)
        case .steps: return String(format: String(localized: "cycle.insights.unit.steps"), number)
        case .bpm: return String(format: String(localized: "cycle.insights.unit.bpm"), number)
        case .milliseconds: return String(format: String(localized: "cycle.insights.unit.ms"), number)
        case .kilograms: return String(format: String(localized: "cycle.insights.unit.kg"), number)
        case .celsius: return String(format: String(localized: "cycle.insights.unit.celsius"), number)
        case .glucose: return String(format: String(localized: "cycle.insights.unit.glucose"), number)
        case .mood, .unknown: return number
        }
    }
}
