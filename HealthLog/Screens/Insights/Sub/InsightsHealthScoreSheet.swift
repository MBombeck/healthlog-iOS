import SwiftUI

/// **The health score's detail**, a sheet from its card on the Insights
/// overview, the same way every other score card opens its detail.
///
/// Top to bottom, in the order of a detail page: the number, what the
/// comparison with last week says, the pillars that carried it, how well it
/// is covered, then what the score is. Every value is the server's
/// (`HealthScoreStore.score`); nothing is computed here.
///
/// The server sends no history of the score, so the sheet has no course and
/// no statistics; it shows only what the snapshot carries.
struct InsightsHealthScoreSheet: View {
    @Environment(HealthScoreStore.self) private var store

    var body: some View {
        HLSheetScaffold("Health score", size: .standard) {
            HLPage {
                if let score = store.score {
                    InsightsHealthScoreContent(score: score)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The sheet's sections for one score.
struct InsightsHealthScoreContent: View {
    let score: HealthScore

    var body: some View {
        head
        comparison
        pillars
        confidence
        background
    }

    // MARK: - The number

    /// The ring the card shows, larger, with the comparison under it.
    private var head: some View {
        let appearance = InsightsTileStyle.prismUniform.appearance(signal: nil)
        return VStack(spacing: HLSpace.sm) {
            HLScoreRing(
                fraction: Double(score.score) / 100,
                value: String(score.score),
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor,
                accessibilityLabel: String(localized: "\(String(localized: "Health score")) \(String(score.score)) of 100")
            )
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            // The same prism on the filled arc as on the card, so the score
            // is the same ring wherever it stands.
            .insightsRingEffect(appearance.ringEffect, fraction: Double(score.score) / 100, isHero: true)
            if let line = Self.comparisonLine(score) {
                Text(verbatim: line)
                    .hlText(.factLabel)
            }
            if let basis = score.scoreBasis {
                Text(verbatim: HealthScorePresentation.basisLine(basis))
                    .hlText(.rowSubtitle)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.healthScoreSheet.head")
    }

    /// The tile ring's size; the sheet shows the same ring the card does.
    static let ringDiameter: CGFloat = 96

    /// "+3 vs. last week", or the short reason there is no comparison.
    static func comparisonLine(_ score: HealthScore) -> String? {
        if let delta = score.delta {
            let number = HLValueFormat.signedNumber(Double(delta), fractionDigits: 0 ... 0)
            return String(localized: "insights.healthScore.delta \(number)")
        }
        return score.deltaReason.map(HealthScorePresentation.shortLabel(for:))
    }

    // MARK: - Why there is no comparison

    /// The reason in full when the server withheld the week's change. A step
    /// caused by a new method is said to be one, never a change in the person.
    @ViewBuilder
    private var comparison: some View {
        if let reason = score.deltaReason {
            HLCard {
                Text(HealthScorePresentation.explanation(for: reason))
                    .hlText(.factLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        RestModeGate(score: score) { restMode in
            HLCard {
                Text(HealthScorePresentation.restModeLine(for: restMode))
                    .hlText(.factLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pillars

    /// The pillars that carried the score, in the server's order. Names only:
    /// the per-pillar values do not ride this wire, and none is made up.
    @ViewBuilder
    private var pillars: some View {
        if let composition = score.composition, !composition.isEmpty {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                HLSectionHeader("What counts here", rank: .area)
                HLCard(layout: .rows) {
                    ForEach(composition, id: \.rawValue) { pillar in
                        HLRow(
                            title: Text(verbatim: HealthScorePresentation.label(for: pillar)),
                            value: pillar == score.bandSetter ? Text("insights.healthScore.setsColour") : nil
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("insights.healthScoreSheet.pillar.\(pillar.rawValue)")
                    }
                }
                ForEach(Self.pillarNotes(score), id: \.self) { note in
                    Text(verbatim: note)
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .hlContainerGap(HLLayout.cardGap)
        }
    }

    /// The notes under the pillars: a pillar set that changed, a selection
    /// the person made, a score without a measured pillar.
    static func pillarNotes(_ score: HealthScore) -> [String] {
        var notes: [String] = []
        if let notice = score.compositionNotice {
            notes += HealthScorePresentation.noticeLines(notice)
        }
        if score.runsOnChosenComposition {
            notes.append(HealthScorePresentation.chosenCompositionExplanation)
        }
        if let basis = score.scoreBasis, !basis.physiological {
            notes.append(HealthScorePresentation.basisWithoutPhysiology)
        }
        return notes
    }

    // MARK: - Confidence

    @ViewBuilder
    private var confidence: some View {
        if let confidence = score.confidence {
            HLCard {
                // The band names itself ("High confidence"); the server's
                // coverage stands beside it.
                HLFactRow(
                    label: Text(verbatim: HealthScorePresentation.label(for: confidence.band)),
                    value: Text(verbatim: HLNumberFormat.percent(confidence.score))
                )
            }
        }
    }

    // MARK: - What the score is

    private var background: some View {
        HLCard("insights.healthScore.whatIs.title", style: .outline) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("insights.healthScore.whatIs.body")
                    .hlText(.factLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HLSourcesLink(topic: .healthScore)
            }
        }
    }
}
