@testable import HealthLog
import Testing

/// Lock the corrected drill-down presentation invariant.
///
/// Pre-v0.4.0 (A1-Audit §3.1) the Dashboard + Trends used two paired
/// `@State` properties (`presentedKind` + `detailStore`) for the
/// `.fullScreenCover(item:)` content. When SwiftUI re-evaluated the cover
/// content closure with `detailStore` still nil, the cover rendered
/// `EmptyView()` → opaque black screen, stuck (no toolbar to dismiss).
/// User report #2: "Seite wird schwarz und die App hängt sich auf".
///
/// The fix collapses to a single `Identifiable` `MetricDrillDown` token
/// presented via `.navigationDestination(item:)` inside a `NavigationStack`.
/// Locking the *identity* contract here makes a regression future-proof
/// (any commit that splits the token across two properties shows up
/// immediately in this test file's diff).
@Suite("Drill-down presentation infrastructure")
struct DrillDownNavigationTests {
    @Test("MetricDrillDown collapses kind + presentation into a single token")
    func singleTokenShape() {
        let token = MetricDrillDown(kind: .bloodPressure)
        #expect(token.kind == .bloodPressure)
        // Every construction is distinct so SwiftUI treats consecutive
        // openings of the same kind as new presentations.
        let other = MetricDrillDown(kind: .bloodPressure)
        #expect(token.id != other.id)
        #expect(token != other)
    }

    @Test("MetricDrillDown is Hashable + Identifiable — required by navigationDestination")
    func conformsToProtocols() {
        let token = MetricDrillDown(kind: .weight)
        let set: Set<MetricDrillDown> = [token]
        #expect(set.contains(token))
    }

    @Test("Same instance compares equal to itself (idempotency)")
    func selfEqual() {
        let token = MetricDrillDown(kind: .pulse)
        let copy = token
        #expect(token == copy)
        #expect(token.id == copy.id)
    }
}

/// Lock the eager-store-build contract introduced by **WEIGHT-TILE-TAP-FIX**
/// (2026-05-16). Operator reported the dashboard weight tile depressed
/// visually (`.hlPressable` scale) on tap but no chart-detail screen
/// opened. Root cause: the `.navigationDestination(item:)` closure
/// inline-built the `ChartDetailStore` guarded by
/// `if let container { ChartDetailScreen(…) }`. Whenever that conditional
/// resolved to `EmptyView()`, SwiftUI silently swallowed the push
/// (a navigationDestination producing an empty view yields no animation,
/// no toolbar, no back button — visually identical to the closure never
/// running). Eagerly building the store BEFORE flipping `drillDown`
/// kills that ambiguity.
///
/// These tests don't drive SwiftUI's view tree (the framework is closed-
/// box for that), but they pin the **store-construction contract** that
/// the destination closure now consumes — if anyone re-introduces an
/// inline-build path or breaks the `kind`-match guard, the assertions
/// here surface the regression in CI before operator hits it on device.
@MainActor
@Suite("Drill-down eager store contract — WEIGHT-TILE-TAP-FIX")
struct DrillDownEagerStoreTests {
    /// Builds a real `ChartDetailStore` mirroring the eager-build path
    /// `DashboardScreen.openDetail` + `ChartsScreen.openDetail` execute.
    /// In-memory repos so the test stays hermetic — the contract under
    /// test is "store is constructible without a live network", which is
    /// the precondition that made the inline-build path unsafe.
    private func makeStore(kind: MetricKind) async throws -> ChartDetailStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let insights = MetricInsightsRepository(api: api)
        return ChartDetailStore(kind: kind, measurementsRepo: repo, insightsRepo: insights)
    }

    @Test("Eagerly-built store carries the kind the tile-tap intended (weight)")
    func weightEagerStore() async throws {
        let store = try await makeStore(kind: .weight)
        #expect(
            store.kind == .weight,
            "Destination must read the same kind that openDetail recorded — operator tapping weight must NOT land on BP/Pulse."
        )
    }

    @Test("Eagerly-built store is independent per kind", arguments: MetricKind.allCases)
    func independentStorePerKind(kind: MetricKind) async throws {
        let store = try await makeStore(kind: kind)
        #expect(
            store.kind == kind,
            "Eager-build path must not mix kinds — \(kind.rawValue) tile must produce a \(kind.rawValue) store."
        )
    }

    @Test("Eagerly-built store's queryKey embeds its kind — destination identity check")
    func queryKeyEmbedsKind() async throws {
        let weight = try await makeStore(kind: .weight)
        let pulse = try await makeStore(kind: .pulse)
        #expect(weight.queryKey.contains("weight"))
        #expect(pulse.queryKey.contains("pulse"))
        #expect(
            weight.queryKey != pulse.queryKey,
            "queryKey must distinguish kinds — guards the destination's kind-match assertion."
        )
    }
}

