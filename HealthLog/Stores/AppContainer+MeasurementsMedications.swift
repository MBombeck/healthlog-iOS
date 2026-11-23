import Foundation

// MARK: - Measurements + Medications store phase

extension AppContainer {
    /// Factory — constructs the `MeasurementsStore` + `MedicationsStore` VERBATIM
    /// from the prior inline `init` block (same args, same order, same captures),
    /// so the move is behaviour-identical. The `public let` handles stay on
    /// `AppContainer`; the post-construction wiring (badge recompute, delivery-
    /// prefs predicate, spotlight settle hooks) stays in `init` where it composes
    /// onto the live stores. `@MainActor` because the stores are
    /// `@MainActor @Observable`.
    @MainActor
    static func makeMeasurementsAndMedications(
        measurementsRepo: MeasurementsRepository,
        medicationsRepo: MedicationsRepository,
        healthKit: AnyHealthKitWriter?,
        undo: UndoCoordinator,
        celebration: CelebrationCoordinator,
        personalRecordsSnapshotBox: PersonalRecordsSnapshotBox,
        swr: SWRCoordinator,
        keychain: KeychainStoring,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry
    ) -> (measurements: MeasurementsStore, medications: MedicationsStore) {
        let measurements = MeasurementsStore(
            repo: measurementsRepo,
            healthKit: healthKit,
            undoCoordinator: undo,
            celebrationCoordinator: celebration,
            personalRecordsSnapshot: { [personalRecordsSnapshotBox] in personalRecordsSnapshotBox.records },
            swr: swr,
            // Read fresh per call so the per-user run-once marker
            // for the historical Apple-Health backfill follows the live session.
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )
        measurements.bindAuthenticatedSessionRegistry(authenticatedSessionRegistry)
        let medications = MedicationsStore(
            repo: medicationsRepo,
            swr: swr,
            undoCoordinator: undo
        )
        return (measurements, medications)
    }
}
