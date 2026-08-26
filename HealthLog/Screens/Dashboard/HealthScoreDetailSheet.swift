import SwiftUI

/// Detail surface for the Health Score tile.
///
/// **v1.34.0 (CU-31) — explanations, not verdicts.** The rebuilt composite ships
/// its own identity alongside the number: which pillars carried it
/// (`composition`), how well covered it is (`confidence`), which pillar set the
/// colour (`bandSetter`), whether a rest phase framed the window (`restMode`),
/// and — when there is no week-over-week delta — *why* (`deltaReason`).
///
/// Nothing on this sheet is computed on device. The old "Composite formula"
/// line and the four-pillar provenance accordion are gone with the server's old
/// `components` object; the score's own composition took their place.
public struct HealthScoreDetailSheet: View {
    @Environment(HealthScoreStore.self) private var store
    @Environment(InsightsStore.self) private var insightsStore

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let score = store.score {
                    VStack(alignment: .leading, spacing: HLSpace.lg) {
                        HealthScoreLoaded(score: score)
                            .padding(.horizontal, HLSpace.sm)
                        // Each explanatory card is earned by a field the server
                        // actually sent — see `HealthScorePresentation.sections`.
                        ForEach(HealthScorePresentation.sections(for: score), id: \.self) { section in
                            switch section {
                            case .deltaReason: DeltaReasonCard(score: score)
                            case .composition: CompositionCard(score: score)
                            case .confidence: ConfidenceCard(score: score)
                            case .restMode: RestModeCard(score: score)
                            }
                        }
                        DataProvenanceLine(digest: insightsStore.digest)
                        DocumentationCard()
                    }
                    .padding(.horizontal, HLSpace.lg)
                    .padding(.vertical, HLSpace.lg)
                } else if let error = store.error {
                    // PB5-review F3: PB5 removed `.disabled` on `HealthScoreTile`
                    // ("the detail sheet renders its own error states") — but
                    // pre-F3 this branch did not exist, so an errored tap opened
                    // an infinite-skeleton sheet. Reuse the existing
                    // `HealthScoreErrorState` view (kept lightweight + retry-
                    // capable) so the user gets an explanation and a way out.
                    VStack(alignment: .leading, spacing: HLSpace.lg) {
                        HLCard {
                            HealthScoreErrorState(error: error) {
                                Task { await store.refresh() }
                            }
                        }
                        DocumentationCard()
                    }
                    .padding(.horizontal, HLSpace.lg)
                    .padding(.vertical, HLSpace.lg)
                } else {
                    HealthScoreSkeleton()
                        .padding(HLSpace.lg)
                }
            }
            .hlScreenBackground()
            // v0.5.x C-9 — iOS 26+ soft scroll-edge so content blurs into
            // the sheet's Liquid Glass header instead of clipping cleanly.
            // iOS 18-25: no-op (system stays flat-translucent).
            .hlScrollEdgeSoft()
            .navigationTitle(String(localized: "Health Score"))
            .navigationBarTitleDisplayMode(.inline)
            // v0.6.1 Y2 — Home-Compliance pattern: drop the 'Fertig'
            // confirmationAction toolbar item (`docs/design-handbook-v1.md
            // §2.6 / AP-007`). Drag-indicator + swipe-down is the dismiss.
        }
    }
}

// MARK: - Why there is no week-over-week delta

/// **The `deltaReason` card — CU-31's core honesty rule.**
///
/// When the server withholds the delta it also says why. Four of the six
/// reasons are statements about the *measurement*: the formula changed
/// (`algorithm_changed`), the pillar set changed, this is the first eligible
/// window, or the move sat inside the noise floor. This card says exactly that,
/// so a step in the number caused by a new calculation is never told as a step
/// in the person's health. Self-suppresses when a real delta is present.
private struct DeltaReasonCard: View {
    let score: HealthScore

