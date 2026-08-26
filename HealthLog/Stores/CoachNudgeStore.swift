import Foundation
import Observation

/// **v1.18.6 (CCH-03)** — `@MainActor @Observable` driver behind the discreet
/// unread dot on the Coach entry points (the floating button + the More-tab
/// "Coach" row). Holds the server-authoritative unread signal from
/// `GET /api/insights/coach/nudge-status` and exposes ``unread`` for the dot.
///
/// **Server is authority (render-only).** The store never recomputes the unread
/// state — it mirrors `CoachNudgeStatus.unread`. A proactive nudge lands as the
/// initial assistant message of a conversation server-side; this store only
/// reads whether that (or any reply) is newer than the last `seen` stamp.
///
/// **Cheap + SWR-deduped.** ``refresh(coachEnabled:online:)`` single-flights via
/// an in-flight `Task` so a foreground bounce + a Coach-surface-appear in the
/// same tick collapse to one GET. It is gated: no request fires when the `coach`
/// module is off or the device is offline (the caller passes the gate result).
///
/// **Optimistic clear.** Opening a Coach surface calls
/// ``markSeenOptimistically()`` — the dot clears on the same tick, then
/// `POST /api/insights/coach/seen` reconciles server-side (a subsequent refresh
/// confirms `unread == false`). A failed POST leaves the optimistic-cleared dot
/// dark; the next refresh re-surfaces it only if the server still reports unread.
@MainActor
@Observable
public final class CoachNudgeStore {
    /// Drives the dot on the Coach entry points. `false` until a refresh resolves
    /// a real unread nudge — no fabricated state.
    public private(set) var unread: Bool = false

    /// Newest Coach assistant-message timestamp (`nil` when none). Kept so a
    /// future surface can show "last nudged" without a second call; not rendered
    /// today.
    public private(set) var nudgedAt: Date?

    /// The server Coach service. `nil` in unit tests that inject behaviour via
    /// the closure initialiser; production wiring supplies a real
    /// ``CoachServerService``.
    private let fetchStatus: (@Sendable () async throws -> CoachNudgeStatus)?
    private let postSeen: (@Sendable () async throws -> Void)?

    /// W-FOCUS-FILTER — resolves the live Focus-filter config. Injected (not a
    /// direct `FocusFilterConfigStore.current()` read) so tests stay isolated
    /// from the shared App Group suite; production reads the shared store.
    private let focusFilterConfig: @MainActor () -> FocusFilterConfig

    /// In-flight refresh — single-flights concurrent refresh calls (foreground +
    /// surface-appear in the same tick collapse to one GET).
    private var inFlight: Task<Void, Never>?

    /// Production initialiser — binds to a live ``CoachServerService``.
    public init(
        service: CoachServerService,
        focusFilterConfig: @escaping @MainActor () -> FocusFilterConfig = { FocusFilterConfigStore.current() }
    ) {
        fetchStatus = { try await service.nudgeStatus() }
        postSeen = { try await service.markCoachSeen() }
        self.focusFilterConfig = focusFilterConfig
    }

    /// Test / preview initialiser — inject the two network legs directly. The
    /// Focus-filter config defaults to **inactive** so a coach test never inherits
    /// (or bleeds across) the shared App Group suite; production uses the
    /// `service:` initialiser, which reads the shared store.
    public init(
        fetchStatus: (@Sendable () async throws -> CoachNudgeStatus)? = nil,
        postSeen: (@Sendable () async throws -> Void)? = nil,
        focusFilterConfig: @escaping @MainActor () -> FocusFilterConfig = { .inactive }
    ) {
        self.fetchStatus = fetchStatus
        self.postSeen = postSeen
        self.focusFilterConfig = focusFilterConfig
    }

    /// Refresh the unread signal — SWR-deduped + gated.
    ///
    /// - Parameters:
    ///   - coachEnabled: the `coach` module gate. `false` → no call, dot stays
    ///     dark (a disabled surface has nothing to nudge about).
    ///   - online: reachability gate. `false` → no doomed request; the dot keeps
    ///     its last-known value until connectivity returns.
    ///
    /// A coach-disabled refresh also clears any stale unread so the dot never
    /// lingers after the operator switches the module off.
    public func refresh(coachEnabled: Bool, online: Bool) async {
        guard coachEnabled else {
            unread = false
            nudgedAt = nil
            return
        }
        // W-FOCUS-FILTER — while a HealthLog Focus filter pauses coach nudges,
        // keep the proactive-nudge dot dark. The server unread state is
        // untouched; the next refresh after the Focus ends re-surfaces it.
        if focusFilterConfig().suppressesCoachNudges {
            unread = false
            return
        }
        guard online else { return }
        guard let fetchStatus else { return }

        // Single-flight: ride an in-flight refresh rather than spawning a second.
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            do {
                let status = try await fetchStatus()
                self?.apply(status)
            } catch {
                // Fail-quiet: a transient error leaves the last-known dot in place
                // (never flips it on from a failure). The category is operator-grade.
                HLLog.api.error(
                    "Coach nudge-status refresh failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            self?.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Optimistically clear the dot on open, then reconcile server-side.
    /// Opening a Coach surface calls this once; the dot clears on the same tick
    /// so the affordance feels responsive, and the POST stamps the seen time so
    /// the cleared state follows the user across devices.
    ///
    /// The optimistic clear is synchronous (the dot is `false` the moment this
    /// returns); the seen POST is spawned fire-and-forget. The spawned `Task` is
    /// **returned** as a testable seam so a test can `await` the reconcile leg
    /// deterministically instead of yielding-and-hoping under the parallel
    /// runner. Production callers ignore the return value — behaviour is
    /// unchanged (`@discardableResult`).
    @discardableResult
    public func markSeenOptimistically() -> Task<Void, Never>? {
        unread = false
        guard let postSeen else { return nil }
        // No `self` capture: the seen task only awaits the captured `postSeen`
        // closure and owns no store state (it must NOT touch `inFlight`, which
        // belongs to `refresh()`'s single-flight — v0150 C-M2).
        return Task {
            do {
                try await postSeen()
            } catch {
                // The dot is already cleared optimistically; a failed stamp just
                // means the next refresh may re-surface it if the server still
                // reports unread. Honest reconcile, no crash. The seen task owns
                // NO single-flight handle — `inFlight` belongs to `refresh()`, so
                // we must NOT touch it here (doing so cross-contaminated an
                // unrelated in-flight refresh; v0150 C-M2).
                HLLog.api.error(
                    "Coach mark-seen failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }

    /// Reconcile local state from a fresh server status.
    private func apply(_ status: CoachNudgeStatus) {
        unread = status.unread
        nudgedAt = status.nudgedAt
    }

    /// Reset on logout — the next user re-loads their own signal; until then no
    /// dot is shown (a stale unread must never bleed across accounts).
    public func clearOnLogout() {
        inFlight?.cancel()
        inFlight = nil
        unread = false
        nudgedAt = nil
    }

    /// Test-only — set the unread signal without a network round-trip so the
    /// logout-wipe suite can prove `clearOnLogout` purges it (v0150 sec-L1).
    func seedForTesting(unread: Bool, nudgedAt: Date?) {
        self.unread = unread
        self.nudgedAt = nudgedAt
    }
}
