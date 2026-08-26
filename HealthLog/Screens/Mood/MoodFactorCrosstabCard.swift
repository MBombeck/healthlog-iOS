import SwiftUI

/// v0.14.8 — the **"What your ratings show"** card on the Insights → Mood page.
/// Renders the server's `factorCrosstab` rows (`GET /api/mood/insights`, server
/// v1.14.0): for each RATED factor, the mean of a tracked metric on the days
/// the factor was scored LOW vs HIGH (median split, inverse-aware, Welch + FDR).
///
/// This is the first iOS surface for the actual analytical USE of the slider
/// rating VALUES — until now the ratings were captured + read back but never
/// shown in an analysis. The sentence is the honest read: "On days you rated
/// <factor> low, your <metric> tended to be <higher/lower>."
///
/// **ASSOCIATION, NEVER CAUSE.** Every row is a short-window statistical
/// association, FDR-corrected server-side. The card carries a standing
/// "association, not cause" caption and adds no causal/clinical language (MDR
/// doctrine). Direction is encoded by **glyph + ink-weight + words**, NEVER hue
/// — fully monochrome, matching `MoodInfluenceCard` / `MoodBetterDaysCard`.
///
/// **Self-suppressing.** Renders nothing when there are no rows — the host keeps
/// the calm empty state for the whole relations region instead.
struct MoodFactorCrosstabCard: View {
    /// The crosstab rows, most-significant first. Empty → the card hides.
    let rows: [FactorMetricCrosstabRow]
    /// Resolves a factor's label from the live catalog (`labelKey` fallback).
    @Environment(MoodTagCatalogStore.self) private var catalog
    /// QoL-2 (A360-4) — gate the expand/collapse spring like the rest of the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false

    private static let collapsedCap = 4

    private var visibleRows: [FactorMetricCrosstabRow] {
        expanded ? rows : Array(rows.prefix(Self.collapsedCap))
    }

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text("mood.factorCrosstab.title")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)

                    // The standing association-not-cause caption — once, up top,
                    // so every row reads under it.
                    Text("mood.factorCrosstab.caption")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: HLSpace.sm) {
                        ForEach(visibleRows) { row in
                            MoodFactorCrosstabRowView(
                                row: row,
                                resolvedLabel: label(for: row),
                                resolvedSymbol: symbol(for: row)
                            )
                        }
                    }

                    if rows.count > Self.collapsedCap {
                        Button {
                            withAnimation(reduceMotion ? nil : HLMotion.spring) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show fewer" : "Show more")
                                .font(.hlSubhead.weight(.medium))
                                .foregroundStyle(HLText.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("insights.mood.factorCrosstab.toggle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("insights.mood.factorCrosstab")
        }
    }

    /// Localized factor label: the catalog (live taxonomy) first, falling back
    /// to the server `labelKey` so a retired factor still reads humanly.
    private func label(for row: FactorMetricCrosstabRow) -> String {
        catalog.label(forTagKey: row.factor) ?? MoodTagCatalogL10n.resolve(row.labelKey)
    }

    /// SF Symbol for the factor (Lucide-mapped); neutral slider glyph otherwise.
    private func symbol(for row: FactorMetricCrosstabRow) -> String {
        MoodTagSFSymbol.symbol(forLucide: row.icon) ?? "slider.horizontal.3"
    }
}

/// One crosstab row: factor (icon + label) · the honest association sentence
/// ("On days you rated X low, your <metric> tended to be lower") · a restrained
/// confidence pill. Pure presentation — the host resolves the label/symbol.
struct MoodFactorCrosstabRowView: View {
    let row: FactorMetricCrosstabRow
    let resolvedLabel: String
    let resolvedSymbol: String

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: resolvedSymbol)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(resolvedLabel)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
                Text(Self.associationSentence(for: row))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HLSpace.sm)

            MoodConfidencePill(confidence: row.confidence)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resolvedLabel))
        .accessibilityValue(Text(Self.accessibilityValue(row, label: resolvedLabel)))
    }

    /// `delta = lowAvg − highAvg`. Positive → the metric ran HIGHER on the days
    /// the factor was rated low (a worse day, because the split is inverse-aware).
    private var higherOnLowDays: Bool {
        row.delta >= 0
    }

    /// The honest, non-causal association sentence. The human factor label + the
    /// metric + the direction the metric leaned on the factor's LOW (worse) days.
    nonisolated static func associationSentence(for row: FactorMetricCrosstabRow) -> String {
        let metric = metricLabel(for: row.metricKey)
        return row.delta >= 0
            ? String(
                localized: "On your worse \(row.labelKeyHumanFallback) days, your \(metric) tended to run higher.",
                comment: "Factor-crosstab association sentence: metric higher on low/worse factor days"
            )
            : String(
                localized: "On your worse \(row.labelKeyHumanFallback) days, your \(metric) tended to run lower.",
                comment: "Factor-crosstab association sentence: metric lower on low/worse factor days"
            )
    }

    /// VoiceOver value: the averages + direction + sample size + confidence.
    nonisolated static func accessibilityValue(_ row: FactorMetricCrosstabRow, label: String) -> String {
        let metric = metricLabel(for: row.metricKey)
        let lowAvg = formatted(row.lowAvg, display: row.display)
        let highAvg = formatted(row.highAvg, display: row.display)
        let confidence = MoodConfidencePill.label(for: row.confidence)
        return String(
            localized: "On worse \(label) days your \(metric) averaged \(lowAvg); on better days \(highAvg). Based on \(row.minGroupDays) days each side. \(confidence) confidence.",
            comment: "VoiceOver value for one factor-crosstab row"
        )
    }

    /// Formatted metric value with its display-unit precision. Counts (steps)
    /// read as integers; everything else to one fraction digit.
    nonisolated static func formatted(_ value: Double, display: String) -> String {
        switch display {
        case "steps": value.formatted(.number.precision(.fractionLength(0)))
        default: value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    // MARK: - Metric channel resolution (server FACTOR_CROSSTAB_METRICS keys)

    /// Localized label per `FACTOR_CROSSTAB_METRICS` channel key (server
    /// `mood-aggregates.ts`). Note these keys differ from the `betterDays`
    /// metric keys (`sleepDuration` vs `sleep`, `restingHeartRate` vs `pulse`).
    nonisolated static func metricLabel(for key: String) -> String {
        switch key {
        case "sleepDuration": String(localized: "sleep duration", comment: "Factor-crosstab metric: sleep duration")
        case "steps": String(localized: "step count", comment: "Factor-crosstab metric: steps")
        case "restingHeartRate": String(localized: "resting heart rate", comment: "Factor-crosstab metric: resting heart rate")
        case "heartRateVariability": String(localized: "heart-rate variability", comment: "Factor-crosstab metric: HRV")
        case "weight": String(localized: "weight", comment: "Factor-crosstab metric: weight")
        case "bloodPressureSystolic": String(localized: "blood pressure", comment: "Factor-crosstab metric: systolic blood pressure")
        default:
            key.lowercased()
                .split(separator: "_")
                .joined(separator: " ")
        }
    }
}

private extension FactorMetricCrosstabRow {
    /// Human factor label for the sentence — resolves the server `labelKey`
    /// (lowercased so it reads naturally mid-sentence: "your worse sleep days").
    var labelKeyHumanFallback: String {
        MoodTagCatalogL10n.resolve(labelKey).lowercased()
    }
}
