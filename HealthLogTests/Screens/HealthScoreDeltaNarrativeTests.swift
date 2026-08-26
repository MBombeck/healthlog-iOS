import Foundation
@testable import HealthLog
import Testing

/// **CU-31 — how a withheld delta is told, and how the detail sheet explains
/// the score.**
///
/// The rule under test: when the server says the delta is missing because *its
/// own way of measuring changed* (`algorithm_changed` first among them), the
/// surface must not narrate a change in the person. It shows the reason
/// instead — a statement about the method, never about the user's health.
///
/// The second half pins the acceptance criterion that the detail sheet shows
/// the score's composition and its confidence, and that each explanatory card
/// is earned by a field the server actually sent.
@Suite("Health Score v2 — delta narrative + detail sections")
struct HealthScoreDeltaNarrativeTests {
    private func score(
        delta: Int?,
        reason: HealthScoreDeltaReason?,
        confidence: HealthScoreConfidence? = nil,
        composition: [HealthScorePillar]? = nil,
        restMode: RestModeAnnotation? = nil
    ) -> HealthScore {
        HealthScore(
            score: 71,
            band: .yellow,
            delta: delta,
            confidence: confidence,
            composition: composition,
            deltaReason: reason,
            scoreVersion: 2,
            bandSetter: composition?.last,
            restMode: restMode
        )
    }

    // MARK: - The narrative gate

    @Test("algorithm_changed suppresses the week-over-week narrative")
    func algorithmChangedSuppressesNarrative() {
        let subject = score(delta: nil, reason: .algorithmChanged)
        #expect(subject.suppressesDeltaNarrative)
        #expect(subject.narratableDelta == nil)
        // It is a statement about the measurement, not about the person.
        #expect(subject.deltaReason?.isMeasurementArtefact == true)
    }

    @Test("a plain delta with no reason IS narrated")
    func plainDeltaIsNarrated() {
        let subject = score(delta: -4, reason: nil)
        #expect(subject.suppressesDeltaNarrative == false)
        #expect(subject.narratableDelta == -4)
    }

    @Test("first_eligibility_window and below_noise_floor are held to the same rule")
    func siblingArtefactsSuppressToo() {
        for reason in [HealthScoreDeltaReason.firstEligibilityWindow, .belowNoiseFloor] {
            let subject = score(delta: nil, reason: reason)
            #expect(subject.suppressesDeltaNarrative)
            #expect(subject.narratableDelta == nil)
            #expect(subject.deltaReason?.isMeasurementArtefact == true)
        }
    }

    /// Every reason gets its own words. A shared or empty caption would collapse
    /// "the formula changed" into "no data yet", which are different facts.
    @Test("each delta reason has its own non-empty short label and explanation")
    func reasonCopyIsDistinct() {
        let reasons: [HealthScoreDeltaReason] = [
            .algorithmChanged, .compositionChanged, .firstEligibilityWindow,
            .belowNoiseFloor, .noPreviousWindow, .noCurrentScore, .unknown("future_reason")
        ]
        let shortLabels = reasons.map(HealthScorePresentation.shortLabel(for:))
        let explanations = reasons.map(HealthScorePresentation.explanation(for:))

        #expect(shortLabels.allSatisfy { !$0.isEmpty })
        #expect(explanations.allSatisfy { !$0.isEmpty })
        #expect(Set(shortLabels).count == reasons.count)
        #expect(Set(explanations).count == reasons.count)
        // The explanation is the long form — always longer than the chip.
        #expect(zip(shortLabels, explanations).allSatisfy { $1.count > $0.count })
        // An unknown reason never borrows the algorithm-change wording.
        #expect(explanations.last != explanations.first)
    }

    /// No raw server token ever reaches the screen — not for the eight known
    /// pillars, and not for a ninth the server might add later.
    @Test("pillar labels are localized, never raw wire tokens")
    func pillarLabelsAreLocalized() {
        for pillar in HealthScorePillar.known {
            let label = HealthScorePresentation.label(for: pillar)
            #expect(!label.isEmpty)
            #expect(label != pillar.rawValue)
        }
        let unknown = HealthScorePresentation.label(for: HealthScorePillar.unknown("IMMUNITY"))
        #expect(!unknown.isEmpty)
        #expect(unknown != "IMMUNITY")
    }

    @Test("confidence bands are localized, never raw wire tokens")
    func confidenceLabelsAreLocalized() {
        let bands: [HealthScoreConfidenceBand] = [.high, .medium, .low, .draft, .unknown("provisional")]
        let labels = bands.map(HealthScorePresentation.label(for:))
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == bands.count)
        #expect(labels.last != "provisional")
    }

    // MARK: - Detail-sheet sections

    @Test("a full score earns all four explanatory sections, in order")
    func fullScoreEarnsEverySection() {
        let subject = score(
            delta: nil,
            reason: .algorithmChanged,
            confidence: HealthScoreConfidence(score: 82, band: .medium),
            composition: [.bloodPressure, .activity, .sleep],
            restMode: RestModeAnnotation(active: true, since: nil, episodeCount: 1)
        )
        #expect(HealthScorePresentation.sections(for: subject) == [
            .deltaReason, .composition, .confidence, .restMode
        ])
    }

    /// The acceptance criterion, stated directly: composition + confidence show
    /// whenever the server sent them.
    @Test("composition and confidence appear whenever the server sent them")
    func compositionAndConfidenceAppear() {
        let subject = score(
            delta: 2,
            reason: nil,
            confidence: HealthScoreConfidence(score: 90, band: .high),
            composition: [.bloodPressure, .glycaemia]
        )
        let sections = HealthScorePresentation.sections(for: subject)
        #expect(sections.contains(.composition))
        #expect(sections.contains(.confidence))
        // No withheld delta → no reason card.
        #expect(sections.contains(.deltaReason) == false)
    }

    @Test("a minimal score earns no explanatory section — nothing is invented")
    func minimalScoreEarnsNothing() {
        #expect(HealthScorePresentation.sections(for: score(delta: 3, reason: nil)).isEmpty)
    }

    @Test("an empty composition array does not produce an empty card")
    func emptyCompositionIsNotACard() {
        let subject = score(delta: 3, reason: nil, composition: [])
        #expect(HealthScorePresentation.sections(for: subject).contains(.composition) == false)
    }

    /// Rest mode is an explanation of the window, not a verdict — and the
    /// server only ever sends it active, so an `active: false` relic must not
    /// raise a card.
    @Test("rest mode only earns a card when the server says it is active")
    func restModeCardNeedsAnActiveEpisode() throws {
        let inactive = score(
            delta: 1, reason: nil,
            restMode: RestModeAnnotation(active: false, since: nil, episodeCount: 0)
        )
        #expect(HealthScorePresentation.sections(for: inactive).contains(.restMode) == false)

        let active = score(
            delta: 1, reason: nil,
            restMode: RestModeAnnotation(active: true, since: Date(timeIntervalSince1970: 1_753_344_000), episodeCount: 2)
        )
        #expect(HealthScorePresentation.sections(for: active).contains(.restMode))
        let annotation = try #require(active.activeRestMode)
        #expect(!HealthScorePresentation.restModeLine(for: annotation).isEmpty)
    }

    @Test("the band setter is named, not judged")
    func bandSetterLineNamesThePillar() {
        let line = HealthScorePresentation.bandSetterLine(for: .sleep)
        #expect(line.contains(HealthScorePresentation.label(for: .sleep)))
        #expect(!line.contains("SLEEP"))
    }
}
