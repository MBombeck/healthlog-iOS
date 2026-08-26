import Foundation
import Observation

/// **v1.18.6 — app-wide diabetes opt-in state.**
///
/// `@MainActor @Observable` store backing the Settings "I have diabetes /
/// clinician glucose targets" toggle. Server-first: the authoritative flag
/// lives on the server (`GET`/`PATCH /api/auth/me/diabetes`); this is an
/// in-memory cache only (a short TTL avoids smashing the endpoint on every
/// Settings mount). The ADA glucose bands are applied SERVER-SIDE — this store
/// only surfaces the switch + the resolved flag, never any band math.
@MainActor
@Observable
public final class DiabetesStore {
    /// Last-known flag. `nil` until the first successful fetch.
    public private(set) var hasDiabetes: Bool?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    private let repo: DiabetesRepository
    private var lastFetchedAt: Date?
    private let staleAfter: TimeInterval = 60 // seconds

    public init(repo: DiabetesRepository) {
        self.repo = repo
    }

    /// Refetch. Honours the 60 s TTL — pass `force: true` to bypass.
    public func refresh(force: Bool = false) async {
        if !force, let last = lastFetchedAt, -last.timeIntervalSinceNow < staleAfter, hasDiabetes != nil {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let dto = try await repo.fetch()
            hasDiabetes = dto.hasDiabetes
            lastFetchedAt = .now
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// PATCH the flag. Optimistic local flip first so the Settings toggle snaps
    /// instantly, then reconcile with the server's resolved next-state. Reverts
    /// to the previous value on a non-retriable error. Skips the write when the
    /// desired value already matches the in-memory flag. Returns `true` on
    /// success.
    @discardableResult
    public func setHasDiabetes(_ enabled: Bool) async -> Bool {
        if hasDiabetes == enabled { return true }
        let previous = hasDiabetes
        hasDiabetes = enabled // optimistic
        do {
            let dto = try await repo.update(hasDiabetes: enabled)
            hasDiabetes = dto.hasDiabetes
            lastFetchedAt = .now
            error = nil
            return true
        } catch let err as HLError {
            hasDiabetes = previous
            error = err
            return false
        } catch {
            hasDiabetes = previous
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    public func clearOnLogout() {
        hasDiabetes = nil
        lastFetchedAt = nil
        error = nil
    }

    /// Test-only — set the opt-in flag without a network round-trip so the
    /// logout-wipe suite can prove `clearOnLogout` purges it (v0150 sec-L1).
    func seedForTesting(hasDiabetes: Bool) {
        self.hasDiabetes = hasDiabetes
    }
}