    var body: some View {
        if let reason = score.deltaReason {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text(HealthScorePresentation.shortLabel(for: reason))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(HealthScorePresentation.explanation(for: reason))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Composition

/// What carried this score — the server-resolved pillar list, in the server's
/// order. A list of names, not values: the per-pillar numbers deliberately do
/// not ride this wire, and iOS invents none. The `bandSetter` line explains
/// which pillar decided the colour.
private struct CompositionCard: View {
    let score: HealthScore

    var body: some View {
        if let composition = score.composition, !composition.isEmpty {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text(String(localized: "What this score is made of", comment: "Health Score composition section"))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(composition, id: \.rawValue) { pillar in
                            PillarRow(pillar: pillar, isBandSetter: pillar == score.bandSetter)
                        }
                    }
                    if let bandSetter = score.bandSetter {
                        Text(HealthScorePresentation.bandSetterLine(for: bandSetter))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // v1.35.0 (GH #83) — the detail surface is the one place
                    // with room to say what a chosen composition *means*. The
                    // tile carries the bare provenance mark; the sentence about
                    // comparability belongs here, next to the list it is about.
                    if score.runsOnChosenComposition {
                        Text(HealthScorePresentation.chosenCompositionExplanation)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(String(
                        localized: "Only pillars with enough data carry the score. Missing ones are left out, never guessed.",
                        comment: "Health Score composition footnote"
                    ))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PillarRow: View {
    let pillar: HealthScorePillar
    let isBandSetter: Bool

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Text(HealthScorePresentation.label(for: pillar))
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.primary)
            Spacer(minLength: 0)
            if isBandSetter {
                Text(String(localized: "sets the colour", comment: "Health Score band setter marker"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confidence

/// How well covered the number is (`confidence: { score, band }`). Rendered
/// verbatim — the coverage score comes from the server's own `deriveCoverage`.
private struct ConfidenceCard: View {
    let score: HealthScore

    var body: some View {
        if let confidence = score.confidence {
            HLCard(style: .ghost) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text(String(localized: "Confidence", comment: "Health Score confidence section"))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    HStack(spacing: HLSpace.sm) {
                        Text(HealthScorePresentation.label(for: confidence.band))
                            .font(.hlSubhead.weight(.medium))
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: 0)
                        Text(verbatim: HLNumberFormat.percent(confidence.score))
                            .font(.hlMetric(.body))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(
                localized: "Confidence \(HealthScorePresentation.label(for: confidence.band)), \(confidence.score) percent coverage",
                comment: "Health Score confidence a11y label"
            )))
        }
    }
}

// MARK: - Rest mode

/// The rest-phase framing — an explanation of the window this score was
/// measured in. It never changed the number, and it never reads as a verdict.
private struct RestModeCard: View {
    let score: HealthScore

    var body: some View {
        RestModeGate(score: score) { restMode in
            HLCard(style: .ghost) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text(String(localized: "Rest phase", comment: "Health Score rest mode section"))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    Text(HealthScorePresentation.restModeLine(for: restMode))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Documentation

private struct DocumentationCard: View {
    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(String(localized: "How the score works"))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(String(
                    // swiftlint:disable:next line_length
                    localized: "Up to eight pillars can carry this score: blood pressure, blood sugar, activity, sleep, waist, wellbeing, fitness and blood lipids. Only the ones with enough data count — a missing pillar is left out rather than filled in with a guess.",
                    comment: "Health Score explainer"
                ))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Data provenance line

//
// v0.4.0 Stream Golf (A8 §6.3): surfaces "Berechnet aus N Messungen über M Tage"
// beneath the score. Pulls data from `comprehensive.dataSpanDays` +
// `comprehensive.totalMeasurements` (same source as the Insights footer).

private struct DataProvenanceLine: View {
    let digest: ComprehensiveDigest?

    var body: some View {
        if let digest, let span = digest.dataSpanDays, let total = digest.totalMeasurements, total > 0 {
            HLCard(style: .ghost) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundStyle(HLText.tertiary)
                    Text(String(localized: "Calculated from \(total) measurements over \(span) days."))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
