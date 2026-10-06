import Foundation

// MARK: - D-2 mood-tag-extraction wiring

extension AppContainer {
    /// Constructs `MoodStore` with the on-device tag-extraction service
    /// (D-2) reading the live AI capability gate on every call (#115 · 0.2:
    /// `statusText.onDeviceAllowed`) — same pattern as
    /// `OnDeviceBriefingService` / `TrendObservationsService`.
    ///
    /// Factored out of `AppContainer.init` to keep the main initialiser
    /// under the SwiftLint `file_length` / `type_body_length` budget.
    static func makeMoodStore(
        repo: MoodRepository,
        healthKit: AnyHealthKitWriter?,
        aiCapabilities: any AICapabilityReading,
        undoCoordinator: UndoCoordinator
    ) -> MoodStore {
        let tagExtraction = MoodTagExtractionService(aiCapabilities: aiCapabilities)
        return MoodStore(
            repo: repo,
            healthKit: healthKit,
            tagExtraction: tagExtraction,
            undoCoordinator: undoCoordinator
        )
    }
}
