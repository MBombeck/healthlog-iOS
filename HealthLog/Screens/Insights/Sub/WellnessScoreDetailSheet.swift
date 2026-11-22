import SwiftUI

/// **The wellness-score tap-through detail**, a sheet from the overview's
/// score rings and a pushed page from the recovery page's trend card.
/// Top to bottom: the server's assessment, the ranked contributor rows (a tap
/// deep-navigates to that contributor's metric page; STRAIN has no breakdown
/// and shows provenance instead), then the "Was ist das?" explainer LAST, so
/// the data comes first and the methodology second.
///
/// Every row is server-returned; the "insufficient" arm shows the
/// calm gate, not a fabricated score.
struct WellnessScoreDetailSheet: View {
    let dto: DerivedMetricDTO
    /// Deep-nav into a contributor's metric page (overview push seam). The sheet
    /// dismisses first, then the parent pushes the metric screen.
    let onSelectMetric: ((MetricKind) -> Void)?
    /// Deep-nav from the Stimmung contributor into the Mood special
    /// Insights page (mood is not a chartable `MetricKind`, so it needs its own
    /// seam). The sheet dismisses first, then the parent routes to the Mood page.
    var onSelectMood: (() -> Void)?
    /// `false` when pushed onto a stack (the recovery page) instead of
    /// presented as a sheet: the page then uses that stack's bar and back button.
    var embedsNavigationStack = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Issue-2 — the derived store, used to re-read the per-id route on open so
    /// the deterministic per-score `assessment` populates (the overview's BATCH
    /// route returns `assessment: null` by design).
    @Environment(DerivedInsightsStore.self) private var derivedStore

    /// Issue-2 — the per-id assessment fetched on open. The sheet is handed a
    /// BATCH DTO (no assessment), so the section paints from the single-route
    /// re-read. Falls back to whatever the incoming DTO carried.
    @State private var loadedAssessment: DerivedMetricDTO.Assessment?

    private var archetype: WellnessScorePresentation.Archetype {
        // v1.27.5 — DTO-aware: RECOVERY_SCORE promotes to the factor breakdown
        // when the server ships its readiness-blend `components[]`, else stays
        // provenance-only (watch-native recovery has no sub-scores).
        WellnessScorePresentation.archetype(for: dto)
    }

    /// The assessment to render: the single-route re-read if it landed, else the
    /// assessment the incoming DTO already carried (e.g. a future server that
    /// fills it on the batch too, or a unit-test fixture).
    private var effectiveAssessment: DerivedMetricDTO.Assessment? {
        loadedAssessment ?? dto.assessment
    }

    var body: some View {
        // The sheet dismisses by drag, the pushed page by its back button.
        Group {
            if embedsNavigationStack {
                // A sheet that only shows something: the close button.
                HLSheetScaffold(
                    verbatim: InsightsDerivedCopy.title(for: dto.metric),
                    size: .standard
                ) {
                    page
                }
            } else {
                page
            }
        }
        // Issue-2 — re-read the per-id route on open so the deterministic per-score
        // Einschätzung populates (the batch DTO carries `assessment: null`).
        .task(id: dto.metric) {
            guard WellnessScorePresentation.Archetype.isAssessable(dto.metric),
                  let fresh = await derivedStore.fetchSingle(metric: dto.metric),
                  let assessment = fresh.assessment else { return }
            loadedAssessment = assessment
        }
    }

    private var page: some View {
        HLPage {
            assessmentSection
            contributorsSection
            provenanceSection
            grundlageCard
        }
        .navigationTitle(Text(InsightsDerivedCopy.title(for: dto.metric)))
        .navigationBarTitleDisplayMode(.inline)
        // The score's citation pushes inside the surrounding stack,
        // whether that is the sheet's own or the page it was pushed onto.
        .hlSheetStack()
    }

    // MARK: - Assessment (D1 — the per-score "Einschätzung", FIRST)

    /// The server's short "why is this score what it is" explanation, shown
    /// directly under the score heading and ABOVE "Was zählt rein". Rendered as
    /// grey flowing prose (the same `.hlBody` / `HLText.secondary` idiom as the
    /// per-metric Einschätzung in `AssessmentCard.AssessmentBody` and the general
    /// health report), no card chrome, no AI provenance badge (operator: keep it
    /// clean prose).
    ///
    /// **Issue-2 — NOT AI-gated.** The per-score assessment is DETERMINISTIC: the
    /// server always fills `text` for an `ok` score (provider-less accounts + the
    /// demo included) and the web shows it unconditionally. The earlier
    /// `aiSurfacesVisible` gate (added with the per-score assessment) hid it for
    /// every `.none`-AI-mode user — i.e. the default privacy-first user — which is
    /// the regression the operator saw. We only self-suppress on no/empty text
    /// (HONEST-ONLY — never fabricated). AI prose, when warmed, overrides the
    /// deterministic text server-side, so this one binding covers both.
    @ViewBuilder
    private var assessmentSection: some View {
        if let assessment = effectiveAssessment,
           !assessment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // v0162 readability — flowing prose (inline Markdown + preserved
            // paragraph breaks + line spacing) instead of a dense plain block.
            HLInsightProse(text: assessment.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("insights.scoreSheet.assessment")
        }
    }

    // MARK: - Contributor rows (ranked breakdown)

