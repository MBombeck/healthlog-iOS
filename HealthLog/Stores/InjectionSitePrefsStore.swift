import Foundation
import Observation

/// App-wide user-level injection-site **deny-list** state (server v1.8.5).
///
/// The deny-list is server-authoritative (`/api/auth/me/injection-site-prefs`)
/// — this store is an in-memory cache with a short TTL so the site-picker can
/// read the effective set without smashing the endpoint, plus the Settings
/// editor's optimistic write surface.
///
/// **Fail-open:** a fetch failure leaves `excluded == []` so the picker never
/// hides a valid site on a transient blip. The server is the final gate (422
/// on an out-of-set submit), so an over-broad local effective set degrades to
/// a graceful re-fetch, never silent data loss.
///
/// **Optimistic PATCH:** the toggle flips the local set immediately; on a
/// non-retriable failure it rolls back to the server-confirmed list.
@MainActor
@Observable
public final class InjectionSitePrefsStore {
    /// Globally-excluded sites. Empty until the first fetch (fail-open default).
    public private(set) var excluded: [InjectionSite] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    private let repo: InjectionSitePrefsRepository
    private var lastFetchedAt: Date?
    private let staleAfter: TimeInterval = 60

    public init(repo: InjectionSitePrefsRepository) {
        self.repo = repo
    }

    /// Refetch the deny-list. Honours a 60 s TTL — pass `force: true` to bypass.
    /// On failure keeps the last-known list (fail-open).
    public func refresh(force: Bool = false) async {
        if !force, let last = lastFetchedAt, -last.timeIntervalSinceNow < staleAfter {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            excluded = try await repo.fetch()
            lastFetchedAt = .now
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Whether a given site is currently globally excluded.
    public func isExcluded(_ site: InjectionSite) -> Bool {
        excluded.contains(site)
    }

    /// Toggle a site in/out of the deny-list and hard-set the new list
    /// server-side (PATCH replaces the full list). Optimistic — rolls back on
    /// a non-retriable failure.
    public func toggle(_ site: InjectionSite) async {
        let previous = excluded
        var next = excluded
        if let idx = next.firstIndex(of: site) {
            next.remove(at: idx)
        } else {
            next.append(site)
        }
        // Keep canonical `allCases` order so the editor stays stable.
        excluded = InjectionSite.allCases.filter { next.contains($0) }
        error = nil
        do {
            let confirmed = try await repo.update(excluded: excluded)
            excluded = confirmed
            lastFetchedAt = .now
        } catch let err as HLError {
            error = err
            // A durably-enqueued PATCH (retriable OR transient-refresh 401)
            // keeps the optimistic deny-list; only a dropped write rolls back.
            if !err.shouldPersistToOutbox { excluded = previous }
        } catch {
            self.error = .unknown(String(describing: error))
            excluded = previous
        }
    }

    /// The effective allowed set for a medication, given its per-med
    /// allow-list and the current global deny-list. Deny always wins.
    public func effectiveAllowed(for allowed: [InjectionSite]) -> [InjectionSite] {
        InjectionSiteEffectiveSet.effective(allowed: allowed, globalExcluded: excluded)
    }

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — drop the previous user's
    /// deny-list on logout (it reveals injection-therapy use) and reset the
    /// TTL so the next user's first read always fetches fresh.
    public func clearOnLogout() {
        excluded = []
        isLoading = false
        error = nil
        lastFetchedAt = nil
    }
}