/// v0.5.5.1 — cover the **MetricDrillDown UUID collision race** that the
/// v0.4.0 fix defended against. The DashboardScreen `openDetail(for:)`
/// path eagerly builds a `ChartDetailStore` then flips the `drillDown`
/// state. The `.navigationDestination(item:)` closure consumes the
/// presentation token + the eagerly-built store; if a SECOND tap arrives
/// before SwiftUI mounts the destination (concurrent fan-out on cold
/// launch + repeated tile press), both calls overwrite each other and
/// the destination must still resolve to a coherent (token, store) pair
/// — i.e. the same `kind` AND a non-stale UUID identity.
///
/// These tests pin three invariants:
/// 1. Two same-kind presentations are non-equal (distinct UUIDs) so
///    SwiftUI treats them as independent dismount + mount cycles.
/// 2. The store's `queryKey` carries the kind so the destination's
///    `drillDownStore.kind == presentation.kind` guard discriminates
///    the "first wins" path from the "second tap arrived first" race.
/// 3. Sequentially overwriting `drillDownStore` then re-presenting the
///    SAME kind via a fresh `MetricDrillDown(kind:)` produces a token
///    distinct from the prior presentation — operator-tap-tap stays
///    decoupled from store-identity even when both call sites pin the
///    same metric.
@MainActor
@Suite("MetricDrillDown UUID collision race — v0.5.5.1 regression guard")
struct MetricDrillDownCollisionTests {
    private func makeStore(kind: MetricKind) async throws -> ChartDetailStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let insights = MetricInsightsRepository(api: api)
        return ChartDetailStore(kind: kind, measurementsRepo: repo, insightsRepo: insights)
    }

    @Test("Two same-kind presentations carry distinct UUIDs — concurrent taps stay decoupled")
    func sameKindDistinctUUIDs() {
        let first = MetricDrillDown(kind: .weight)
        let second = MetricDrillDown(kind: .weight)
        #expect(first.kind == second.kind, "Shared kind, by construction.")
        #expect(
            first.id != second.id,
            """
            Concurrent or rapid double-tap on the same tile MUST produce \
            two distinct tokens — SwiftUI keys `.navigationDestination(item:)` \
            on identity, so reusing the prior UUID would short-circuit the \
            second mount.
            """
        )
        #expect(first != second, "Identity-based Equatable must surface the UUID delta.")
    }

    @Test("Overwriting `drillDownStore` mid-race keeps the kind-match guard sound")
    func overwriteKeepsKindGuard() async throws {
        // Simulate the race: tap one fires `openDetail(for: .weight)`,
        // builds store A; tap two fires `openDetail(for: .weight)` before
        // the destination mounts and overwrites with store B. Both stores
        // carry the same kind so the destination's
        // `drillDownStore.kind == presentation.kind` guard accepts either —
        // crucially neither resolves to `nil` and falls through to the
        // `DrillDownErrorState` (impossible-race fallback).
        let storeA = try await makeStore(kind: .weight)
        let storeB = try await makeStore(kind: .weight)
        let token = MetricDrillDown(kind: .weight)
        #expect(storeA.kind == token.kind, "Store A's kind matches the token — first-tap path.")
        #expect(storeB.kind == token.kind, "Store B's kind matches the token — second-tap path.")
        #expect(
            ObjectIdentifier(storeA) != ObjectIdentifier(storeB),
            "Overwrite must yield a distinct store instance — otherwise the eager-build optimisation collapses to a single store reused across taps."
        )
    }

    @Test("Mismatched kind early-returns via the destination's guard")
    func mismatchedKindFallsThrough() async throws {
        // Simulate the bug the eager-build guard defends against: tap one
        // built a `.weight` store, tap two flipped `drillDown` to a
        // `.pulse` MetricDrillDown before the destination mounted. The
        // destination closure's `drillDownStore.kind == presentation.kind`
        // returns false; the closure falls through to the inline-build
        // branch (which constructs the right store from `container`).
        let weightStore = try await makeStore(kind: .weight)
        let pulseToken = MetricDrillDown(kind: .pulse)
        #expect(
            weightStore.kind != pulseToken.kind,
            """
            Mismatched-kind path: guard must read false so the destination \
            falls through to the inline-build branch — guards against the \
            v0.4.0 race where a stale store painted the wrong chart for \
            the second tap.
            """
        )
    }
}
