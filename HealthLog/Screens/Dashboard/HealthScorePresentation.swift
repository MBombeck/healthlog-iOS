import Foundation

/// **Localized copy for the Health Score v2 fields (server v1.34.0).**
///
/// App-target only on purpose: ``HealthLog/Models`` compiles into the widget
/// extension, and none of this prose belongs in the widget's catalogue.
///
/// The delta copy carries the one rule that matters on this surface: when the
/// server withheld a delta because its own way of measuring changed
/// (`algorithm_changed`, `composition_changed`, `first_eligibility_window`,
/// `below_noise_floor`), the text says *the method moved*, never *you moved*.
/// A step caused by a new formula is not news about a person, and the wording
/// here is what keeps those two apart on screen.
enum HealthScorePresentation {
    // MARK: - Which explanatory sections a score earns

    /// The explanatory cards the detail sheet shows for a given score, in
    /// render order. Each one is *earned* by a field the server actually sent —
    /// there is no placeholder card for data we do not have.
    ///
    /// Split out as a pure function so the sheet and its tests agree on the
    /// same predicates instead of restating them.
    enum Section: Hashable, CaseIterable {
        /// Why there is no week-over-week delta.
        case deltaReason
        /// Which pillars carried the score (+ which one set the band colour).
        case composition
        /// Coverage-derived confidence in the number.
        case confidence
        /// An active rest phase framing the window. The illness module gate
        /// still applies on top of this, inside the view.
        case restMode
    }

    /// The sections earned by `score`, in the order the sheet renders them.
    static func sections(for score: HealthScore) -> [Section] {
        var sections: [Section] = []
        if score.deltaReason != nil { sections.append(.deltaReason) }
        if let composition = score.composition, !composition.isEmpty { sections.append(.composition) }
        if score.confidence != nil { sections.append(.confidence) }
        if score.activeRestMode != nil { sections.append(.restMode) }
        return sections
    }

    // MARK: - Pillars

    /// Catalog key for a pillar's short label — **the one place a pillar is
    /// named.** The composition card and the settings surface both go through
    /// here, so the same pillar can never be called two things in one app
    /// (R6: one domain, one description, one definition site).
    static func labelKey(for pillar: HealthScorePillar) -> String {
        switch pillar {
        case .bloodPressure: "Blood pressure"
        case .glycaemia: "Blood sugar"
        case .activity: "Activity"
        case .sleep: "Sleep"
        case .adiposity: "Waist"
        case .wellbeing: "Wellbeing"
        case .fitness: "Fitness"
        case .lipids: "Blood lipids"
        case .unknown: "Additional pillar"
        }
    }

    /// Short label for a score pillar. An id this client does not know yet gets
    /// a neutral placeholder instead of a raw server token.
    static func label(for pillar: HealthScorePillar) -> String {
        String(localized: String.LocalizationValue(labelKey(for: pillar)))
    }

    // MARK: - Chosen composition (v1.35.0 / GH #83)

    // 25-02 (E-2026-08-29 #3) — the painted provenance mark („Eigene
    // Auswahl" / "Your selection") was DELETED, definition site and catalog
    // key together: the operator judged it visual overload on the score
    // tile. The statement survives in its two other carriers — the spoken
    // sentence below and the explanation on the detail surfaces.

    /// The spoken provenance — appended to a score surface's accessibility
    /// label so the spoken tile says where the number's make-up came from.
    /// A full sentence, because VoiceOver reads it in a run with the score
    /// and a bare noun phrase would blur into it. Since 25-02 this is the
    /// ONLY tile-level carrier of the statement (the painted mark is gone).
    static var chosenCompositionA11y: String {
        String(
            localized: "The pillars behind this score were chosen by you.",
            comment: "Health Score a11y — the composition was chosen by the person"
        )
    }

    /// **Why a score built on one composition cannot be read against another.**
    ///
    /// The mark carries the fact; this carries its consequence. Deliberately
    /// framed around the compositions rather than around the reader ("you
    /// chose…"), because it has to hold in both tenses: standing beside a score
    /// that already runs on a chosen composition, and standing beside a save
    /// that is about to change one. One definition site, so the two placements
    /// cannot drift apart.
    static var chosenCompositionExplanation: String {
        String(
            localized: "A score built from a different selection measures something else, so the two numbers cannot be compared.",
            comment: "Health Score — what a self-chosen composition means for comparisons"
        )
    }

    // MARK: - Refused selections

