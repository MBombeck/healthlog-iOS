import Foundation
import Observation

/// Shared, provider-parameterised implementation backing the Settings →
/// Integrations Oura / Polar / Fitbit surfaces. Mirrors
/// ``WithingsIntegrationStore`` (status read + mutations, browser-only connect
/// stays in the View).
///
/// SwiftUI's `@Environment(Type.self)` keys on the concrete type, so each
/// provider needs a *distinct* environment type — the three thin
/// `final @Observable` wrappers below (`OuraIntegrationStore` etc.) forward to a
/// private instance of this core. Keeping the logic here means the three
/// surfaces can never drift.
///
/// **No persistence.** Status is server-authoritative, re-fetched after every
/// mutation.
@MainActor
@Observable
public final class OAuthIntegrationCore {
    public private(set) var status: OAuthIntegrationStatus?
    public private(set) var isWorking: Bool = false
    public private(set) var error: HLError?
    /// Whether the user has stored their own OAuth client id/secret (BYO). `nil`
    /// until the first credentials load.
    public private(set) var credentials: BYOCredentialsStatus?
    /// The most recent live token-probe result (`/test`). `nil` until a test runs.
    public private(set) var lastTestResult: ConnectionTestResult?
    /// **CU-35 (1)** — what the last "Sync now" tap ended in. Deliberately its
    /// own state and NOT folded into ``error``: a 429 ("you just did") and a 502
    /// ("the provider didn't answer") are not failures of this app, and painting
    /// them on the generic red error line would say the opposite of what
    /// happened.
    public private(set) var syncState: ManualSyncState = .idle

    public let provider: OAuthIntegrationRepository.Provider
    /// Whether this provider exposes a manual `/sync` route (Fitbit only).
    public let supportsManualSync: Bool

    private let repo: OAuthIntegrationRepository

    public init(repo: OAuthIntegrationRepository, provider: OAuthIntegrationRepository.Provider) {
        self.repo = repo
        self.provider = provider
        supportsManualSync = provider.supportsManualSync
    }

    /// `true` when a token is stored. `nil` until the first status load so the
    /// list pill stays calm (no false "Connected" flash).
    public var isConnected: Bool? {
        status.map(\.connected)
    }

    /// Whether this provider exposes a live `/test` token-probe.
    public var supportsConnectionTest: Bool {
        provider.supportsConnectionTest
    }

    /// Whether the user has stored their own OAuth credentials. `nil` until the
    /// first credentials load.
    public var hasOwnCredentials: Bool? {
        credentials.map(\.hasCredentials)
    }

