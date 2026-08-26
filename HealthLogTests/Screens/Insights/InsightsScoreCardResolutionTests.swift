import Foundation
@testable import HealthLog
import Testing

/// **Parity Build 4 · 4.3 — the ring selection maps to the rendered cards.**
///
/// `selectedScoreRings` is persisted server-side, but its only renderer (the
/// dashboard hero) had been unmounted, so the setting changed nothing the user
/// could see. It now drives the Insights ring cards too.
///
/// The web deliberately STOPPED rendering these rings in v1.29.1 and kept the
/// contract specifically to feed iOS — `today-hero.tsx:18-21` says so verbatim
/// ("the score-ring SELECTION contract stays server-side … still feeds iOS; the
/// web hero simply stops rendering it"). So iOS rendering them is a documented,
/// intentional divergence, not drift.
///
/// These tests also pin the duplication fix: every card id has exactly ONE
/// owner. Ids inside ``ScoreRingID`` belong to the server selection (visible to
/// web); the rest belong to the device-local hidden-set, which the server models
/// no row for.
@Suite("Insights score-card resolution")
struct InsightsScoreCardResolutionTests {
    private let catalogue = InsightsScoreCardsBlock.hideableCardOrder

    // MARK: - Ownership split

    @Test("exactly the three shared ids are governed by the ring selection")
    func governedIDs() {
        let governed = InsightsScoreCardResolution.selectionGovernedIDs(catalogue: catalogue)
        #expect(governed == ["READINESS", "SLEEP_SCORE", "RECOVERY_SCORE"])
        // MED_COMPLIANCE is selectable on the hero but has no Insights card, so
        // it must not leak into the Insights catalogue.
        #expect(!governed.contains("MED_COMPLIANCE"))
    }

    @Test("the locally-owned ids are disjoint from the selection-owned ids")
    func ownersAreDisjoint() {
        let governed = InsightsScoreCardResolution.selectionGovernedIDs(catalogue: catalogue)
        let local = catalogue.filter { !governed.contains($0) }
        #expect(Set(local) == ["STRAIN_SCORE", "STRESS_SCORE", "FITNESS_AGE", "VASCULAR_AGE_DELTA", "HRV_BALANCE"])
        #expect(Set(local).isDisjoint(with: governed))
        #expect(Set(local).union(governed) == Set(catalogue))
    }

    // MARK: - No explicit selection (the non-regression guard)

    @Test("with no explicit selection the local hidden-set governs everything")
    func noSelectionKeepsPriorBehaviour() {
        // Load-bearing: the SERVER default selection is [MED_COMPLIANCE], which
        // has no Insights card. Letting that default drive the grid would blank
        // Daily condition / Sleep / Recovery for every account that never opened
        // the picker — a regression dressed up as a feature.
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: nil,
            hidden: []
        )
        #expect(ids == catalogue)
    }

    @Test("with no explicit selection a locally hidden card is dropped")
    func noSelectionHonoursHiddenSet() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: nil,
            hidden: ["READINESS", "FITNESS_AGE"]
        )
        #expect(!ids.contains("READINESS"))
        #expect(!ids.contains("FITNESS_AGE"))
        #expect(ids.contains("SLEEP_SCORE"))
    }

    // MARK: - Explicit selection drives the cards

    @Test("selected rings render, in selection order, ahead of the rest")
    func selectionOrdersTheCards() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: [.sleepScore, .readiness],
            hidden: []
        )
        #expect(Array(ids.prefix(2)) == ["SLEEP_SCORE", "READINESS"])
        // The locally-owned cards follow, in catalogue order.
        #expect(Array(ids.dropFirst(2)) == ["STRAIN_SCORE", "STRESS_SCORE", "FITNESS_AGE", "VASCULAR_AGE_DELTA", "HRV_BALANCE"])
    }

    @Test("a shared id left out of the selection does not render")
    func unselectedSharedIdIsDropped() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: [.readiness],
            hidden: []
        )
        #expect(ids.contains("READINESS"))
        #expect(!ids.contains("SLEEP_SCORE"))
        #expect(!ids.contains("RECOVERY_SCORE"))
    }

    @Test("the hidden-set cannot override the selection for a shared id")
    func hiddenSetDoesNotFightTheSelection() {
        // The duplication this build removes: before, a card could be "selected"
        // on the server AND "hidden" locally with no defined winner. Now the
        // selection wins outright for the ids it owns.
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: [.readiness],
            hidden: ["READINESS"]
        )
        #expect(ids.first == "READINESS")
    }

    @Test("MED_COMPLIANCE in the selection adds no Insights card")
    func medComplianceHasNoInsightsCard() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: [.medCompliance, .readiness],
            hidden: []
        )
        #expect(!ids.contains("MED_COMPLIANCE"))
        #expect(ids.first == "READINESS")
    }

    @Test("the hidden-set still governs the cards the server models no row for")
    func hiddenSetStillOwnsTheRest() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: [.readiness],
            hidden: ["HRV_BALANCE"]
        )
        #expect(!ids.contains("HRV_BALANCE"))
        #expect(ids.contains("STRESS_SCORE"))
    }

    @Test("resolution never invents an id outside the catalogue")
    func resolutionIsClosed() {
        let ids = InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: catalogue,
            selection: ScoreRingID.allCases,
            hidden: []
        )
        #expect(Set(ids).isSubset(of: Set(catalogue)))
        #expect(Set(ids).count == ids.count)
    }
}
