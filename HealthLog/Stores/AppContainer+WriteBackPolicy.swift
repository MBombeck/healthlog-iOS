import Foundation

// MARK: - B5 (1.4) — the per-type direction for writes into Apple Health

extension AppContainer {
    /// Hands the HealthKit writer the person's per-type direction from
    /// `GET /api/integrations/healthkit`, read through the same SWR entry the
    /// Settings store keeps (`.hkSyncConfig`, five minutes fresh, the cached
    /// answer offline). `nil` when nothing is cached and the server cannot be
    /// asked: the writer then writes nothing for the kinds it cannot decide
    /// and tries again on its next pass.
    static func attachWriteBackPolicy(
        healthKit: AnyHealthKitWriter?,
        swr: SWRCoordinator,
        settingsRepo: SettingsRepository
    ) {
        guard let healthKit else { return }
        let provider: @Sendable () async -> HealthKitWriteBackPolicy? = {
            if let fetched = try? await swr.fetchCachingFirst(.hkSyncConfig, decoding: HealthKitSyncConfig.self, fetch: {
                // HK-NEW (1.5) — a network answer also says which types the
                // server maps (`acceptedTypes`, once it publishes the list).
                try await HealthKitAcceptedTypes.recording(settingsRepo.healthKitConfig())
            }) {
                return HealthKitWriteBackPolicy(entries: fetched.entries)
            }
            // A failed refresh still has the last answer: a setting changes
            // rarely, and the last one is closer to the truth than none.
            let cached = await swr.peek(.hkSyncConfig, as: HealthKitSyncConfig.self)?.value
            return cached.map { HealthKitWriteBackPolicy(entries: $0.entries) }
        }
        Task.detached {
            await healthKit.attachWriteBackPolicy(provider)
        }
    }
}
