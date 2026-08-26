import Foundation
import Observation

/// `@Observable` store backing the surface guards on
/// `InsightsScreen` / `DailyBriefingHero` / `CorrelationsPanel` /
/// `HealthScoreExplainer`, and the on-device-AI gates on
/// `OnDeviceBriefingService` + `TrendObservationsService`.
///
/// **Per-session memoisation.** The store fetches `/api/feature-flags`
/// once at startup and again on every app-foreground transition.
/// Surface guards read the cached value synchronously — no
/// per-render network round-trip — and the foreground refresh
/// propagates operator-changed state within a single fetch.
///
/// **R5 contract (server brief §c.1 + the cross-coordination audit
/// §g.R5):** the store is the single source of truth for BOTH
/// server-AI surface guards AND on-device assistant gates. The
/// snapshot exposed via ``snapshot`` is a Sendable value type that
/// can cross the actor boundary into `OnDeviceBriefingService`
/// without forcing a main-actor hop on every flag check.
///
/// **Fail-open during bootstrap.** Until the first fetch lands,
/// `isEnabled(_:)` returns ``FeatureFlag/defaultValue`` for every
/// flag — defaults are ON so a fresh launch on a fast device starts
/// the on-device path immediately. If the operator wants a surface
/// off, the first fetch flips it before any user-visible AI output
/// renders.
///
/// **Surface placeholder routing.** When a flag is explicitly false
/// (server-deployed off-state), screens read it via
/// ``isEnabled(_:)`` and render a neutral ``FeatureDisabledCard``
/// in place of the gated content. The card surface is the same
/// regardless of whether the gate was set client-side (default-off
/// during bootstrap, never happens today) or server-side (operator
/// flipped the flag) — operator-control philosophy.
///
/// **Why `@MainActor`?** SwiftUI views read flags via `Environment`
/// during the body evaluation; the store is part of the View tree's
/// dependency graph, so `@MainActor` keeps reads cost-free.
@MainActor
@Observable
public final class FeatureFlagsStore {
    /// Current operator-configured flag map. `nil` until the first
    /// fetch lands. Once non-nil, never reverts to nil — even on
    /// fetch failure (we keep the last-known map and surface
    /// ``error``).
    public private(set) var flags: [FeatureFlag: Bool] = [:]

    /// True from `refresh()` entry until the network call resolves.
    /// Surface guards do **not** show a spinner; this is a debug
    /// affordance (Inspector views, future Settings → Diagnostics).
    public private(set) var isLoading: Bool = false

    /// Last error from a failed refresh. Cleared on the next
    /// successful fetch. Surface guards ignore errors — fail-open is
    /// the only acceptable failure mode (R5: operator-control means
    /// the operator turns OFF, not the network).
    public private(set) var error: HLError?

    /// True after the first successful fetch lands. Surface guards
    /// can use this to differentiate "haven't fetched yet, show
    /// defaults" from "fetched, here's the truth" if they want a
    /// stricter render mode — by default they don't.
    public private(set) var hasSnapshot: Bool = false

    private let repo: FeatureFlagsRepository
    /// Sendable shadow cell that mirrors ``flags`` so cross-actor
    /// readers (`OnDeviceBriefingService` / `TrendObservationsService`,
    /// both `actor` types) can sync-query the flag map without a
    /// MainActor hop. Updated atomically on every refresh /
    /// applyDisabled / clearOnLogout transition. The cell is
    /// `nonisolated(unsafe)` because writes are confined to the
    /// MainActor (this store) and reads are concurrent — single-
    /// writer-multiple-reader from a Foundation cell is the
    /// idiomatic Swift Concurrency-safe pattern for this shape.
    private let liveCell = LiveFlagsCell()

    public init(repo: FeatureFlagsRepository) {
        self.repo = repo
    }

    /// Live `FeatureFlagsServicing` adaptor backed by the shadow
    /// cell. Hand this to the on-device-AI actors so they consult
    /// the current operator state without a hop. Always returns the
    /// SAME instance so callers can capture it once at construction.
    public func liveService() -> LiveFeatureFlagsService {
        let cell = liveCell
        return LiveFeatureFlagsService(resolve: { flag in
            cell.isEnabled(flag)
        })
    }