    public func loadStatus() async {
        error = nil
        do {
            status = try await repo.status()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Ask the server to pull from the provider now.
    ///
    /// The three registers stay separate on purpose (CU-35):
    ///  - a 2xx publishes the server's own `{ imported, outcome }` verdict, so
    ///    "nothing new over there" (`outcome == .empty`) reads as the normal
    ///    non-event it is rather than as a failed run;
    ///  - a 429 / 502 publishes on ``syncState`` **only** — ``error`` stays
    ///    `nil`, because neither is something the user did wrong or can repair;
    ///  - anything else lands on both, so the existing error surface still shows
    ///    genuine failures.
    ///
    /// The status re-read is skipped on a 429: nothing ran, so there is no new
    /// ledger state to fetch, and a second call would spend budget for nothing.
    public func syncNow() async {
        guard supportsManualSync else { return }
        isWorking = true
        error = nil
        syncState = .running
        defer { isWorking = false }
        do {
            let result = try await repo.sync()
            syncState = .finished(result)
            await loadStatus()
        } catch {
            let state = ManualSyncState.classify(error)
            syncState = state
            if case .failed = state {
                self.error = (error as? HLError) ?? .unknown(String(describing: error))
            }
            if case .upstreamUnavailable = state {
                // The run reached the server and the server reached its ledger —
                // the failure is recorded there, so a status re-read shows it.
                await loadStatus()
            }
        }
    }

    public func disconnect() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await repo.disconnect()
            await loadStatus()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Drives the `isWorking` spinner around the browser-only connect flow.
    /// The connect itself stays in the View (it opens the system browser, no
    /// API round-trip) — parity with ``WithingsIntegrationStore``.
    public func openingExternalConnect(_ open: @MainActor () async -> Void) async {
        isWorking = true
        defer { isWorking = false }
        await open()
    }

    // MARK: - BYO credentials + connection test

    /// Load whether the user has stored their own OAuth credentials. Soft — a
    /// failure leaves `credentials == nil` (the screen shows the fallback copy)
    /// without spamming the shared error surface.
    public func loadCredentialsStatus() async {
        do {
            credentials = try await repo.credentialsStatus()
        } catch {
            // Non-fatal: the BYO card degrades to "not set" rather than erroring.
            credentials = nil
        }
    }

    /// Store the user's OAuth client id/secret, then re-read credentials +
    /// status. Returns `true` on success so the View can clear the secret field.
    @discardableResult
    public func saveCredentials(clientId: String, clientSecret: String) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await repo.saveCredentials(clientId: clientId, clientSecret: clientSecret)
            await loadCredentialsStatus()
            await loadStatus()
            return error == nil
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// Delete the stored credentials (also drops any live connection), then
    /// re-read credentials + status.
    public func deleteCredentials() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await repo.deleteCredentials()
            await loadCredentialsStatus()
            await loadStatus()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Run the live token probe (`/test`). No-op on providers without the route.
    /// Publishes the result on ``lastTestResult``; a rejected token / timeout
    /// surfaces on ``error``.
    public func testConnection() async {
        guard supportsConnectionTest else { return }
        isWorking = true
        error = nil
        lastTestResult = nil
        defer { isWorking = false }
        do {
            lastTestResult = try await repo.test()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearOnLogout() {
        status = nil
        error = nil
        credentials = nil
        lastTestResult = nil
        syncState = .idle
    }
}

/// Provider-distinct `@Observable` environment types. Each forwards to a
/// private ``OAuthIntegrationCore`` so SwiftUI's type-keyed environment can
/// resolve the right provider without the three surfaces drifting.
@MainActor
public protocol OAuthIntegrationStoreProtocol: AnyObject {
    var status: OAuthIntegrationStatus? { get }
    var isWorking: Bool { get }
    var error: HLError? { get }
    var credentials: BYOCredentialsStatus? { get }
    var lastTestResult: ConnectionTestResult? { get }
    /// CU-35 (1) — the last manual-sync verdict, separate from ``error``.
    var syncState: ManualSyncState { get }
    var provider: OAuthIntegrationRepository.Provider { get }
    var supportsManualSync: Bool { get }
    var supportsConnectionTest: Bool { get }
    var isConnected: Bool? { get }
    var hasOwnCredentials: Bool? { get }
    func loadStatus() async
    func syncNow() async
    func disconnect() async
    func loadCredentialsStatus() async
    @discardableResult
    func saveCredentials(clientId: String, clientSecret: String) async -> Bool
    func deleteCredentials() async
    func testConnection() async
    func openingExternalConnect(_ open: @MainActor () async -> Void) async
    func clearOnLogout()
}

/// Every wrapper is a pure forwarder to its private ``OAuthIntegrationCore`` —
/// the only difference is which provider it pins. The protocol-extension default
/// implementations forward through `core` so the four surfaces can never drift;
/// each concrete type only has to expose its `core`. Observation still tracks
/// correctly because reads land on `core` (itself `@Observable`) regardless of
/// the accessor path.
@MainActor
public extension OAuthIntegrationStoreProtocol where Self: OAuthIntegrationStoreForwarding {
    var status: OAuthIntegrationStatus? {
        core.status
    }

    var isWorking: Bool {
        core.isWorking
    }

    var error: HLError? {
        core.error
    }

    var credentials: BYOCredentialsStatus? {
        core.credentials
    }

    var lastTestResult: ConnectionTestResult? {
        core.lastTestResult
    }

    var syncState: ManualSyncState {
        core.syncState
    }

    var provider: OAuthIntegrationRepository.Provider {
        core.provider
    }

    var supportsManualSync: Bool {
        core.supportsManualSync
    }

    var supportsConnectionTest: Bool {
        core.supportsConnectionTest
    }

    var isConnected: Bool? {
        core.isConnected
    }

    var hasOwnCredentials: Bool? {
        core.hasOwnCredentials
    }

    func loadStatus() async {
        await core.loadStatus()
    }

    func syncNow() async {
        await core.syncNow()
    }

    func disconnect() async {
        await core.disconnect()
    }

    func loadCredentialsStatus() async {
        await core.loadCredentialsStatus()
    }

    @discardableResult
    func saveCredentials(clientId: String, clientSecret: String) async -> Bool {
        await core.saveCredentials(clientId: clientId, clientSecret: clientSecret)
    }

    func deleteCredentials() async {
        await core.deleteCredentials()
    }

    func testConnection() async {
        await core.testConnection()
    }

    func openingExternalConnect(_ open: @MainActor () async -> Void) async {
        await core.openingExternalConnect(open)
    }

    func clearOnLogout() {
        core.clearOnLogout()
    }
}

/// Marker refinement exposing the shared `core` so the protocol extension above
/// can supply every forwarding member once.
@MainActor
public protocol OAuthIntegrationStoreForwarding: OAuthIntegrationStoreProtocol {
    var core: OAuthIntegrationCore { get }
}

@MainActor
@Observable
public final class OuraIntegrationStore: OAuthIntegrationStoreForwarding {
    public let core: OAuthIntegrationCore
    public init(repo: OAuthIntegrationRepository) {
        core = OAuthIntegrationCore(repo: repo, provider: .oura)
    }
}

@MainActor
@Observable
public final class PolarIntegrationStore: OAuthIntegrationStoreForwarding {
    public let core: OAuthIntegrationCore
    public init(repo: OAuthIntegrationRepository) {
        core = OAuthIntegrationCore(repo: repo, provider: .polar)
    }
}

@MainActor
@Observable
public final class FitbitIntegrationStore: OAuthIntegrationStoreForwarding {
    public let core: OAuthIntegrationCore
    public init(repo: OAuthIntegrationRepository) {
        core = OAuthIntegrationCore(repo: repo, provider: .fitbit)
    }
}

/// v1.28.11 (#46) — Strava workout/activity ingest. Same server-OAuth surface as
/// Oura/Polar (browser connect, status, disconnect) plus BYO credentials + the
/// live `/test` probe.
@MainActor
@Observable
public final class StravaIntegrationStore: OAuthIntegrationStoreForwarding {
    public let core: OAuthIntegrationCore
    public init(repo: OAuthIntegrationRepository) {
        core = OAuthIntegrationCore(repo: repo, provider: .strava)
    }
}
