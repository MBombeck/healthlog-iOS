import Foundation
import Observation

/// **Single source of truth** for whether an optional feature module is offered
/// to the current user (server brief #30, v1.18.0).
///
/// Holds the resolved `modules: { <key>: boolean }` map served by
/// `GET /api/auth/me`. Every module-gated surface reads ``isEnabled(_:)`` from
/// THIS gate — never a scattered local check. ``CycleGate`` consults this gate
/// too (it keeps its gender/opt-in resolution only as a *fallback* for servers
/// that do not yet ship the map).
///
/// **Defensive by design.** The `modules` field is optional on the wire — the
/// server's #30 deploy is "in flight" and prod (v1.17.1) does not emit it yet.
/// A missing map decodes to `nil` here, and ``isEnabled(_:)`` then returns
/// `true` for every key (non-breaking: all modules on). It works today and the
/// moment the server goes live.
///
/// `@MainActor @Observable` so SwiftUI surfaces can read it during `body`
/// evaluation without a hop.
@MainActor
@Observable
public final class ModuleGate {
    /// The resolved per-user module map (`wireKey → enabled`). `nil` until the
    /// first `/api/auth/me` load resolves it, OR when the server omits the
    /// field entirely (older server). Both cases mean "all modules on" —
    /// ``isEnabled(_:)`` defaults to `true`.
    public private(set) var modules: [String: Bool]?

    /// **W-PERF-SWR (High) — memoized dashboard-disabled kinds.**
    /// `DashboardScreen.orderedMetrics(_:)` runs up to 3× per body eval and
    /// previously rebuilt the union of every server-disabled module's
    /// `dashboardMetricKinds` on each call (loop over all `ModuleKey.allCases`
    /// × each key's kind set). That set depends ONLY on `modules`, so it's
    /// cached here and recomputed lazily the first time `modules` changes.
    /// `@ObservationIgnored` keeps the cache off the dependency graph — readers
    /// still observe `modules` (which `dashboardDisabledMetricKinds` reads), so
    /// a toggle still re-evaluates the tile filter.
    @ObservationIgnored private var cachedDisabledKinds: Set<MetricKind>?
    @ObservationIgnored private var cachedDisabledKindsModules: [String: Bool]?

    private let repo: ModuleGateRepository?

    public init(repo: ModuleGateRepository? = nil, modules: [String: Bool]? = nil) {
        self.repo = repo
        self.modules = modules
    }

    /// Whether the given module is enabled for the current user.
    ///
    /// - Core keys are *never* in the map and are always on — but `ModuleKey`
    ///   only models toggleable keys (plus the pre-staged-CORE `medications`,
    ///   which resolves ON until the server starts emitting it).
    /// - Map present, key present → the wire value.
    /// - Map present, key absent → `true` (default-on; #30 / v1.18.3 — illness
    ///   joined the default-on keys when its born-gating was dropped).
    /// - Map absent (older server / not loaded) → `true` (non-breaking).
    public func isEnabled(_ key: ModuleKey) -> Bool {
        guard let modules else { return true }
        return modules[key.wireKey] ?? true
    }

    /// String-key convenience for call sites that hold a raw wire key (e.g. the
    /// 403 `meta.module` mirror). Every key — known or unknown forward-compat —
    /// defaults to `true` when absent (default-on; #30 / v1.18.3).
    public func isEnabled(wireKey: String) -> Bool {
        guard let modules else { return true }
        return modules[wireKey] ?? true
    }

    /// The union of `MetricKind`s owned by every server-DISABLED module, for the
    /// dashboard tile filter. Empty when no module is off (or the map is absent /
    /// not loaded → fails open). Memoized on `modules`: recomputes only when the
    /// map changes, otherwise returns the cached set. Reading `modules` keeps the
    /// `@Observable` dependency so a disable still flips the tile out.
    public func dashboardDisabledMetricKinds() -> Set<MetricKind> {
        let current = modules
        if let cachedDisabledKinds, cachedDisabledKindsModules == current {
            return cachedDisabledKinds
        }
        var disabled: Set<MetricKind> = []
        for key in ModuleKey.allCases where !isEnabled(key) {
            disabled.formUnion(key.dashboardMetricKinds)
        }
        cachedDisabledKinds = disabled
        cachedDisabledKindsModules = current
        return disabled
    }

    /// Replace the in-memory map. Called after a `/api/auth/me` load resolves
    /// the resolved-per-user map. Passing `nil` (server omitted the field)
    /// leaves the "all on" default in effect.
    public func apply(modules: [String: Bool]?) {
        self.modules = modules
    }

    /// Mirror a single disabled-module signal from a `403 +
    /// errorCode: "module.disabled"` response (server brief #30). Flips the
    /// matching key OFF on the same tick the route 403's, so the surface
    /// disappears without waiting on the next `/api/auth/me` refresh. Mirrors
    /// the assistant-disabled convenience hop (F-1).
    public func applyDisabled(wireKey: String) {
        var next = modules ?? [:]
        next[wireKey] = false
        modules = next
    }

    /// **Build 9 (9.2)** — optimistically mirror a single module's availability
    /// after a local toggle (the disable-coach switch). Local-only: the server
    /// write already happened on the owning route, and the resolved `/me` map
    /// already ANDs the flag; this flips the key on the same tick so the coach
    /// surfaces appear/disappear without waiting on the next refresh. The
    /// symmetric sibling of ``applyDisabled(wireKey:)`` (which only sets `false`).
    public func applyModuleOptimistic(wireKey: String, enabled: Bool) {
        var next = modules ?? [:]
        next[wireKey] = enabled
        modules = next
    }

    /// Load the module map from `GET /api/auth/me`. Failures are swallowed —
    /// the gate fails *open* (all modules on) so a transient network blip never
    /// hides a valid surface. The server is the final gate (403 on a disabled
    /// route).
    public func load() async {
        guard let repo else { return }
        if let resolved = try? await repo.fetchModules() {
            modules = resolved
        }
    }

    /// Optimistically flip a single module + revalidate via
    /// `PATCH /api/auth/me/modules`. Returns `true` on success. On failure the
    /// previous map is restored.
    ///
    /// The PATCH carries **only the single toggled key** as a per-key
    /// `{ key: enabled }` body (v1.18.1 §4 Q3); the response echoes the
    /// freshly-resolved map, which we reconcile into local state. Sending a
    /// DELEGATED (cycle/coach) or CORE-pre-staged (medications) key would
    /// `422 modules.invalid`, so those are rejected before any network hop.
    @discardableResult
    public func setEnabled(_ key: ModuleKey, enabled: Bool) async -> Bool {
        guard let repo else { return false }
        guard key.isUserToggleable else { return false }
        let previous = modules
        var next = modules ?? [:]
        next[key.wireKey] = enabled
        modules = next
        do {
            // Per-key body — exactly the one key the user toggled.
            let confirmed = try await repo.updateModules(changes: [key.wireKey: enabled])
            modules = confirmed
            return true
        } catch {
            modules = previous
            return false
        }
    }

    /// Reset on logout — next user re-loads their own map; until then default
    /// to "all on" so no surface is wrongly hidden by a stale map.
    public func clearOnLogout() {
        modules = nil
    }
}
