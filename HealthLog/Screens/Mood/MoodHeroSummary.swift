import SwiftUI

/// v0.10.0 W-Mood-A — zone-1 hero summary (DESIGN-A §1.3).
///
/// "Here is how you feel now": latest mood (big value) + 30-day average + the
/// prior-period trend as a calm caption line.
///
/// **I-4 Item 2 (standardisation):** the card was reworked to read like every
/// other Insights card (`InsightsPrimaryTile` / `BPStatusCard`): a
/// secondary-caption heading, the big headline value, and the trend folded into
/// a single bottom **caption line with a leading direction glyph** — instead of
/// the old free-floating `arrow.up.right` glyph parked in the value row, which
/// the operator flagged as "not conform with the other cards". The trend
/// direction still reads (the small glyph IN the caption), but there is no
/// off-pattern arrow affordance any more. Monochrome; the glyph warms only when
/// the trend is adverse (mood is higher-is-better → a falling slope warms).
struct MoodHeroSummary: View {
    let insights: MoodInsights

    var body: some View {
        HLCard {
            // v0.14.7 B5 — the "Stimmung heute" title moved OUT of the card to a
            // section heading above it (`MoodAnalysisContent` section 0); the
            // card now leads with the value, matching the metric tiles.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                    Text(latestLabel)
                        // Audit-01 H3 — semantic metric style (28pt @ Large)
                        // instead of the pixel-locked escape hatch, so the hero
                        // value scales with Dynamic Type.
                        .font(.hlMetric(.title))
                        .foregroundStyle(HLText.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let avg30 = insights.avg30 {
                        Text("Ø 30d \(avg30.formatted(.number.precision(.fractionLength(1))))")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }

                trendLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Current mood"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var latestLabel: String {
        guard let score = insights.latestScore else { return "—" }
        return MoodCopy.scoreLabel(score)
    }

    /// I-4 Item 2 — the trend, rendered as ONE calm caption line (leading
    /// direction glyph + the "+0.4 vs last month" delta), so the card matches
    /// the canonical "heading → value → caption" anatomy. Omitted when there is
    /// neither a slope nor a prior-period delta. The glyph warms only on an
    /// adverse (falling) slope; rising/flat stays monochrome (no
    /// green-for-up moralising).
    @ViewBuilder
    private var trendLine: some View {
        if let slope = insights.slope30 ?? insights.slope7 {
            let adverse = slope < -0.02
            let symbol = slope > 0.02
                ? "arrow.up.right"
                : (slope < -0.02 ? "arrow.down.right" : "arrow.right")
            HStack(spacing: HLSpace.xs) {
                Image(systemName: symbol)
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(adverse ? HLColor.statusBad : HLText.secondary)
                    .accessibilityHidden(true)
                if let deltaLine {
                    Text(deltaLine)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .monospacedDigit()
                }
            }
        } else if let deltaLine {
            Text(deltaLine)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .monospacedDigit()
        }
    }

    /// "+0.4 vs last month" line — omitted when there's no prior period.
    private var deltaLine: String? {
        guard let avg30 = insights.avg30, let prior = insights.avg30PriorPeriod else { return nil }
        let delta = avg30 - prior
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(1)))
        let signed = delta >= 0 ? "+\(magnitude)" : "−\(magnitude)"
        return String(localized: "\(signed) vs last month")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let score = insights.latestScore {
            parts.append(String(localized: "Latest \(MoodCopy.scoreLabel(score))"))
        }
        if let avg30 = insights.avg30 {
            parts.append(String(localized: "30-day average \(avg30.formatted(.number.precision(.fractionLength(1))))"))
        }
        if let slope = insights.slope30 ?? insights.slope7 {
            let dir = slope > 0.02
                ? String(localized: "rising")
                : (slope < -0.02 ? String(localized: "falling") : String(localized: "steady"))
            parts.append(String(localized: "trend \(dir)"))
        }
        if let line = deltaLine { parts.append(line) }
        return parts.joined(separator: ". ")
    }
}
