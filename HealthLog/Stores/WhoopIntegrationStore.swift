import Foundation
import Observation

/// `@Observable` wrapper over `WhoopRepository` for the Settings → Integrations
/// WHOOP surface. Mirrors `WithingsIntegrationStore` (status read + mutations,
/// browser-only connect stays in the View), plus the BYO-key delta: it owns the
/// credentials-entry step + the `test`/`resume` probes.
///
/// **State machine** (derived from `status`, see ``WhoopStage``):
/// 1. `!configured`           → `.needsCredentials` — paste Client ID/Secret.
/// 2. `configured && !connected` → `.needsConnect` — open the OAuth browser.
/// 3. `connected`             → `.connected` — status + sync/test/disconnect.
///
/// **No persistence.** Status is server-authoritative and re-fetched after every
/// mutation. The clientSecret draft is held only transiently in the View's local
/// `@State` and passed straight through `saveCredentials`; it is never stored on
/// the store and never logged.
@MainActor
@Observable
public final class WhoopIntegrationStore {
    /// The three gated stages of the WHOOP Settings surface.
    public enum WhoopStage: Equatable, Sendable {
        /// No status loaded yet — render a calm initial state.
        case loading
        /// BYO-key creds not yet saved (`configured == false`).
        case needsCredentials
        /// Creds saved, OAuth not yet completed (`configured && !connected`).
        case needsConnect
        /// Linked but the OAuth token expired — sync is dead until the user
        /// re-connects. Surfaced as its own stage so the top-line status pill
        /// stops claiming "Connected" while nothing is flowing (A4 MEDIUM #1).
        case tokenExpired
        /// Fully linked (`connected == true`).
        case connected
    }

    public private(set) var status: WhoopStatus?
    public private(set) var isWorking: Bool = false
    public private(set) var error: HLError?
    /// Last `test` probe result (`{ ok, lastSyncedAt, latencyMs }`), shown
    /// transiently under the Test-connection action. Cleared on the next action.
    public private(set) var lastTestResult: WhoopTestResult?

    private let repo: WhoopRepository
    private let connector: WhoopConnecting?
    /// Resolves the live server base URL for the connect start URL. Injected so
    /// the store stays testable without an `AppContainer`. `nil` ⇒ no live env
    /// (standalone / tests that don't exercise connect).
    private let baseURLProvider: @MainActor () -> URL?
    private let authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry?
    private let userIDProvider: @MainActor () -> String?
    private var localGeneration: UInt64 = 0

    private struct EffectLease {
        let localGeneration: UInt64
        let authenticated: AuthenticatedSessionLease?
    }

    public init(
        repo: WhoopRepository,
        connector: WhoopConnecting? = nil,
        baseURLProvider: @escaping @MainActor () -> URL? = { nil }
    ) {
        self.repo = repo
        self.connector = connector
        self.baseURLProvider = baseURLProvider
        authenticatedSessionRegistry = nil
        userIDProvider = { nil }
    }

    init(
        repo: WhoopRepository,
        connector: WhoopConnecting? = nil,
        baseURLProvider: @escaping @MainActor () -> URL? = { nil },
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        userIDProvider: @escaping @MainActor () -> String?
    ) {
        self.repo = repo
        self.connector = connector
        self.baseURLProvider = baseURLProvider
        self.authenticatedSessionRegistry = authenticatedSessionRegistry
        self.userIDProvider = userIDProvider
    }

    /// Derived stage the View renders against.
    public var stage: WhoopStage {
        guard let status else { return .loading }
        if status.connected {
            // A token-expired connection is technically `connected == true`
            // but is no longer syncing — downgrade so the status pill reflects
            // the dead-sync reality and the re-connect affordance shows.
            return status.tokenExpired == true ? .tokenExpired : .connected
        }
        if status.configured == true { return .needsConnect }
        return .needsCredentials
    }

    /// `true` when the live connection is parked by WHOOP's rate limiter and
    /// the operator can un-park it via `resume()`. Inferred from the last
    /// `test`/`resume` error code (status has no parked flag) — gated in the
    /// View on `lastErrorCode == "rate_limited" || "rate_limited_self"`.
    public private(set) var lastErrorCode: String?

