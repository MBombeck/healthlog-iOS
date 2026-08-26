import SwiftUI

/// v1.25 (GH iOS #38) — the sleep-breathing screening awareness card.
///
/// Renders `GET /api/insights/breathing-screening`
/// (`InsightsBreathingScreeningDTO`): the device's own per-night
/// breathing-disturbance index + flagged events over the last ~30 nights, folded
/// server-side into a calm summary. **Screening signal only — never a diagnosis**
/// (mirrors the server's explicit register). HealthLog invents no threshold;
/// the classification IS the device's own.
///
/// **Server-authoritative, render-don't-recompute.** The card **self-suppresses**
/// when the read is absent / not present.
struct InsightsBreathingScreeningCard: View {
    let screening: InsightsBreathingScreeningDTO?

    var body: some View {
        if let screening, screening.hasContent {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSectionLabel("clinicalSignals.breathing.title")

                    HStack(alignment: .top, spacing: HLSpace.sm) {
                        Image(systemName: "lungs.fill")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text(classificationText)
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Text(detailLine)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)

                    Text("clinicalSignals.breathing.caption")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("insights.clinicalSignals.breathing")
        }
    }

    private var classificationText: String {
        switch screening?.classification {
        case "elevated": String(localized: "clinicalSignals.breathing.classification.elevated")
        case "not-elevated": String(localized: "clinicalSignals.breathing.classification.notElevated")
        default: String(localized: "clinicalSignals.breathing.classification.unknown")
        }
    }

    /// "Across N nights · M flagged events · trending …" — only the parts the
    /// server returned (HONEST-ONLY: no fabricated trend on too few nights).
    private var detailLine: String {
        guard let screening else { return "" }
        var parts: [String] = []
        parts.append(String(format: String(localized: "clinicalSignals.breathing.nights"), screening.nights))
        if screening.eventCount > 0 {
            parts.append(String(format: String(localized: "clinicalSignals.breathing.events"), screening.eventCount))
        }
        if let trend = trendText { parts.append(trend) }
        return parts.joined(separator: " · ")
    }

    private var trendText: String? {
        switch screening?.trend {
        case "up": String(localized: "clinicalSignals.breathing.trend.up")
        case "down": String(localized: "clinicalSignals.breathing.trend.down")
        case "stable": String(localized: "clinicalSignals.breathing.trend.stable")
        default: nil
        }
    }
}