    /// **Why the server will not build a score from this selection.**
    ///
    /// Each sentence says what the limit is *for*, because "at least three
    /// areas" without the reason reads as an arbitrary hurdle. Deliberately
    /// composed here rather than echoing the server's own prose: that text is
    /// written for the web client, and it enumerates which pillars sit in which
    /// area — a mapping that lives only on the server and would go stale in a
    /// client string the first time the catalogue moves.
    static func explanation(for reason: HealthScoreBreadthReason) -> String {
        switch reason {
        case .threeDomainsRequired:
            String(
                // swiftlint:disable:next line_length
                localized: "This selection covers fewer than three different areas of health. A composite built from one or two areas would not be an overall score, only that one area under another name — and several pillars can describe the same area, in which case they count together as one.",
                comment: "Health Score composition refused — too few distinct health domains"
            )
        case .measuredPhysiologicalDomainRequired:
            String(
                // swiftlint:disable:next line_length
                localized: "This selection contains no pillar that is physically measured. Without a measurement taken on your body the number would only summarise what you record about yourself, so keep at least one measured pillar in the selection.",
                comment: "Health Score composition refused — no measured physiological pillar"
            )
        case .unknown:
            String(
                localized: "No score can be built from this selection. Add another pillar and try again.",
                comment: "Health Score composition refused — reason this client does not know"
            )
        }
    }

    // MARK: - Confidence

    /// Qualitative confidence label.
    static func label(for band: HealthScoreConfidenceBand) -> String {
        switch band {
        case .high: String(localized: "High confidence", comment: "Health Score confidence band")
        case .medium: String(localized: "Medium confidence", comment: "Health Score confidence band")
        case .low: String(localized: "Low confidence", comment: "Health Score confidence band")
        case .draft: String(localized: "Provisional", comment: "Health Score confidence band")
        case .unknown: String(localized: "Confidence unknown", comment: "Health Score confidence band")
        }
    }

    // MARK: - Delta reason

    /// Short caption replacing the week-over-week chip on the tile.
    static func shortLabel(for reason: HealthScoreDeltaReason) -> String {
        switch reason {
        case .algorithmChanged:
            String(localized: "Calculation changed", comment: "Health Score delta reason")
        case .compositionChanged:
            String(localized: "Different basis", comment: "Health Score delta reason")
        case .firstEligibilityWindow:
            String(localized: "First full week", comment: "Health Score delta reason")
        case .belowNoiseFloor:
            String(localized: "Within normal variation", comment: "Health Score delta reason")
        case .noPreviousWindow:
            String(localized: "No previous week", comment: "Health Score delta reason")
        case .noCurrentScore:
            String(localized: "No current value", comment: "Health Score delta reason")
        case .unknown:
            String(localized: "No comparison", comment: "Health Score delta reason")
        }
    }

    /// The full explanation shown in the detail sheet.
    ///
    /// `algorithm_changed` gets the most explicit wording of the six: the
    /// number moved because the server changed how it counts, and that is a
    /// statement about the measurement, not about the person being measured.
    static func explanation(for reason: HealthScoreDeltaReason) -> String {
        switch reason {
        case .algorithmChanged:
            String(
                localized: "The way this score is calculated changed. Any step you see is a change in the method, not a change in you — so this week is not compared with the last one.",
                comment: "Health Score delta reason explanation"
            )
        case .compositionChanged:
            String(
                localized: "Other pillars carried the score than last week, so the two numbers are not measuring the same thing. No comparison is shown.",
                comment: "Health Score delta reason explanation"
            )
        case .firstEligibilityWindow:
            String(
                localized: "This is the first week with enough data for a score. There is nothing before it to compare against yet.",
                comment: "Health Score delta reason explanation"
            )
        case .belowNoiseFloor:
            String(
                localized: "The change stayed smaller than this score's own margin of variation, so it is not reported as a change.",
                comment: "Health Score delta reason explanation"
            )
        case .noPreviousWindow:
            String(
                localized: "There is no previous week to compare against.",
                comment: "Health Score delta reason explanation"
            )
        case .noCurrentScore:
            String(
                localized: "There is no current value to compare.",
                comment: "Health Score delta reason explanation"
            )
        case .unknown:
            String(
                localized: "No week-over-week comparison is available for this score.",
                comment: "Health Score delta reason explanation"
            )
        }
    }

    // MARK: - Band setter

    /// Which pillar set the colour — an explanation of the band, never a
    /// verdict about the pillar.
    static func bandSetterLine(for pillar: HealthScorePillar) -> String {
        String(
            localized: "\(label(for: pillar)) set the colour of this score.",
            comment: "Health Score band setter explanation"
        )
    }

    // MARK: - Rest mode

    /// Calm framing for an active rest phase: it explains the window the score
    /// was measured in and never changes the number.
    static func restModeLine(for restMode: RestModeAnnotation) -> String {
        guard let since = restMode.since else {
            return String(
                localized: "A rest phase is running. It frames this score, it does not change it.",
                comment: "Health Score rest mode explanation"
            )
        }
        let date = since.formatted(.dateTime.day().month(.abbreviated))
        return String(
            localized: "A rest phase has been running since \(date). It frames this score, it does not change it.",
            comment: "Health Score rest mode explanation with onset"
        )
    }
}
