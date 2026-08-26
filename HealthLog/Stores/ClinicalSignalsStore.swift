import Foundation
import Observation

/// `@Observable` wrapper over `ClinicalSignalsRepository` — the three v1.25
/// read-only "clinical signals" awareness reads (GH iOS #38): baseline-drift
/// health status, sleep-breathing screening, and "what changed since your last
/// lab panel".
///
/// **HONEST-ONLY + server-authoritative.** The store surfaces ONLY what the
/// server returns; each payload stays `nil` until a `present`/has-content read
/// lands, so every host card self-suppresses in standalone / no-data exactly
/// like the other conditional insight cards. Nothing is recomputed on-device.
///
/// **Server-derived (paired only).** All three are pure server compute with no
/// on-device fallback — call sites additionally gate on a cloud surface being
/// available so the cards hide in standalone / no-server.
@MainActor
@Observable
public final class ClinicalSignalsStore {
    /// Baseline-drift health status (`GET /api/insights/health-status`).
    public private(set) var healthStatus: InsightsHealthStatusDTO?
    /// Sleep-breathing screening (`GET /api/insights/breathing-screening`).
    public private(set) var breathing: InsightsBreathingScreeningDTO?
    /// Lab-panel changes (`GET /api/insights/labs-changes`).
    public private(set) var labsChanges: InsightsLabsChangesDTO?

    public private(set) var isLoading: Bool = false
    /// `true` once a load has completed at least once this session.
    public private(set) var hasSettledOnce: Bool = false

    private let repo: ClinicalSignalsRepository

    public init(repo: ClinicalSignalsRepository) {
        self.repo = repo
    }

    /// Fetches all three reads concurrently. Each is independent — one route
    /// being absent never blocks the others.
    public func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        async let status = repo.fetchHealthStatus()
        async let breath = repo.fetchBreathingScreening()
        async let labs = repo.fetchLabsChanges()
        let (resolvedStatus, resolvedBreath, resolvedLabs) = await (status, breath, labs)
        healthStatus = resolvedStatus
        breathing = resolvedBreath
        labsChanges = resolvedLabs
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        healthStatus = nil
        breathing = nil
        labsChanges = nil
        hasSettledOnce = false
    }
}
