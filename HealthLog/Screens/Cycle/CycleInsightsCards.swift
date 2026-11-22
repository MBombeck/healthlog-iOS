import SwiftUI

struct CycleInsightsSection: View {
    let store: CycleStore

    var body: some View {
        // The page's own gap, so the section headers inside keep their room.
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            if store.isLoadingInsights, store.insights == nil {
                ProgressView("cycle.insights.loading")
                    .frame(maxWidth: .infinity)
            } else if store.insightsError != nil {
                HLSectionHeader("cycle.insights.title", rank: .area)
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        Text("cycle.insights.error")
                            .hlText(.emptyMessage)
                        HLButton(HLControlWord.retry.key, variant: .secondary) {
                            Task { await store.loadInsights(force: true) }
                        }
                    }
                }
            } else if let insights = store.insights {
                // While the server holds no supported pattern there
                // is no card saying so.
                if !insights.isLearning {
                    if let headline = Self.standaloneHeadline(insights) {
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
        .hlContainerGap(HLLayout.cardGap)
        .task {
            await store.loadCustomSymptoms()
            await store.loadInsights()
        }
    }

    /// The "most notable pattern" card only for a pattern the
    /// "Phase × Vitalwerte" card does not list. The server's headline is its
    /// strongest row, so with the rows on screen the card repeated their first
    /// line word for word.
    static func standaloneHeadline(_ insights: CycleInsightsDTO) -> CyclePhaseMetricRow? {
        guard let headline = insights.headline,
              !insights.rows.contains(where: { $0.id == headline.id }) else { return nil }
        return headline
    }
}

private struct CycleInsightHeadlineCard: View {
    let row: CyclePhaseMetricRow
    /// Weight, temperature and glucose averages in the account's unit.
    @Environment(\.unitPreferences) private var units

    var body: some View {
        HLSectionHeader("cycle.insights.headline.title", rank: .area)
        // One level under the header: the metric names the pattern in row
        // type, the comparison follows as body text.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLRowTitle(Text(verbatim: CycleInsightFormatting.metricLabel(row.metricKey)))
                Text(CycleInsightFormatting.comparison(row, units: units))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Text(CycleInsightFormatting.evidence(row))
                    .hlText(.footnote)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct CyclePhaseVitalRows: View {
    let rows: [CyclePhaseMetricRow]
    /// Weight, temperature and glucose averages in the account's unit.
    @Environment(\.unitPreferences) private var units

    var body: some View {
        HLSectionHeader("cycle.insights.vitals.title", rank: .area)
        HLCard(layout: .rows) {
            ForEach(rows) { row in
                HLRow(
                    title: Text(verbatim: CycleInsightFormatting.metricLabel(row.metricKey)),
                    detail: CycleInsightFormatting.rowDetail(row, units: units),
                    value: Text(verbatim: CycleInsightFormatting.delta(row, units: units))
                )
            }
        }
    }
}

private struct CycleSymptomPatternCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let patterns: [CycleSymptomPhasePattern]
    let customSymptoms: [CycleCustomSymptomDTO]

    var body: some View {
        HLSectionHeader("cycle.insights.symptoms.title", rank: .area)
        HLCard {
            VStack(alignment: .leading, spacing: HLLayout.rowSpacing) {
                ForEach(patterns) { pattern in
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(symptomLabel(pattern.symptomKey)).font(.hlSubhead)
                            Spacer()
                            Text(topPhaseLabel(pattern))
                                .hlText(.rowStatus)
                        }
                        GeometryReader { proxy in
                            HStack(spacing: HLSpace.hair) {
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

    /// An interpolated `LocalizationValue` looks up the key
    /// `cycle.phase.%@.name`, which does not exist, so the raw key showed on
    /// screen. The explainer's own resource names the phase.
    private func phaseLabel(_ phase: CyclePhaseValue) -> String {
        String(localized: CyclePhaseExplainer.nameKey(for: palette(phase)))
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

enum CycleInsightFormatting {
    static func metricLabel(_ key: String) -> String {
        let localizationKey = "cycle.insights.metric.\(key)"
        let value = String(localized: String.LocalizationValue(localizationKey))
        guard value == localizationKey else { return value }
        return key
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    static func comparison(_ row: CyclePhaseMetricRow, units: UnitPreferences) -> String {
        String(
            format: String(localized: "cycle.insights.comparison"),
            formatted(row.lutealAvg, display: row.displayValue, units: units, isDelta: false),
            formatted(row.follicularAvg, display: row.displayValue, units: units, isDelta: false)
        )
    }

    /// The one detail line of a phase row: the comparison, then the days
    /// it rests on.
    static func rowDetail(_ row: CyclePhaseMetricRow, units: UnitPreferences) -> Text? {
        HLRowDetail.text([comparison(row, units: units), evidence(row)])
    }

    static func delta(_ row: CyclePhaseMetricRow, units: UnitPreferences) -> String {
        formatted(row.delta, display: row.displayValue, units: units, isDelta: true, signed: true)
    }

    /// The displays whose canonical values follow the account's
    /// unit, mapped to the kind carrying the transform (web parity:
    /// `cycle-phase-crosstab.tsx` `DISPLAY_TO_TYPE`, plus glucose, which
    /// follows the account's glucose unit here as everywhere else in the app).
    static func kind(for display: CycleInsightDisplay) -> MetricKind? {
        switch display {
        case .kilograms: .weight
        case .celsius: .bodyTemperature
        case .glucose: .glucose
        default: nil
        }
    }

    /// The days a phase comparison rests on. The q-value left the line;
    /// what it guarantees is said in the screen's (i) (`cycle.info.patterns`).
    static func evidence(_ row: CyclePhaseMetricRow) -> String {
        String(
            format: String(localized: "cycle.insights.evidence"),
            row.lutealDays,
            row.follicularDays
        )
    }

    static func formatted(
        _ value: Double,
        display: CycleInsightDisplay,
        units: UnitPreferences,
        isDelta: Bool,
        signed: Bool = false
    ) -> String {
        /// A change carries its sign; a level does not.
        func text(_ number: Double) -> String {
            signed
                ? HLValueFormat.signedNumber(number, fractionDigits: 1 ... 1)
                : HLValueFormat.number(number, fractionDigits: 1 ... 1)
        }
        // A phase average converts as a level; a phase DELTA by the factor
        // alone (a 0.3 °C shift is 0.54 °F, never 32.54 °F).
        if let kind = kind(for: display), units.transform(for: kind).rescales,
           let suffix = units.transform(for: kind).suffix
        {
            let converted = isDelta ? units.displayDelta(value, kind: kind) : units.displayValue(value, kind: kind)
            return "\(text(converted)) \(suffix)"
        }
        let number = text(value)
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
