import SwiftUI

/// v0.14.1 — the **"Influence on mood"** card (the Daylio payoff) on the
/// Insights → Mood page. Renders the server's `tagInfluence` rows
/// (`GET /api/mood/insights`, server v1.11.5): per tag, the average daily mood
/// on days the tag is PRESENT vs ABSENT, the `delta`, and a `confidence` band.
///
/// **ASSOCIATION, NEVER CAUSE.** Each row is a statistical association over a
/// short window. The card carries a standing "association, not cause" caption
/// and adds no causal/clinical language (MDR doctrine). Direction is encoded by
/// **glyph + ink-weight + sign**, NEVER hue — fully monochrome, matching
/// `MoodTagInsightSection`.
///
/// **Honest precision.** The `confidence` band (Low/Med/High) is a restrained
/// micro-pill, never a fake-precise number. The server already enforces a
/// ≥5-day floor per side and a Welch t-test; a row that did not clear the floor
/// simply isn't in the payload, so the card never invents one.
///
/// **Self-suppressing.** Renders nothing when there are no rows — the host keeps
/// the calm empty state for the whole relations region instead.
struct MoodInfluenceCard: View {
    /// Structured taxonomy rows (icon + localized label), strongest swing first.
    let structuredRows: [TagInfluenceRow]
    /// Flat free-text rows (rendered verbatim), strongest swing first.
    let flatRows: [TagInfluenceRow]
    /// Resolves a structured tag's icon/label from the live catalog.
    @Environment(MoodTagCatalogStore.self) private var catalog
    /// QoL-2 (A360-4) — gate the expand/collapse spring like the rest of the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false

    /// Collapsed cap across BOTH axes — a calm, scannable lead set.
    private static let collapsedCap = 5

    /// Combined, structured-first ordering. We do not interleave by delta: the
    /// curated taxonomy reads first (icon + label), free-text after.
    private var allRows: [TagInfluenceRow] {
        structuredRows + flatRows
    }

    private var visibleRows: [TagInfluenceRow] {
        expanded ? allRows : Array(allRows.prefix(Self.collapsedCap))
    }

    var body: some View {
        if allRows.isEmpty {
            EmptyView()
        } else {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text("Influence on your mood")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)

                    // The standing association-not-cause caption — once, up top,
                    // so every row reads under it.
                    Text("Average mood on days with a tag vs days without. These are associations, not causes.")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: HLSpace.sm) {
                        ForEach(visibleRows) { row in
                            MoodInfluenceRowView(
                                row: row,
                                resolvedLabel: label(for: row),
                                resolvedSymbol: symbol(for: row)
                            )
                        }
                    }

                    if allRows.count > Self.collapsedCap {
                        Button {
                            withAnimation(reduceMotion ? nil : HLMotion.spring) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show fewer" : "Show more")
                                .font(.hlSubhead.weight(.medium))
                                .foregroundStyle(HLText.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("insights.mood.influence.toggle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("insights.mood.influence")
        }
    }

    /// Localized display label: a structured tag resolves via the catalog
    /// (`labelKey`); a flat tag renders its free-text string verbatim.
    private func label(for row: TagInfluenceRow) -> String {
        if let key = row.labelKey {
            return MoodTagCatalogL10n.resolve(key)
        }
        return catalog.label(forTagKey: row.tag) ?? row.tag
    }

    /// SF Symbol for a structured tag (Lucide-mapped, catalog-aware); a flat
    /// tag with no catalog match falls back to a neutral `tag` glyph.
    private func symbol(for row: TagInfluenceRow) -> String {
        if let symbol = MoodTagSFSymbol.symbol(forLucide: row.icon) {
            return symbol
        }
        return "tag"
    }
}

/// One influence row: tag (icon + label) · a mono delta micro-bar · the signed
/// delta · a restrained confidence pill. Pure presentation — the host resolves
/// the label/symbol so this view stays catalog-agnostic + testable.
struct MoodInfluenceRowView: View {
    let row: TagInfluenceRow
    let resolvedLabel: String
    let resolvedSymbol: String

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: resolvedSymbol)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(width: 22, alignment: .center)

            Text(resolvedLabel)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .lineLimit(1)

            Spacer(minLength: HLSpace.sm)

            // Direction glyph + signed delta — sign + weight carry valence, no hue.
            HStack(spacing: HLSpace.xs) {
                Image(systemName: row.isPositive ? "arrow.up" : "arrow.down")
                    .font(.hlCaption.weight(row.isPositive ? .semibold : .regular))
                    .foregroundStyle(row.isPositive ? HLText.primary : HLText.secondary)
                Text(Self.deltaString(row.delta))
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }

            MoodConfidencePill(confidence: row.confidence)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resolvedLabel))
        .accessibilityValue(Text(Self.accessibilityValue(row, label: resolvedLabel)))
    }

    /// `"+0.7"` / `"−0.4"` (proper minus), locale decimal separator.
    nonisolated static func deltaString(_ delta: Double) -> String {
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return delta >= 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    /// VoiceOver value: direction + averages + signed delta + sample size +
    /// confidence — the full honest read, in words.
    nonisolated static func accessibilityValue(_ row: TagInfluenceRow, label: String) -> String {
        let withAvg = row.withAvg.formatted(.number.precision(.fractionLength(1)))
        let withoutAvg = row.withoutAvg.formatted(.number.precision(.fractionLength(1)))
        let signed = deltaString(row.delta)
        let confidence = MoodConfidencePill.label(for: row.confidence)
        return String(
            localized: "Mood \(withAvg) on days with \(label), \(withoutAvg) without. \(signed) difference, based on \(row.minGroupDays) days each side. \(confidence) confidence.",
            comment: "VoiceOver value for one mood tag-influence row"
        )
    }
}

/// A restrained Low/Med/High confidence pill. Monochrome — the band is encoded
/// by the localized WORD + ink weight, never by colour, so it can never read as
/// fake-precise statistical certainty.
struct MoodConfidencePill: View {
    let confidence: MoodConfidence

    var body: some View {
        Text(Self.label(for: confidence))
            .font(.hlCaption2.weight(.medium))
            .foregroundStyle(Self.ink(for: confidence))
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xxs)
            .background(
                HLSurface.tertiary,
                in: Capsule(style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// Higher confidence reads in primary ink; lower steps back to tertiary —
    /// weight, not hue, conveys the band.
    private static func ink(for confidence: MoodConfidence) -> Color {
        switch confidence {
        case .high: HLText.primary
        case .medium: HLText.secondary
        case .low: HLText.tertiary
        }
    }

    /// Localized band word.
    nonisolated static func label(for confidence: MoodConfidence) -> String {
        switch confidence {
        case .high: String(localized: "High", comment: "Mood relation confidence band: high")
        case .medium: String(localized: "Medium", comment: "Mood relation confidence band: medium")
        case .low: String(localized: "Low", comment: "Mood relation confidence band: low")
        }
    }
}
