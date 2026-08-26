import Foundation
import Observation

/// `@Observable` wrapper over `WithingsRepository` for the Settings →
/// Integrations Withings surface. Holds the connection status + the
/// load/sync/disconnect lifecycle the screen renders.
///
/// The browser-only connect flow stays in the View (it opens the system
/// browser, no API round-trip) — only the status read + the two mutations are
/// owned here.
///
/// **No persistence.** Status is server-authoritative and re-fetched after
/// every mutation.
@MainActor
@Observable
public final class WithingsIntegrationStore {
    public private(set) var status: WithingsStatus?
    public private(set) var isWorking: Bool = false
    public private(set) var error: HLError?

    private let repo: WithingsRepository

    public init(repo: WithingsRepository) {
        self.repo = repo
    }

    /// (Re)loads the connection status.
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

    /// Pulls the `measure` bucket now, then re-loads status.
    public func syncNow() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await repo.sync()
            await loadStatus()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Revokes the Withings link, then re-loads status.
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
    /// API round-trip), but the spinner state is owned here for parity with
    /// the sync/disconnect mutations.
    public func openingExternalConnect(_ open: @MainActor () async -> Void) async {
        isWorking = true
        defer { isWorking = false }
        await open()
    }

    public func clearOnLogout() {
        status = nil
        error = nil
    }
}
