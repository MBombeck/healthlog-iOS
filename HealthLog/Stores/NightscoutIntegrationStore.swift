import Foundation
import Observation

/// `@Observable` wrapper over ``NightscoutRepository`` for the Settings →
/// Integrations Nightscout surface. Unlike the OAuth wearables the connect step
/// is a URL-+-token paste form, so the connect mutation lives **here** (a real
/// `POST` round-trip), not in the View.
///
/// **No persistence.** The URL/token are stored encrypted server-side; iOS
/// holds them only transiently in the form fields the View binds.
@MainActor
@Observable
public final class NightscoutIntegrationStore {
    public private(set) var status: NightscoutStatus?
    public private(set) var isWorking: Bool = false
    public private(set) var error: HLError?
    /// The most recent live-probe result (`POST /api/nightscout/test`). `nil`
    /// until a test runs.
    public private(set) var lastTestResult: ConnectionTestResult?
    /// **CU-35 (1)** — what the last "Sync now" tap ended in. Kept apart from
    /// ``error`` for the same reason as on the OAuth surfaces: a 429 means "you
    /// just did" and a 502 means "your Nightscout instance didn't answer", and
    /// neither belongs on a red error line that implies the app broke.
    public private(set) var syncState: ManualSyncState = .idle

    private let repo: NightscoutRepository

    public init(repo: NightscoutRepository) {
        self.repo = repo
    }

    /// `true` when an instance URL is stored. `nil` until first load.
    public var isConnected: Bool? {
        status.map(\.connected)
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

    /// Saves the pasted instance URL (+ optional token), then re-loads status.
    /// Returns `true` on success so the View can dismiss the form.
    @discardableResult
    public func connect(url: String, token: String, allowPrivateHost: Bool) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await repo.connect(url: url, token: token, allowPrivateHost: allowPrivateHost)
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

    /// **CU-35 (1)** — ask the server to pull from the Nightscout instance now.
    /// Same three-register split as ``OAuthIntegrationCore/syncNow()``: a 2xx
    /// publishes the server's `{ imported, outcome }` verdict, a 429 / 502 lands
    /// on ``syncState`` alone, anything else also on ``error``.
    public func syncNow() async {
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
                await loadStatus()
            }
        }
    }

    /// Run the live connection probe (`/test`). Publishes the result on
    /// ``lastTestResult``; a rejected token / unreachable instance surfaces on
    /// ``error``.
    public func testConnection() async {
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
        lastTestResult = nil
        syncState = .idle
    }
}
