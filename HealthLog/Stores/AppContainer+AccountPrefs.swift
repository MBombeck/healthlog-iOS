import Foundation

extension AppContainer {
    /// **The account's zone and glucose unit, out of the app process.**
    ///
    /// The widget extension (and an intent the system runs there) cannot read the
    /// app's `UserDefaults.standard`; the paired watch cannot read anything on the
    /// phone. Both need the ACCOUNT's glucose unit to take a reading in, and the
    /// extension needs the account zone to name "today" (``ProfileDay``).
    ///
    /// - The zone already flows through ``ProfileTimeZoneBox/shared``, which
    ///   mirrors every push into ``SharedAccountPrefs``. This copies an existing
    ///   install's app-scoped mirror across once (the update path).
    /// - The glucose unit follows `SettingsStore.onGlucoseUnitChange` into the
    ///   same App-Group mirror and re-pushes the watch snapshot, and the value
    ///   the store holds right now is copied across at wiring time.
    ///
    /// Both writes are scoped to the signed-in account and no-op without one;
    /// the logout cascade clears the mirror (`performFullLocalLogout`).
    static func wireSharedAccountPrefs(
        settingsStore: SettingsStore,
        profileTimeZoneBox: ProfileTimeZoneBox,
        sharedPrefs: SharedAccountPrefs = .live,
        onGlucoseUnitChange: @escaping @MainActor () -> Void
    ) {
        settingsStore.onGlucoseUnitChange = { unit in
            sharedPrefs.setGlucoseUnit(unit)
            onGlucoseUnitChange()
        }
        sharedPrefs.setGlucoseUnit(settingsStore.glucoseUnit)
        // Unit system + weight unit, for Siri weight/temperature.
        settingsStore.onAccountUnitsChange = { units in
            sharedPrefs.setAccountUnits(system: units.system, weight: units.weight)
        }
        sharedPrefs.setAccountUnits(system: settingsStore.unitPreference, weight: settingsStore.weightUnit)
        profileTimeZoneBox.mirrorIntoSharedIfUnset()
    }
}

extension AppContainer {
    /// Logout: the watch snapshot (Privacy H4) and the App-Group account prefs
    /// (#115 B5 — zone and glucose unit, which the extension reads) belong to
    /// the account that is leaving. Runs after the store registry, whose
    /// settings reset still writes the prefs once more.
    /// The review prompt's counters go with them; its pacing stays.
    func resetDeviceMirrorsOnLogout() {
        resetWatchSnapshotOnLogout()
        SharedAccountPrefs.live.clear()
        ReviewPromptCoordinator.live.resetForSignOut()
        Self.removeAccountDoseFiles()
    }

    /// **R1 (10).** The App-Group files about this account's doses: the
    /// takes offered for undo, the doses resolved on this device, the widget
    /// tap outcome and its legacy marker, the relay Activity's name and the
    /// server reminders the extension saw. The next account on the device
    /// must start without any of them.
    static func removeAccountDoseFiles(containerURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier))
    {
        guard let containerURL else { return }
        for name in accountDoseFilenames {
            try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(name, isDirectory: false))
        }
    }

    static let accountDoseFilenames = [
        WidgetAppGroup.externalTakeLogFilename,
        ResolvedDoseLedger.filename,
        WidgetAppGroup.doseOutcomeFilename,
        WidgetAppGroup.pendingConfirmFilename,
        RelayLiveActivityLabel.filename,
        RelayDeliveredReminders.filename,
        PushDeliveryCounters.filename
    ]
}
