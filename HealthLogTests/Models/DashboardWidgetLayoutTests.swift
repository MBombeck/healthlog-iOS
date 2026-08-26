import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.2 W1a (A2) — pure reorder math for the server-first dashboard widget
/// layout. The dashboard grid feeds `reordering(_:)` only the VISIBLE,
/// mappable widget ids; the hidden rows must keep their relative sequence in
/// the unmatched tail so the AddTileSheet ordering + future un-hide position
/// stay stable. No network, no store: just the value-type transform the
/// optimistic write path depends on.
@Suite("DashboardWidgetLayout — reorder math (A2 hidden-row preservation)")
struct DashboardWidgetLayoutTests {
    private func config(_ id: String, visible: Bool, order: Int) -> DashboardWidgetConfig {
        DashboardWidgetConfig(id: id, visible: visible, tileVisible: visible, order: order)
    }

    @Test("reordering renumbers order to match the new id sequence")
    func reorderingRenumbers() {
        let start = DashboardWidgetLayout(widgets: [
            config("a", visible: true, order: 0),
            config("b", visible: true, order: 1),
            config("c", visible: true, order: 2)
        ])
        let moved = start.reordering(["c", "a", "b"])
        let ordered = moved.widgets.sorted { $0.order < $1.order }
        #expect(ordered.map(\.id) == ["c", "a", "b"])
        #expect(ordered.map(\.order) == [0, 1, 2])
    }

    @Test("reordering of visible-subset keeps hidden rows' relative sequence")
    func reorderingPreservesHiddenRelativeOrder() {
        // Visible: a, c, e (order 0,2,4). Hidden: b, d (order 1,3).
        let start = DashboardWidgetLayout(widgets: [
            config("a", visible: true, order: 0),
            config("b", visible: false, order: 1),
            config("c", visible: true, order: 2),
            config("d", visible: false, order: 3),
            config("e", visible: true, order: 4)
        ])
        // Operator drags the visible tiles into e, a, c.
        let moved = start.reordering(["e", "a", "c"])
        let ordered = moved.widgets.sorted { $0.order < $1.order }
        // Visible tiles lead; hidden b, d keep ORIGINAL relative sequence.
        #expect(ordered.map(\.id) == ["e", "a", "c", "b", "d"])
        // Hidden tiles stay hidden, visible stay visible.
        let byId = Dictionary(uniqueKeysWithValues: moved.widgets.map { ($0.id, $0.effectiveTileVisible) })
        #expect(byId["b"] == false)
        #expect(byId["d"] == false)
        #expect(byId["e"] == true)
        #expect(ordered.map(\.order) == [0, 1, 2, 3, 4])
    }

    @Test("reordering preserves hidden sequence for an unsorted source array")
    func reorderingHiddenSequenceUnsortedSource() {
        // Array order deliberately scrambled vs `order`.
        let start = DashboardWidgetLayout(widgets: [
            config("d", visible: false, order: 3),
            config("a", visible: true, order: 0),
            config("e", visible: true, order: 4),
            config("b", visible: false, order: 1),
            config("c", visible: true, order: 2)
        ])
        let moved = start.reordering(["c", "a", "e"])
        let ordered = moved.widgets.sorted { $0.order < $1.order }
        // Hidden b (order 1) still precedes hidden d (order 3).
        #expect(ordered.map(\.id) == ["c", "a", "e", "b", "d"])
    }

    @Test("reordering preserves per-widget visible + tileVisible flags")
    func reorderingPreservesFlags() {
        let start = DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: "a", visible: true, tileVisible: false, order: 0),
            DashboardWidgetConfig(id: "b", visible: false, tileVisible: true, order: 1)
        ])
        let moved = start.reordering(["b", "a"])
        let byId = Dictionary(uniqueKeysWithValues: moved.widgets.map { ($0.id, $0) })
        #expect(byId["a"]?.visible == true)
        #expect(byId["a"]?.tileVisible == false)
        #expect(byId["b"]?.visible == false)
        #expect(byId["b"]?.tileVisible == true)
    }

    // MARK: - v0.14 A — pin-to-home (settingTileVisible)

    @Test("pinning a hidden tile shows it and moves it to the tail order")
    func pinningMovesToTail() {
        let start = DashboardWidgetLayout(widgets: [
            config("a", visible: true, order: 0),
            DashboardWidgetConfig(id: "b", visible: false, tileVisible: false, order: 1),
            config("c", visible: true, order: 2)
        ])
        let next = start.settingTileVisible(forId: "b", visible: true, moveToTailWhenShowing: true)
        let b = next.widgets.first { $0.id == "b" }
        #expect(b?.effectiveTileVisible == true)
        // max order was 2 → tail = 3.
        #expect(b?.order == 3)
        // Other rows untouched.
        #expect(next.widgets.first { $0.id == "a" }?.order == 0)
        #expect(next.widgets.first { $0.id == "c" }?.order == 2)
    }

    @Test("unpinning hides the tile but keeps its order")
    func unpinningKeepsOrder() {
        let start = DashboardWidgetLayout(widgets: [
            config("a", visible: true, order: 0),
            config("b", visible: true, order: 5)
        ])
        let next = start.settingTileVisible(forId: "b", visible: false, moveToTailWhenShowing: false)
        let b = next.widgets.first { $0.id == "b" }
        #expect(b?.effectiveTileVisible == false)
        #expect(b?.order == 5)
    }

    @Test("settingTileVisible is a no-op for an unknown id")
    func settingUnknownIdIsNoOp() {
        let start = DashboardWidgetLayout(widgets: [config("a", visible: true, order: 0)])
        let next = start.settingTileVisible(forId: "zzz", visible: true, moveToTailWhenShowing: true)
        #expect(next == start)
    }

    @Test("pinning without move flag leaves order in place")
    func pinningWithoutMoveKeepsOrder() {
        let start = DashboardWidgetLayout(widgets: [
            config("a", visible: true, order: 0),
            DashboardWidgetConfig(id: "b", visible: false, tileVisible: false, order: 1)
        ])
        let next = start.settingTileVisible(forId: "b", visible: true, moveToTailWhenShowing: false)
        let b = next.widgets.first { $0.id == "b" }
        #expect(b?.effectiveTileVisible == true)
        #expect(b?.order == 1)
    }

    // MARK: - Widget-id gating (pinnable ⇔ has a server widget id)

    @Test("core metrics map to a server widget id (pinnable)")
    func coreMetricsArePinnable() {
        #expect(DashboardWidgetId.id(forMetricKind: .weight) == DashboardWidgetId.weight)
        #expect(DashboardWidgetId.id(forMetricKind: .bloodPressure) == DashboardWidgetId.bp)
        #expect(DashboardWidgetId.id(forMetricKind: .pulse) == DashboardWidgetId.pulse)
        #expect(DashboardWidgetId.id(forMetricKind: .bmi) == DashboardWidgetId.bmi)
    }

    @Test("v1.10 additive signals have NO widget id (not pinnable yet)")
    func v110SignalsAreNotPinnable() {
        for kind in [
            MetricKind.falls,
            .sixMinuteWalk,
            .stairAscentSpeed,
            .stairDescentSpeed,
            .breathingDisturbances,
            .cardioRecovery,
            .wristTemperature
        ] {
            #expect(DashboardWidgetId.id(forMetricKind: kind) == nil)
        }
    }
}
