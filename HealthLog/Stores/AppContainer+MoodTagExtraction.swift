import Foundation

// MARK: - D-2 mood-tag-extraction wiring

extension AppContainer {
    /// Constructs `MoodStore` with the on-device tag-extraction service
    /// (D-2) wired through a `LiveFeatureFlagsService` adaptor. The actor
    /// reads the operator-flag state on every call rather than caching the
    /// snapshot at init — same pattern as `OnDeviceBriefingService` /
    /// `TrendObservationsService` (see `AppContainer+FeatureFlags.swift`).
    ///
    /// Factored out of `AppContainer.init` to keep the main initialiser
    /// under the SwiftLint `file_length` / `type_body_length` budget.
    static func makeMoodStore(
        repo: MoodRepository,
        healthKit: AnyHealthKitWriter?,
        featureFlagsStore: FeatureFlagsStore,
        undoCoordinator: UndoCoordinator
    ) -> MoodStore {
        let liveFlags = featureFlagsStore.liveService()
        let tagExtraction = MoodTagExtractionService(featureFlags: liveFlags)
        return MoodStore(
            repo: repo,
            healthKit: healthKit,
            tagExtraction: tagExtraction,
            undoCoordinator: undoCoordinator
        )
    }
}