    @ViewBuilder
    private var contributorsSection: some View {
        let contributors = WellnessScorePresentation.rankedContributors(dto)
        if archetype == .scoreWithBreakdown, !contributors.isEmpty {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                HLSectionHeader("What counts here", rank: .area)
                // One card of rows, not a card per contributor.
                HLCard(layout: .rows) {
                    // Cap the mounted rows (perf) — the breakdowns are ≤5 today.
                    ForEach(contributors.prefix(6)) { contributor in
                        ContributorRow(contributor: contributor, canNavigateMood: onSelectMood != nil) {
                            // Mood is a SPECIAL page, not a chartable
                            // `MetricKind`; route it via `onSelectMood`. All other
                            // contributors deep-nav into their metric chart page.
                            if contributor.key == "mood" {
                                guard let onSelectMood else { return }
                                dismiss()
                                onSelectMood()
                                return
                            }
                            guard let kind = contributor.deepNavKind, let onSelectMetric else { return }
                            dismiss()
                            onSelectMetric(kind)
                        }
                    }
                }
            }
            .hlContainerGap(HLLayout.cardGap)
        }
    }

    // MARK: - Provenance (STRAIN + the no-breakdown scores)

    @ViewBuilder
    private var provenanceSection: some View {
        // STRAIN / RECOVERY / STRESS have no sub-decomposition → show the
        // provenance + reason instead of contributor rows.
        if archetype == .scoreProvenanceOnly {
            HLCard("How this is measured") {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    // One origin line: the window, and for recovery
                    // which source backs the number (W-B187 #29: the server
                    // resolves WHOOP-native vs the computed proxy, so the read
                    // is never misattributed).
                    Text(provenanceText)
                        .hlText(.factLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("insights.scoreSheet.recoverySource")
                    if let reason = dto.reason, !reason.isEmpty {
                        Text(reason)
                            .hlText(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The provenance line, with the recovery source joined to it. Only
    /// RECOVERY_SCORE carries a WHOOP-vs-computed authority decision; every other
    /// provenance-only score (STRAIN / STRESS) keeps the window alone. Reads the
    /// server-resolved source — never fabricated.
    private var provenanceText: String {
        let window = InsightsDerivedCopy.provenanceLine(for: dto.provenance)
        guard dto.metric == "RECOVERY_SCORE" else { return window }
        let source = WellnessScorePresentation.isWhoopNativeRecovery(dto)
            ? String(localized: "insights.provenance.recovery.whoop")
            : String(localized: "insights.provenance.recovery.hrv")
        return window + ", " + source
    }

    // MARK: - "Was ist [Metrik]?" (explainer, LAST)

    /// Replaces the boring "Server-computed from your own data …"
    /// provenance line with a plain-language "Was ist [Metrik]?" explainer of
    /// WHAT the metric IS. Falls back to the honesty caveat below. The heading
    /// names the metric ("Was ist Cardio-Fitness?").
    private var grundlageCard: some View {
        // The title is already localized; as a key it finds no entry and
        // stands as it is.
        HLCard(LocalizedStringKey(InsightsDerivedCopy.whatIsTitle(for: dto.metric)), style: .outline) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let whatIs = InsightsDerivedCopy.whatIs(for: dto) {
                    Text(whatIs)
                        .hlText(.factLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat = InsightsDerivedCopy.caveat(for: dto) {
                    Text(caveat)
                        .hlText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 1.0.3 (App Review 1.4.1) — the guideline literature behind
                // this derived score, one tap from the claim it qualifies.
                HLSourcesLink(topic: .derivedScore(dto.metric))
            }
        }
    }
}

// MARK: - Contributor row

private struct ContributorRow: View {
    let contributor: WellnessScorePresentation.Contributor
    /// True when the parent can route the Stimmung (mood) special
    /// page, so the mood row reads tappable even though it has no `deepNavKind`.
    var canNavigateMood: Bool = false
    let onTap: () -> Void

    private var isTappable: Bool {
        contributor.deepNavKind != nil || (contributor.key == "mood" && canNavigateMood)
    }

    var body: some View {
        // One data row: the ring in the symbol column, name and weight (or
        // the reason a sub-score is withheld), the value on the right. A
        // tappable row opens its page as a whole, without a chevron.
        let row = HLRow(
            title: Text(verbatim: contributor.label),
            detail: Text(verbatim: contributor.gapReason ?? weightCaption),
            value: Text(verbatim: contributor.valueText)
        ) {
            HLScoreRing(
                fraction: contributor.fraction ?? 0,
                signal: contributor.signal,
                compact: true
            )
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
        }
        if isTappable {
            HLRowButton(action: onTap) { row }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
                .accessibilityIdentifier("insights.scoreSheet.contributor.\(contributor.key)")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityIdentifier("insights.scoreSheet.contributor.\(contributor.key)")
        }
    }

    /// "Weight · 25 %" — the effective share after null-redistribution.
    private var weightCaption: String {
        let pct = Int((contributor.weight * 100).rounded())
        return String(localized: "Weight · \(HLNumberFormat.percent(pct))")
    }

    private var accessibilityLabel: String {
        // A withheld sub-score reads its reason, not an empty value.
        if let reason = contributor.gapReason { return "\(contributor.label), \(reason)" }
        return "\(contributor.label), \(contributor.valueText), \(weightCaption)"
    }
}
