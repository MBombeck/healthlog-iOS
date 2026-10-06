import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

// MARK: - N1 — medication-reminder delivery (`clientManaged`)

extension AppContainer {
    /// Builds the coordinator over the container's own `APIClient`.
    ///
    /// The writer uses ``NotificationsRepository/setMedicationClientManaged(_:)``
    /// (guarded by `baseUpdatedAt`, echo returned); the sign-out release uses the
    /// fail-fast, retry-free variant. Both go through a repository of their own
    /// so the concurrency token they hold is not shared with a settings screen
    /// that may be mid-edit.
    static func makeMedicationReminderDelivery(
        api: APIClientProtocol,
        notificationsAuthorized: (@Sendable () async -> Bool)?
    ) -> MedicationReminderDeliveryCoordinator {
        let repo = NotificationsRepository(api: api)
        return MedicationReminderDeliveryCoordinator(
            defaults: .standard,
            notificationsAuthorized: notificationsAuthorized ?? Self.systemAllowsNotifications,
            writeClaim: { clientManaged in
                try await repo.setMedicationClientManaged(clientManaged)
            },
            releaseOnSignOut: {
                try await repo.releaseMedicationClientManagedOnSignOut()
            }
        )
    }

    /// Whether iOS shows this app's notifications at all. `.provisional` and
    /// `.ephemeral` deliver (quietly), exactly as an APNs push would be
    /// delivered on this device; `.denied` and `.notDetermined` do not.
    @Sendable
    nonisolated static func systemAllowsNotifications() async -> Bool {
        #if canImport(UserNotifications)
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied, .notDetermined:
                return false
            @unknown default:
                return false
            }
        #else
            return false
        #endif
    }

    /// Feeds the coordinator its three inputs and hands it the sign-out step.
    ///
    /// - the `/me` reading from ``SettingsStore`` (lease attached there);
    /// - every medication snapshot, attributed to the keychain user at that
    ///   moment, chained onto `onMedicationsDidChange` without displacing the
    ///   delivery-prefs and Live Activity consumers already on it;
    /// - ``AuthStore/onBeforeRemoteSignOut`` for the release, with the owner
    ///   whose credentials are still present.
    ///
    /// The permission is read inside each evaluation, and an evaluation runs
    /// after every medication load — the foreground pass loads medications, so
    /// a permission changed in the Settings app is picked up on the way back.
    func wireMedicationReminderDelivery() {
        let coordinator = medicationReminderDelivery
        let keychain = keychain
        settingsStore.onMedicationReminderServerDelivery = { [weak coordinator] state, lease in
            coordinator?.noteServerDelivery(state, lease: lease)
        }
        let previous = medicationsStore.onMedicationsDidChange
        medicationsStore.onMedicationsDidChange = { [weak coordinator] medications in
            previous?(medications)
            coordinator?.noteMedications(
                medications,
                ownerID: keychain.getString(forKey: KeychainKey.userID)
            )
        }
        authStore.onBeforeRemoteSignOut = { [weak coordinator] in
            await coordinator?.releaseForSignOut(ownerID: keychain.getString(forKey: KeychainKey.userID))
        }
    }
}
