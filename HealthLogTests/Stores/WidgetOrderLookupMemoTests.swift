import Foundation
@testable import HealthLog
import Testing

/// **W-B187 — the memoized dashboard ordering lookup.**
///
/// `DashboardScreen.orderedMetrics(_:)` used to rebuild TWO
/// `Dictionary(uniqueKeysWithValues:)` on every body eval; since the dashboard
/// observes ~11 stores, any unrelated store churn re-ran the build. The two
/// dictionaries depend ONLY on `layout.widgets`, so they're now derived once into
/// `WidgetOrderLookup` and memoized on `DashboardLayoutStore.widgetOrderLookup`,
/// recomputed only when the layout actually changes.
///
/// These tests pin the pure projection (correct + stable for unchanged input) and
/// the store-level cache (same instance returned while the layout is unchanged,
/// fresh value after a mutation).
@Suite("Widget-order lookup memoization (W-B187)")
struct WidgetOrderLookupMemoTests {
    // MARK: - Pure projection

    @Test("lookup maps each widget id to its order and effective visibility")
    func projectionMapsOrderAndVisibility() {
        let widgets = [
            DashboardWidgetConfig(id: "a", visible: true, tileVisible: true, order: 2),
            DashboardWidgetConfig(id: "b", visible: true, tileVisible: false, order: 0),
            // `tileVisible == nil` → effective falls back to `visible`.
            DashboardWidgetConfig(id: "c", visible: false, tileVisible: nil, order: 1)
        ]
        let lookup = WidgetOrderLookup(widgets: widgets)

        #expect(lookup.orderById["a"] == 2)
        #expect(lookup.orderById["b"] == 0)
        #expect(lookup.orderById["c"] == 1)

        #expect(lookup.visibilityById["a"] == true)
        #expect(lookup.visibilityById["b"] == false)
        // c: tileVisible nil → effectiveTileVisible == visible == false
        #expect(lookup.visibilityById["c"] == false)
    }

    @Test("identical widgets produce equal lookups (cache-key equality holds)")
    func equalInputsProduceEqualLookups() {
        let widgets = DashboardWidgetLayout.default.widgets
        #expect(WidgetOrderLookup(widgets: widgets) == WidgetOrderLookup(widgets: widgets))
    }

    @Test("a different layout produces a different lookup")
    func differentInputsProduceDifferentLookups() {
        let base = WidgetOrderLookup(widgets: DashboardWidgetLayout.default.widgets)
        let reordered = WidgetOrderLookup(
            widgets: DashboardWidgetLayout.default.reordering(["bp", "weight"]).widgets
        )
        #expect(base != reordered)
    }

    // MARK: - Store-level memoization

    @MainActor
    private func makeStore() -> DashboardLayoutStore {
        let api = DashboardLayoutStoreTests.LayoutStubAPI(initial: .default)
        return DashboardLayoutStore(repo: DashboardRepository(api: api), swr: nil)
    }

    @Test("store returns an EQUAL lookup on repeated reads while the layout is unchanged")
    @MainActor
    func cacheStableWhileLayoutUnchanged() {
        let store = makeStore()
        let first = store.widgetOrderLookup
        let second = store.widgetOrderLookup
        // Same derived value — no recompute drift between reads.
        #expect(first == second)
        // And it actually reflects the current (default) layout.
        #expect(first == WidgetOrderLookup(widgets: store.layout.widgets))
    }

    @Test("store recomputes the lookup after the layout mutates")
    @MainActor
    func cacheRecomputesAfterLayoutChange() async {
        let store = makeStore()
        let before = store.widgetOrderLookup

        // Mutate the layout via a reorder (optimistic write; echoed by the stub).
        await store.reorder(["bp", "weight"])

        let after = store.widgetOrderLookup
        // The cache invalidated: the new lookup reflects the reordered layout.
        #expect(after == WidgetOrderLookup(widgets: store.layout.widgets))
        #expect(after != before)
    }
}
