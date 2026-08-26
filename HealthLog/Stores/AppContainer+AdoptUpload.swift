import Foundation

/// v0.11 W4 — adopt-on-pair upload wiring, extracted from `AppContainer.init`
/// to keep the composition-root file under its length budget.
///
/// Builds the `AuthStore.adoptUploadHook`: when a standalone user pairs (the
/// `beginServerPairing()` intent flag + the terminal `.authenticated` site fire
/// it), reads the local mirror, recreates local-only medications, and replays
/// measurements / moods / intakes over the idempotent batch endpoints.
///
/// The medication-definition provider resolves local med ids from the
/// `LocalRepository` medication mirror (v0.13 W5) — the offline med catalogue is
/// authoritative even when the in-memory `MedicationsStore` is unloaded at
/// pair-time. The local mirror is KEPT after upload — it's the offline cache,
/// and the idempotent re-run depends on it. No-op for paired-from-start users
/// (the hook never runs without a standalone→paired transition).
extension AppContainer {
    static func makeAdoptUploadHook(
        api: APIClientProtocol,
        localRepo: LocalRepository,
        medicationsStore: MedicationsStore
    ) -> @Sendable (
        @escaping @Sendable (AdoptUploadProgress) async -> Void
    ) async -> Result<AdoptUploadProgress, Error> {
        _ = medicationsStore // store snapshot no longer the definition source (W5)
        let uploader = StandaloneAdoptUploadService(
            api: api,
            medicationProvider: LocalMedicationDefinitionProvider(local: localRepo)
        )
        return { [weak localRepo, uploader] onProgress in
            guard let localRepo else {
                return .success(AdoptUploadProgress(completed: 0, total: 0))
            }
            do {
                let bundle = try await localRepo.allForBackfill()
                let progress = try await uploader.run(bundle: bundle, onProgress: onProgress)
                return .success(progress)
            } catch {
                return .failure(error)
            }
        }
    }
}