    /// (Re)loads the connection + credential status.
    public func loadStatus() async {
        guard let lease = captureEffectLease() else { return }
        error = nil
        do {
            let loadedStatus = try await repo.status()
            guard isCurrent(lease) else { return }
            status = loadedStatus
            // A fresh, healthy status clears any stale parked signal — the
            // server un-parked or the connection recovered.
            if status?.connected == true, status?.tokenExpired != true {
                lastErrorCode = nil
            }
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Saves the per-user WHOOP Client ID + Secret, then re-loads status so the
    /// stage advances to `.needsConnect`. The secret is forwarded once and never
    /// retained here.
    public func saveCredentials(clientId: String, clientSecret: String) async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            try await repo.saveCredentials(clientId: clientId, clientSecret: clientSecret)
            guard isCurrent(lease) else { return }
            await loadStatus()
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Wipes stored credentials + the OAuth connection, then re-loads status
    /// (stage falls back to `.needsCredentials`).
    public func removeCredentials() async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            try await repo.deleteCredentials()
            guard isCurrent(lease) else { return }
            await loadStatus()
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Pulls now, then re-loads status.
    public func syncNow(fullSync: Bool = false) async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            try await repo.sync(fullSync: fullSync)
            guard isCurrent(lease) else { return }
            await loadStatus()
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// `true` once a `test`/`resume` probe reported the connection is parked by
    /// WHOOP's rate limiter. Drives the "Resume sync" affordance — the status
    /// snapshot has no parked flag, so the error code is the only signal.
    public var isRateLimitParked: Bool {
        lastErrorCode == "rate_limited" || lastErrorCode == "rate_limited_self"
    }

    /// Probes the live connection; stores the result (or surfaces the mapped
    /// `errorCode` via ``error``). Records the error code so a `rate_limited*`
    /// outcome can reveal the "Resume sync" recovery affordance.
    public func testConnection() async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            let result = try await repo.test()
            guard isCurrent(lease) else { return }
            lastTestResult = result
            lastErrorCode = nil
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
            lastErrorCode = Self.serverCode(from: err)
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Un-parks a rate-limit-parked connection (`POST /api/integrations/whoop/
    /// resume`), then re-loads status. Clears the parked signal on success.
    public func resume() async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            _ = try await repo.resume()
            guard isCurrent(lease) else { return }
            lastErrorCode = nil
            await loadStatus()
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
            lastErrorCode = Self.serverCode(from: err)
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Extracts the server `errorCode` from an `HLError.server`, else `nil`.
    private static func serverCode(from error: HLError) -> String? {
        if case let .server(_, code, _) = error { return code }
        return nil
    }

    /// Revokes the OAuth link (keeps creds), then re-loads status.
    public func disconnect() async {
        guard let lease = captureEffectLease() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }
        do {
            try await repo.disconnect()
            guard isCurrent(lease) else { return }
            await loadStatus()
        } catch let err as HLError {
            guard isCurrent(lease) else { return }
            error = err
        } catch {
            guard isCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Runs the WHOOP OAuth connect leg in an in-app auth session, then re-reads
    /// status as the authoritative connected signal (`configured && connected`).
    ///
    /// **Mechanism (B5).** The session is opened against `…/api/whoop/connect`
    /// itself (NOT a pre-fetched WHOOP URL) so the server's httpOnly nonce cookie
    /// round-trips. The final server redirect is a web URL (`…/settings/
    /// integrations?whoop=connected|error`) — we parse it when the session
    /// surfaces it, but ALWAYS re-read `GET /api/whoop/status` afterwards and gate
    /// the connected stage on `configured && connected`, so a missed/dismissed
    /// web redirect still resolves to the truth. A `whoop=error` outcome surfaces
    /// the mapped reason; `.canceled` (real dismissal OR the un-catchable web
    /// redirect) stays quiet and lets the status re-read decide.
    ///
    /// Requires both a `connector` and a resolvable base URL; absent either (e.g.
    /// standalone) it no-ops.
    public func connect() async {
        guard let lease = captureEffectLease() else { return }
        guard let connector, let baseURL = baseURLProvider() else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { if isCurrent(lease) { isWorking = false } }

        let connectURL = baseURL.appendingPathComponent("/api/whoop/connect")
        let outcome = await connector.connect(connectURL: connectURL)
        guard isCurrent(lease) else { return }

        // Re-read status FIRST as the authoritative signal — `loadStatus()`
        // resets `error` to nil, so any failure message must be set AFTER it.
        await loadStatus()
        guard isCurrent(lease) else { return }

        if case let .failed(reason) = outcome {
            let parsed = WhoopConnectOutcome.failed(reason: reason)
            if let message = parsed.userFacingMessage {
                // Surface as a server-style error so the View's existing error
                // row renders it; code lets `rate_limited` reuse the same map.
                error = .server(status: 400, code: reason.isEmpty ? "connect" : reason, message: message)
            }
        }
    }

    public func clearOnLogout() {
        localGeneration &+= 1
        status = nil
        isWorking = false
        error = nil
        lastTestResult = nil
        lastErrorCode = nil
    }

    private func captureEffectLease() -> EffectLease? {
        guard let authenticatedSessionRegistry else {
            return EffectLease(localGeneration: localGeneration, authenticated: nil)
        }
        guard let ownerID = userIDProvider(),
              let authenticated = authenticatedSessionRegistry.capture(ownerID: ownerID) else
        {
            return nil
        }
        return EffectLease(localGeneration: localGeneration, authenticated: authenticated)
    }

    private func isCurrent(_ lease: EffectLease) -> Bool {
        guard lease.localGeneration == localGeneration else { return false }
        return lease.authenticated?.isCurrent ?? !Task.isCancelled
    }
}
