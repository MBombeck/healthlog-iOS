import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **Parity Build 4 · 4.5 — the `sections` slice.**
///
/// Before this build `InsightsLayoutStore` had no `sections` concept at all, so
/// overview section show/hide + reorder — a shipped web surface since v1.15.11 —
/// was completely unreachable from iOS (`12-layout-dashboard-insights-domains.md`
/// §A, the cluster's only P0). These tests pin the round-trip the store's
/// optimistic write-through relies on: a reorder survives, a hide survives, the
/// catalogue matches the server's, and the verbatim-echo contract that lets an
/// unknown future section id survive a PUT is not broken by any of it.
@Suite("InsightsLayout sections slice")
struct InsightsLayoutSectionsTests {
    private func layout(sections: [InsightsLayoutSection]?) -> InsightsLayout {
        InsightsLayout(
            version: 2,
            sections: sections,
            tiles: [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
        )
    }

    // MARK: - Catalogue

    @Test("the catalogue mirrors the server INSIGHTS_SECTION_IDS, in order")
    func catalogueMatchesServer() {
        // Pinned literally: a drift here silently desyncs the two editors — the
        // phone would offer a row the server drops, or hide one it renders.
        #expect(InsightsLayoutSectionId.allInDefaultOrder == [
            "wellness-scores", "daily-briefing", "vitals", "trends", "period-review",
            "cycle-summary", "signals", "rhythm-events", "health-status", "breathing",
            "labs-changes", "ecg"
        ])
    }

    @Test("the ECG row rides the same sections array")
    func ecgIsASection() {
        // 4.5 explicitly folds the ECG row into `sections` rather than giving it
        // a bespoke flag — iOS has no ECG screen yet, but the row still governs
        // the web block and must be editable from the phone.
        #expect(InsightsLayoutSectionId.known.contains(InsightsLayoutSectionId.ecg))
        #expect(layout(sections: nil).visibleSectionIds.contains(InsightsLayoutSectionId.ecg))
    }

    // MARK: - Resolution

    @Test("a layout with no sections resolves to the full default set, all visible")
    func nilResolvesToDefaults() {
        let resolved = layout(sections: nil).resolvedSections
        #expect(resolved.map(\.id) == InsightsLayoutSectionId.allInDefaultOrder)
        // Bound OUTSIDE the macro on purpose. `#expect` expands to
        // `$0.allSatisfy($1)`, where the compiler cannot rule out
        // `allSatisfy`'s `rethrows` overload and demands a `try` the
        // expectation cannot carry. Rewriting the argument does not help —
        // swiftformat's `preferKeyPath` turns a closure straight back into
        // `\.visible`. Binding first sidesteps the expansion entirely.
        let allVisible = resolved.allSatisfy(\.visible)
        #expect(allVisible)
        #expect(resolved.map(\.order) == Array(0 ..< InsightsLayoutSectionId.allInDefaultOrder.count))
    }

    @Test("a partial stored list keeps its order and appends the missing catalogue ids")
    func partialListIsMerged() {
        let stored = [
            InsightsLayoutSection(id: InsightsLayoutSectionId.trends, visible: true, order: 0),
            InsightsLayoutSection(id: InsightsLayoutSectionId.vitals, visible: false, order: 1)
        ]
        let resolved = layout(sections: stored).resolvedSections
        #expect(resolved.first?.id == InsightsLayoutSectionId.trends)
        #expect(resolved[1].id == InsightsLayoutSectionId.vitals)
        #expect(resolved[1].visible == false)
        #expect(resolved.count == InsightsLayoutSectionId.allInDefaultOrder.count)
        #expect(Set(resolved.map(\.id)) == InsightsLayoutSectionId.known)
    }

    @Test("an unknown section id is dropped from the RESOLVED view but kept in storage")
    func unknownIdIsEchoedNotResolved() {
        let stored = [
            InsightsLayoutSection(id: "a-future-server-section", visible: true, order: 0),
            InsightsLayoutSection(id: InsightsLayoutSectionId.trends, visible: true, order: 1)
        ]
        let value = layout(sections: stored)
        #expect(!value.resolvedSections.contains { $0.id == "a-future-server-section" })
        // The verbatim echo is the whole reason `sections` is a bare String id:
        // resolution is a READ view and must never rewrite what we hold.
        #expect(value.sections?.contains { $0.id == "a-future-server-section" } == true)
        #expect(value.reconciled().sections == stored)
    }

    // MARK: - Reorder

    @Test("reordering sections round-trips through an encode/decode cycle")
    func reorderRoundTrips() throws {
        let moved = layout(sections: nil).reorderingSections([
            InsightsLayoutSectionId.trends,
            InsightsLayoutSectionId.vitals
        ])
        #expect(Array(moved.resolvedSections.map(\.id).prefix(2)) == [
            InsightsLayoutSectionId.trends, InsightsLayoutSectionId.vitals
        ])
        // Unlisted sections keep their relative sequence behind the listed ones.
        #expect(moved.resolvedSections[2].id == InsightsLayoutSectionId.wellnessScores)

        let data = try JSONEncoder.hlDefault.encode(moved)
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded.resolvedSections.map(\.id) == moved.resolvedSections.map(\.id))
        #expect(decoded.resolvedSections.map(\.order) == moved.resolvedSections.map(\.order))
    }

    @Test("reordering never drops or duplicates a section")
    func reorderIsTotal() {
        let moved = layout(sections: nil).reorderingSections([InsightsLayoutSectionId.labsChanges])
        let ids = moved.resolvedSections.map(\.id)
        #expect(ids.count == InsightsLayoutSectionId.allInDefaultOrder.count)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Visibility

    @Test("a hidden section round-trips hidden, and leaves visibleSectionIds")
    func hiddenRoundTrips() throws {
        let hidden = layout(sections: nil).togglingSectionVisibility(forId: InsightsLayoutSectionId.vitals)
        #expect(hidden.isSectionVisible(InsightsLayoutSectionId.vitals) == false)
        #expect(!hidden.visibleSectionIds.contains(InsightsLayoutSectionId.vitals))

        let data = try JSONEncoder.hlDefault.encode(hidden)
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded.isSectionVisible(InsightsLayoutSectionId.vitals) == false)
        // Every other section is untouched by a single-row toggle.
        #expect(decoded.visibleSectionIds.count == InsightsLayoutSectionId.allInDefaultOrder.count - 1)
    }

    @Test("hide + reorder compose: the hidden row keeps its flag through a move")
    func hideSurvivesReorder() {
        let value = layout(sections: nil)
            .togglingSectionVisibility(forId: InsightsLayoutSectionId.signals)
            .reorderingSections([InsightsLayoutSectionId.signals, InsightsLayoutSectionId.trends])
        #expect(value.resolvedSections.first?.id == InsightsLayoutSectionId.signals)
        #expect(value.isSectionVisible(InsightsLayoutSectionId.signals) == false)
    }

    @Test("toggling an unknown section id is a no-op")
    func unknownToggleIsNoOp() {
        let value = layout(sections: nil)
        #expect(value.togglingSectionVisibility(forId: "not-a-section") == value)
    }

    @Test("the first toggle on a sections-less layout materialises the full default set")
    func firstToggleMaterialisesDefaults() {
        // A v1 blob / fresh install carries no `sections`. The web editor sends
        // the whole normalised list on its first save; iOS must too, else the
        // server would fill defaults over the single row we meant to change.
        let value = layout(sections: nil).togglingSectionVisibility(forId: InsightsLayoutSectionId.ecg)
        #expect(value.sections?.count == InsightsLayoutSectionId.allInDefaultOrder.count)
        #expect(value.sections?.filter { !$0.visible }.map(\.id) == [InsightsLayoutSectionId.ecg])
    }

    @Test("a sections edit still emits sections through the server filter")
    func sectionsSurviveTheServerFilter() throws {
        // `filteringForServer()` only prunes TILE ids; a sections edit must reach
        // the wire or the whole surface is decorative.
        let edited = layout(sections: nil).togglingSectionVisibility(forId: InsightsLayoutSectionId.trends)
        let json = try String(decoding: JSONEncoder.hlDefault.encode(edited.filteringForServer()), as: UTF8.self)
        #expect(json.contains("\"sections\""))
        #expect(json.contains(InsightsLayoutSectionId.trends))
    }
}
