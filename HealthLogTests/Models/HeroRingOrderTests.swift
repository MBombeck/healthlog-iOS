import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **Parity Build 4 · 4.8 — `heroRingOrder` on the wire.**
///
/// iOS could not express the hero ring order at all: the field was absent from
/// the wire model, so the health-score anchor was effectively pinned to the
/// leading edge on the phone while web let the user drag it anywhere
/// (`dashboard-layout-section.tsx:626-663`).
///
/// **This is a capability gap, NOT data loss.** The server preserves the stored
/// value whenever a PUT omits the field
/// (`api/dashboard/widgets/route.ts:286-310`, verbatim: "`selectedScoreRings`
/// and `heroRingOrder` ride the same preserve-when-absent contract"), so every
/// earlier iOS save was safe. An early audit called it a P0 data loss; that was
/// investigated and disproven (`12-layout…md` §F) and is not re-litigated here.
/// What these tests pin is the two halves of the contract: the field is SENT
/// when the user sets it, and OMITTED on every unrelated save.
@Suite("heroRingOrder encode contract")
struct HeroRingOrderTests {
    private func sampleLayout() -> DashboardWidgetLayout {
        DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: DashboardWidgetId.weight, visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: DashboardWidgetId.bp, visible: true, tileVisible: true, order: 1)
        ])
    }

    private func encodeJSON(_ layout: DashboardWidgetLayout) throws -> String {
        try String(decoding: JSONEncoder.hlDefault.encode(layout), as: UTF8.self)
    }

    // MARK: - Omitted when nil

    @Test("a tile reorder OMITS heroRingOrder (preserve-when-absent)")
    func reorderOmitsHeroOrder() throws {
        let reordered = sampleLayout().reordering([DashboardWidgetId.bp, DashboardWidgetId.weight])
        #expect(reordered.heroRingOrder == nil)
        #expect(try !encodeJSON(reordered).contains("heroRingOrder"))
    }

    @Test("a visibility toggle OMITS heroRingOrder")
    func toggleOmitsHeroOrder() throws {
        let toggled = sampleLayout().togglingTileVisibility(forId: DashboardWidgetId.weight)
        #expect(toggled.heroRingOrder == nil)
        #expect(try !encodeJSON(toggled).contains("heroRingOrder"))
    }

    @Test("a selection-only change still OMITS heroRingOrder")
    func selectionOnlyOmitsHeroOrder() throws {
        // The legacy entry point (`setSelectedScoreRings`) must keep behaving
        // exactly as before — it sends the selection and lets the server
        // preserve whatever order is stored.
        let changed = sampleLayout().settingSelectedScoreRings([.readiness, .sleepScore])
        #expect(changed.heroRingOrder == nil)
        let json = try encodeJSON(changed)
        #expect(json.contains("selectedScoreRings"))
        #expect(!json.contains("heroRingOrder"))
    }

    // MARK: - Encoded when set

    @Test("setting the order SENDS heroRingOrder with the anchor in place")
    func orderIsEncodedWhenSet() throws {
        let changed = sampleLayout().settingScoreRings(
            selected: [.readiness, .sleepScore],
            heroOrder: [.readiness, .healthScore, .sleepScore]
        )
        #expect(changed.heroRingOrder == ["READINESS", "HEALTH_SCORE", "SLEEP_SCORE"])
        let json = try encodeJSON(changed)
        #expect(json.contains("heroRingOrder"))
        #expect(json.contains("HEALTH_SCORE"))
    }

    @Test("a deselected ring cannot survive in the order")
    func orderIsReconciledAgainstSelection() {
        let changed = sampleLayout().settingScoreRings(
            selected: [.readiness],
            heroOrder: [.sleepScore, .healthScore, .readiness]
        )
        #expect(changed.heroRingOrder == ["HEALTH_SCORE", "READINESS"])
    }

    @Test("the anchor is always present, even when the caller omits it")
    func anchorIsAlwaysPresent() {
        let changed = sampleLayout().settingScoreRings(
            selected: [.medCompliance],
            heroOrder: [.medCompliance]
        )
        #expect(changed.heroRingOrder == ["MED_COMPLIANCE", "HEALTH_SCORE"])
    }

    @Test("the order is clamped to the server MAX_HERO_RING_ORDER")
    func orderIsClamped() {
        #expect(HeroRingID.maxOrderLength == 4)
        let changed = sampleLayout().settingScoreRings(
            selected: [.readiness, .recovery, .sleepScore, .medCompliance],
            heroOrder: [.healthScore, .readiness, .recovery, .sleepScore, .medCompliance]
        )
        #expect(changed.heroRingOrder?.count == HeroRingID.maxOrderLength)
    }

    // MARK: - Decode + resolve

    @Test("heroRingOrder decodes from a server echo and survives a round-trip")
    func decodeRoundTrips() throws {
        let echo = Data(#"""
        {"version":1,"widgets":[],"selectedScoreRings":["READINESS"],"heroRingOrder":["READINESS","HEALTH_SCORE"]}
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: echo)
        #expect(decoded.heroRingOrder == ["READINESS", "HEALTH_SCORE"])
        #expect(decoded.resolvedHeroRingOrder == [.readiness, .healthScore])
        #expect(try encodeJSON(decoded).contains("heroRingOrder"))
    }

    @Test("an older server that omits heroRingOrder decodes to nil, not a crash")
    func absentFieldDecodesToNil() throws {
        let echo = Data(#"{"version":1,"widgets":[],"selectedScoreRings":["READINESS"]}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: echo)
        #expect(decoded.heroRingOrder == nil)
        // With nothing stored, the resolver still hands the editor a sane
        // starting point: the anchor first, then the selection.
        #expect(decoded.resolvedHeroRingOrder == [.healthScore, .readiness])
    }

    @Test("an unknown ring id in a stored order is dropped, not fatal")
    func unknownIdIsDropped() throws {
        let echo = Data(#"""
        {"version":1,"widgets":[],"selectedScoreRings":["READINESS"],"heroRingOrder":["FUTURE_RING","READINESS"]}
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: echo)
        #expect(decoded.resolvedHeroRingOrder == [.readiness, .healthScore])
    }

    // MARK: - HeroRingID

    @Test("HeroRingID mirrors the server HERO_RING_IDS set")
    func heroRingIDsMirrorServer() {
        #expect(Set(HeroRingID.allCases.map(\.rawValue)) == [
            "HEALTH_SCORE", "READINESS", "RECOVERY_SCORE", "SLEEP_SCORE", "MED_COMPLIANCE"
        ])
        #expect(HeroRingID.healthScore.scoreRing == nil)
        #expect(HeroRingID(.recovery).scoreRing == .recovery)
    }
}