    /// Synchronous flag query. Pre-snapshot reads return the
    /// `FeatureFlag.defaultValue` so on-device AI doesn't blink off
    /// during launch. Post-snapshot reads return the server-deployed
    /// state.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag] ?? flag.defaultValue
    }

    /// Sendable view of the current flag map. Hand this to the
    /// on-device assistant actors so they don't have to hop to the
    /// main actor for every gate check (R5 wiring).
    public var snapshot: FeatureFlagsStoreSnapshot {
        FeatureFlagsStoreSnapshot(flags: flags)
    }

    /// Fetches the operator-configured flag set from
    /// `GET /api/feature-flags`. Idempotent — call on every app
    /// foreground transition; per-session cache is the store's
    /// `flags` map (never touches `URLCache` or any disk).
    ///
    /// On failure, keeps the last-known flag map and surfaces the
    /// error in ``error`` for debug surfaces. Surface guards never
    /// flip to "disabled" on a fetch error — fail-open is the only
    /// acceptable failure mode.
    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let wireFlags = try await repo.fetch()
            flags = Self.mapWireFlags(wireFlags)
            liveCell.store(flags)
            hasSnapshot = true
        } catch let err as HLError {
            HLLog.api.warning(
                "FeatureFlagsStore.refresh failed: \(err.localizedDescription, privacy: .private) — keeping last-known flags"
            )
            error = err
        } catch {
            HLLog.api.warning(
                "FeatureFlagsStore.refresh failed: \(String(describing: type(of: error)), privacy: .public) — keeping last-known flags"
            )
            self.error = .unknown(String(describing: error))
        }
    }

    /// Targeted update from a server-emitted 403 errorCode envelope.
    /// When `APIClient` parses
    /// `"errorCode": "assistant.disabled.<surface>"` it throws
    /// ``HLError/assistantDisabled(_:)`` and the caller can mirror
    /// the operator-state into the store **without** a follow-up
    /// `/api/feature-flags` round-trip. The store then surfaces the
    /// disabled state on the next render tick.
    ///
    /// Idempotent — repeated calls with the same flag are no-ops.
    public func applyDisabled(_ flag: FeatureFlag) {
        guard flags[flag] != false else { return }
        flags[flag] = false
        liveCell.store(flags)
    }

    /// Wipes cached flags on logout. Next login fetches fresh.
    public func clearOnLogout() {
        flags = [:]
        liveCell.store(flags)
        error = nil
        hasSnapshot = false
    }

    // MARK: - Helpers

    /// Maps the wire `[String: Bool]` payload to the typed
    /// `[FeatureFlag: Bool]` cache. Unknown keys are skipped (the
    /// server may ship a new surface before iOS knows about it —
    /// silent skip is the additive contract).
    static func mapWireFlags(_ wire: [String: Bool]) -> [FeatureFlag: Bool] {
        var out: [FeatureFlag: Bool] = [:]
        for (key, value) in wire {
            guard let flag = FeatureFlag(rawValue: key) else {
                // Server-defined feature-flag key (enum-grade wire constant), no user data.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.api.debug("FeatureFlagsStore: ignoring unknown wire flag \(key, privacy: .public)")
                continue
            }
            out[flag] = value
        }
        return out
    }
}

/// Sendable lock-guarded shadow of the flag map. Reads cross
/// actor isolation (used by the on-device AI services from their
/// own actor queues); writes happen on the MainActor from
/// `FeatureFlagsStore`. `NSLock.withLock` keeps the critical
/// section synchronous so neither the actor read nor the MainActor
/// write can suspend mid-lock (Swift 6 cooperative-pool safety).
final class LiveFlagsCell: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [FeatureFlag: Bool] = [:]

    func store(_ next: [FeatureFlag: Bool]) {
        lock.withLock { flags = next }
    }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        lock.withLock { flags[flag] ?? flag.defaultValue }
    }
}
