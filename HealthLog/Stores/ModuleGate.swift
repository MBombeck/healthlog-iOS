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

    /// **Audit A-7 — why each module is (not) available** (`moduleAccess`,
    /// server v1.38.15). `nil` until the first `/api/auth/me` load resolves it,
    /// AND on every server older than v1.38.15, which omits the field. `nil`
    /// means "no reason known" — every surface then behaves exactly as it did
    /// before A-7. The booleans in ``modules`` remain the gate; this map only
    /// explains them.
    public private(set) var moduleAccess: [String: ModuleAccessState]?

    private let repo: ModuleGateRepository?

    public init(
        repo: ModuleGateRepository? = nil,
        modules: [String: Bool]? = nil,
        moduleAccess: [String: ModuleAccessState]? = nil
    ) {
        self.repo = repo
        self.modules = modules
        self.moduleAccess = moduleAccess
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

    /// **Audit A-7 — the server's verdict on this module, if it sent one.**
    ///
    /// `nil` when the server is older than v1.38.15, when the map has not
    /// loaded yet, or when this key is simply not in the map. `nil` is not a
    /// state — it is the absence of one, and every caller must fall back to
    /// today's behaviour on it.
    public func accessState(_ key: ModuleKey) -> ModuleAccessState? {
        accessState(wireKey: key.wireKey)
    }

    /// **Audit A-7** — string-key overload for call sites holding a raw wire
    /// key (the 403 `meta.module` mirror, a future module with no `ModuleKey`).
    public func accessState(wireKey: String) -> ModuleAccessState? {
        moduleAccess?[wireKey]
    }

    /// **Audit A-7 (fix round 1) — the server's verdict, but only where the two
    /// halves agree.**
    ///
    /// This is the accessor every SURFACE reads. ``accessState(_:)`` is the raw
    /// map and stays that way (a diagnostic, and what the invariant test asserts
    /// against); this one applies the fallback. `nil` when the server sent no
    /// map, when the key is absent from it — and when `modules[key]` and
    /// `moduleAccess[key]` disagree. The server's invariant is
    /// `modules[key] == (moduleAccess[key] == "enabled")`; if it is ever
    /// violated the boolean wins (it is the half every gate has obeyed since
    /// #30) and the disagreement is logged once. Saying nothing is bad; saying
    /// the wrong thing is worse.
    ///
    /// The disagreement is REACHABLE, which is why this is an accessor and not a
    /// clause inside ``offReason(_:)``: ``setEnabled(_:enabled:)`` replaces
    /// `modules` wholesale from the PATCH echo, so a sibling key whose boolean
    /// moved server-side in that round-trip briefly carries a stale reason. The
    /// switchboard turns a reason into a LOCKED SWITCH, so it needs the same
    /// guard the reason sentence has always had.
    public func reconciledAccessState(_ key: ModuleKey) -> ModuleAccessState? {
        guard let state = accessState(key) else { return nil }
        let on = isEnabled(key)
        guard on == state.impliesEnabled else {
            ModuleAccessDisagreementLog.note(wireKey: key.wireKey, enabled: on, state: state)
            return nil
        }
        return state
    }

    /// **Audit A-7 — the localized sentence saying why this module is off**, or
    /// `nil` when there is nothing honest to say.
    ///
    /// `nil` when the module is on, when the server sent no `moduleAccess` map,
    /// when this key is absent from it — and when the two halves disagree
    /// (see ``reconciledAccessState(_:)``, which is where that rule now lives).
    public func offReason(_ key: ModuleKey) -> String? {
        reconciledAccessState(key)?.offReason
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
    ///
    /// **Audit A-7** — the access map travels with the booleans it explains, so a
    /// caller can never leave a stale reason attached to a fresh map.
    public func apply(modules: [String: Bool]?, moduleAccess: [String: ModuleAccessState]? = nil) {
        self.modules = modules
        self.moduleAccess = moduleAccess
    }

    /// Mirror a single disabled-module signal from a `403 +
    /// errorCode: "module.disabled"` response (server brief #30). Flips the
    /// matching key OFF on the same tick the route 403's, so the surface
    /// disappears without waiting on the next `/api/auth/me` refresh. Mirrors
    /// the assistant-disabled convenience hop (F-1).
    ///
    /// **Audit A-7** — the 403 envelope carries no `moduleAccess` state, so the
    /// key's stale entry is DROPPED rather than guessed at. Until the next
    /// `/api/auth/me` refresh the surface behaves exactly as it did before A-7
    /// (hidden, unexplained); an invented "you switched this off" next to an
    /// operator's instance-wide off would be worse than the silence.
    public func applyDisabled(wireKey: String) {
        var next = modules ?? [:]
        next[wireKey] = false
        modules = next
        moduleAccess?[wireKey] = nil
    }

    /// **Build 9 (9.2)** — optimistically mirror a single module's availability
    /// after a local toggle (the disable-coach switch). Local-only: the server
    /// write already happened on the owning route, and the resolved `/me` map
    /// already ANDs the flag; this flips the key on the same tick so the coach
    /// surfaces appear/disappear without waiting on the next refresh. The
    /// symmetric sibling of ``applyDisabled(wireKey:)`` (which only sets `false`).
    ///
    /// **Audit A-7** — this IS the person's own switch, so the access map is
    /// mirrored along with the boolean: `enabled` / `disabled`, the only two
    /// states a local toggle can produce. The invariant therefore survives the
    /// optimistic tick, and the switchboard row keeps offering its toggle.
    public func applyModuleOptimistic(wireKey: String, enabled: Bool) {
        var next = modules ?? [:]
        next[wireKey] = enabled
        modules = next
        if moduleAccess != nil {
            moduleAccess?[wireKey] = enabled ? .enabled : .disabled
        }
    }

    /// Load the module map from `GET /api/auth/me`. Failures are swallowed —
    /// the gate fails *open* (all modules on) so a transient network blip never
    /// hides a valid surface. The server is the final gate (403 on a disabled
    /// route).
    ///
    /// **Audit A-7** — reads the booleans and their `moduleAccess` reasons in
    /// the same hop, because `GET /api/auth/me` carries both.
    public func load() async {
        guard let repo else { return }
        if let resolved = try? await repo.fetchModuleGateState() {
            modules = resolved.modules
            moduleAccess = resolved.moduleAccess
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
        let previousAccess = moduleAccess
        // Audit A-7 — mirrors the boolean AND the reason (this is the person's
        // own switch, so `.enabled` / `.disabled` is the whole vocabulary).
        applyModuleOptimistic(wireKey: key.wireKey, enabled: enabled)
        do {
            // Per-key body — exactly the one key the user toggled.
            let confirmed = try await repo.updateModules(changes: [key.wireKey: enabled])
            modules = confirmed
            // **Audit A-7 (fix round 1) — the echo replaces every boolean, so it
            // can invalidate a SIBLING key's reason.** The optimistic mirror
            // above only touches the toggled key; a sibling whose boolean moved
            // server-side between the two hops would otherwise keep an access
            // entry that now contradicts it. Dropping the entry means "no reason
            // known", which is the honest state until the next `/api/auth/me`
            // load — not a guess in either direction.
            dropAccessEntriesContradicting(confirmed)
            return true
        } catch {
            modules = previous
            moduleAccess = previousAccess
            return false
        }
    }

    /// Audit A-7 (fix round 1) — forget every `moduleAccess` entry whose reason
    /// no longer matches the given boolean map. Keys absent from the map are
    /// left alone: absent means default-on and the server simply did not mention
    /// them, which is not the same as a contradiction.
    private func dropAccessEntriesContradicting(_ booleans: [String: Bool]) {
        guard var access = moduleAccess else { return }
        var changed = false
        for (wireKey, state) in access {
            guard let on = booleans[wireKey], on != state.impliesEnabled else { continue }
            ModuleAccessDisagreementLog.note(wireKey: wireKey, enabled: on, state: state)
            access[wireKey] = nil
            changed = true
        }
        if changed { moduleAccess = access }
    }

    /// Reset on logout — next user re-loads their own map; until then default
    /// to "all on" so no surface is wrongly hidden by a stale map.
    public func clearOnLogout() {
        modules = nil
        moduleAccess = nil
    }
}
