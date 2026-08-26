import SwiftUI

/// v0.14.1 — the **"Better days" board** on the Insights → Mood page. Renders
/// the server's `betterDays` factors (`GET /api/mood/insights`, server v1.11.5):
/// one ranked, confidence-gated list folding the tag deltas AND the
/// mood × health-metric correlations into "what is associated with your
/// better-mood days".
///
/// **ASSOCIATION, NEVER CAUSE.** Every factor is a statistical association. The
/// card carries a standing "association, not cause" caption and adds no
/// causal/clinical language (MDR doctrine). `direction` (up/down) is encoded by
/// **glyph + ink-weight**, NEVER hue — fully monochrome.
///
/// **Server ranking respected.** Rows render in the exact order the server
/// delivered (effect-size desc, then confidence), so neither a tag nor a metric
/// dominates for scale reasons alone.
///
/// **Self-suppressing.** Renders nothing when there are no factors.
struct MoodBetterDaysCard: View {
    /// The ranked board, server order preserved. Empty → the card hides.
    let factors: [BetterDayFactor]
    /// Resolves a structured tag's label from the live catalog.
    @Environment(MoodTagCatalogStore.self) private var catalog
    /// QoL-2 (A360-4) — gate the expand/collapse spring like the rest of the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false

    private static let collapsedCap = 5

    private var visibleFactors: [BetterDayFactor] {
        expanded ? factors : Array(factors.prefix(Self.collapsedCap))
    }

    var body: some View {
        if factors.isEmpty {
            EmptyView()
        } else {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    // v0.14.7 B6 — the in-card title is removed: the section
                    // heading above this region ("Was deine Stimmung prägt" /
                    // "What shapes your mood", `InsightsMoodPage.relationsBlock`)
                    // already names it, so an in-card title duplicated the label.
                    VStack(spacing: HLSpace.sm) {
                        ForEach(visibleFactors) { factor in
                            MoodBetterDayRowView(
                                factor: factor,
                                resolvedLabel: label(for: factor),
                                resolvedSymbol: symbol(for: factor)
                            )
                        }
                    }

                    if factors.count > Self.collapsedCap {
                        Button {
                            withAnimation(reduceMotion ? nil : HLMotion.spring) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show fewer" : "Show more")
                                .font(.hlSubhead.weight(.medium))
                                .foregroundStyle(HLText.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("insights.mood.betterDays.toggle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("insights.mood.betterDays")
        }
    }

    /// Localized label: a structured tag via the catalog (`labelKey`); a flat
    /// tag verbatim; a metric via the channel-key table.
    private func label(for factor: BetterDayFactor) -> String {
        switch factor.source {
        case .tag:
            if let key = factor.labelKey {
                return MoodTagCatalogL10n.resolve(key)
            }
            return catalog.label(forTagKey: factor.key) ?? factor.key
        case .metric:
            return MoodBetterDayRowView.metricLabel(for: factor.key)
        }
    }

    /// SF Symbol: a structured tag's catalog glyph; a metric's channel glyph; a
    /// neutral fallback otherwise.
    private func symbol(for factor: BetterDayFactor) -> String {
        switch factor.source {
        case .tag:
            MoodTagSFSymbol.symbol(forLucide: factor.icon) ?? "tag"
        case .metric:
            MoodBetterDayRowView.metricSymbol(for: factor.key)
        }
    }
}

/// One better-days row: factor (icon + label) · a direction glyph + descriptive
/// "with higher/lower mood" caption · a restrained confidence pill. Pure
/// presentation; the host resolves the label/symbol.
struct MoodBetterDayRowView: View {
    let factor: BetterDayFactor
    let resolvedLabel: String
    let resolvedSymbol: String

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: resolvedSymbol)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(resolvedLabel)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
                Text(Self.directionCaption(for: factor))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: HLSpace.sm)

            Image(systemName: factor.isPositive ? "arrow.up" : "arrow.down")
                .font(.hlSubhead.weight(factor.isPositive ? .semibold : .regular))
                .foregroundStyle(factor.isPositive ? HLText.primary : HLText.secondary)

            MoodConfidencePill(confidence: factor.confidence)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resolvedLabel))
        .accessibilityValue(Text(Self.accessibilityValue(factor, label: resolvedLabel)))
    }

    /// Descriptive direction caption — "with higher mood" / "with lower mood".
    /// Never causal.
    nonisolated static func directionCaption(for factor: BetterDayFactor) -> String {
        factor.isPositive
            ? String(localized: "Tends to go with higher mood", comment: "Better-days factor: positive association caption")
            : String(localized: "Tends to go with lower mood", comment: "Better-days factor: negative association caption")
    }

    /// VoiceOver value: direction + sample size + confidence, in words.
    nonisolated static func accessibilityValue(_ factor: BetterDayFactor, label: String) -> String {
        let caption = directionCaption(for: factor)
        let confidence = MoodConfidencePill.label(for: factor.confidence)
        return String(
            localized: "\(caption), based on \(factor.n) days. \(confidence) confidence.",
            comment: "VoiceOver value for one better-days factor row"
        )
    }

    // MARK: - Metric channel resolution

    /// Localized label per `CORRELATION_METRICS` channel key (server
    /// `mood-aggregates.ts`). Unknown future keys fall back to a de-snaked form.
    nonisolated static func metricLabel(for key: String) -> String {
        switch key {
        case "sleep": String(localized: "Sleep", comment: "Better-days metric: sleep duration")
        case "steps": String(localized: "Steps", comment: "Better-days metric: step count")
        case "pulse": String(localized: "Resting pulse", comment: "Better-days metric: pulse")
        case "weight": String(localized: "Weight", comment: "Better-days metric: body weight")
        case "bloodPressureSystolic": String(localized: "Blood pressure", comment: "Better-days metric: systolic blood pressure")
        default:
            // Forward-compatible de-snake: `FUTURE_CHANNEL` → `future channel`.
            key.lowercased()
                .split(separator: "_")
                .joined(separator: " ")
        }
    }

    /// SF Symbol per metric channel key. Neutral fallback for unknown keys.
    nonisolated static func metricSymbol(for key: String) -> String {
        switch key {
        case "sleep": "bed.double"
        case "steps": "figure.walk"
        case "pulse": "heart"
        case "weight": "scalemass"
        case "bloodPressureSystolic": "waveform.path.ecg"
        default: "chart.xyaxis.line"
        }
    }
}
