import Foundation
@testable import HealthLog
import Testing

/// **v0.14.11 (Task B)** — the CYCLE ring tile gate in the "Deine
/// Gesundheitswerte" grid (`InsightsScoreCardsBlock.showsCycleTile`): the tile is
/// shown ONLY when cycle tracking is available AND the cycle surface isn't
/// disabled; hidden for men / opt-in-off users (`isAvailable == false`) and for a
/// 403-`cycle.disabled` surface. Exercised off the main actor (no SwiftUI host) —
/// the pure `nonisolated static` helper the live `cycleTileAvailable` feeds.
@Suite("Score-tile cycle gate")
struct ScoreTileCycleGateTests {
    @Test("cycle tile HIDDEN when not available (men / opt-in-off)")
    func hiddenWhenUnavailable() {
        #expect(InsightsScoreCardsBlock.showsCycleTile(isAvailable: false, isDisabled: false) == false)
        #expect(InsightsScoreCardsBlock.showsCycleTile(isAvailable: false, isDisabled: true) == false)
    }

    @Test("cycle tile SHOWN when available and not disabled")
    func shownWhenAvailable() {
        #expect(InsightsScoreCardsBlock.showsCycleTile(isAvailable: true, isDisabled: false) == true)
    }

    @Test("cycle tile HIDDEN when available but surface disabled (403 cycle.disabled)")
    func hiddenWhenDisabled() {
        #expect(InsightsScoreCardsBlock.showsCycleTile(isAvailable: true, isDisabled: true) == false)
    }
}
