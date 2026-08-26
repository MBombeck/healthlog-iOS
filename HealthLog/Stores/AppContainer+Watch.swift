import Foundation

extension AppContainer {
    /// **v0.12 P2 — wire the watchOS companion onto the live stores.**
    ///
    /// The watch is a thin remote: it sends `WatchAction`s the phone funnels
    /// into the EXISTING server-first store methods, and renders a
    /// `WatchSnapshot` the phone re-pushes on every relevant store change.
    /// This method:
    ///   1. teaches the coordinator how to build the current snapshot
    ///      (`snapshotProvider`),
    ///   2. wires the two action closures onto `MedicationsStore.mark` +
    ///      `MoodStore.log` (canonical paths — no parallel write path),
    ///   3. chains a re-push onto `onIntakesDidChange` / `onEntriesDidChange`
    ///      (composing with the widget refresh already on those slots), so a
    ///      mark made anywhere — phone, widget, watch — loops a fresh snapshot
    ///      back to the watch,
    ///   4. activates the session (last, after the closures exist).
    static func wireWatchCompanion(
        coordinator: WatchSessionCoordinator,
        medicationsStore: MedicationsStore,
        moodStore: MoodStore,
        measurementsStore: MeasurementsStore,
        keychain: KeychainStoring
    ) {
        // WW/F4 — the phone can accept a watch write when it's signed-in
        // (has a server token) OR running standalone (a no-server user has a
        // working LOCAL write path). The watch's `signedIn`/`canLog` flag is
        // this OR, so a standalone operator can log mood / mark intakes instead
        // of being told to "sign in on iPhone." Read live off UserDefaults via
        // the same `@Sendable` predicate the standalone read-union gate uses.
        let isStandalone = standaloneModePredicate()
        coordinator.snapshotProvider = { [weak medicationsStore, weak moodStore, weak coordinator] in
            guard let medicationsStore else { return .placeholder }
            let hasToken = keychain.getString(forKey: KeychainKey.authToken) != nil
            let canLog = hasToken || isStandalone()
            return WatchSnapshot.make(
                medications: medicationsStore.medications,
                derivedIntakes: medicationsStore.derivedTodayIntakes,
                latestMood: moodStore?.recents(limit: 1).first,
                moodCountToday: moodStore?.todayCount() ?? 0,
                signedIn: canLog,
                // v0.15.2 W-WATCH-COMPLICATIONS — fold the latest score + newest
                // measurement glances (wired lazily by `wireWatchGlances` after
                // those stores exist) into the snapshot the watch complications
                // read. Absent when not yet wired → complications show em-dash.
                healthScore: coordinator?.scoreProvider?(),
                latestMeasurement: coordinator?.latestMeasurementProvider?()
            )
        }

        coordinator.onMarkIntake = { [weak medicationsStore] intakeId, status in
            guard let medicationsStore else { return .failed }
            let outcome = await medicationsStore.markIntakeQuick(
                intakeId: intakeId, status: status.intakeStatus
            )
            return outcome.watchAckOutcome
        }

        coordinator.onLogMood = { [weak moodStore] score in
            guard let moodStore else { return .failed }
            let result = await moodStore.logReturningOutcome(score: score, tags: [], note: nil)
            return result.outcome.watchAckOutcome
        }

        // Quick-capture a manual measurement from the wrist through the SAME
        // server-first capture path the app's `MeasureSheet` uses (server write
        // + Outbox + HK mirror). The watch never holds a token or talks to the
        // server itself — it just hands the phone a kind + value.
        coordinator.onLogMeasurement = { [weak measurementsStore] kind, value, secondary in
            guard let measurementsStore else { return .failed }
            let outcome = await measurementsStore.captureReturningOutcome(
                kind: kind.metricKind,
                value: kind.measurementValue(value: value, secondary: secondary),
                note: nil
            )
            return outcome.watchAckOutcome
        }

        // WW/F7 — re-push the snapshot to the watch whenever the medication
        // intakes change, but COALESCE a burst (e.g. "mark all taken") into a
        // single push (compose onto the existing widget-refresh closure).
        let prevIntakes = medicationsStore.onIntakesDidChange
        medicationsStore.onIntakesDidChange = { [weak coordinator] in
            prevIntakes?()
            coordinator?.pushCurrentCoalesced()
        }

        // …and whenever the mood entries change.
        let prevMood = moodStore.onEntriesDidChange
        moodStore.onEntriesDidChange = { [weak coordinator] in
            prevMood?()
            coordinator?.pushCurrentCoalesced()
        }

        coordinator.activate()
    }

    /// **v0.15.2 W-WATCH-COMPLICATIONS — feed the watch-face score-ring +
    /// latest-measurement complications.**
    ///
    /// Runs AFTER `wireWatchCompanion` (the watch session is wired early in
    /// `AppContainer` init, before the score / settings stores exist). Teaches
    /// the coordinator to read the latest server health score + the newest
    /// measurement (formatted via the live unit preferences) when it builds a
    /// snapshot, and chains a coalesced re-push onto each store's change slot so
    /// a fresh score / measurement loops a new snapshot to the watch.
    ///
    /// Mirrors the server value verbatim (never recomputes the score) and reuses
    /// the SAME glance formatters the phone widgets use — one formatting path, no
    /// drift between phone widget and watch complication.
    static func wireWatchGlances(
        coordinator: WatchSessionCoordinator,
        healthScoreStore: HealthScoreStore,
        measurementsStore: MeasurementsStore,
        unitPreferences: @escaping @MainActor () -> UnitPreferences
    ) {
        coordinator.scoreProvider = { [weak healthScoreStore] in
            WatchSnapshot.HealthScoreGlance.make(from: healthScoreStore?.score)
        }
        coordinator.latestMeasurementProvider = { [weak measurementsStore] in
            let latest = measurementsStore?.recent.max { $0.recordedAt < $1.recordedAt }
            return WatchSnapshot.LatestMeasurement.make(from: latest, units: unitPreferences())
        }

        let prevScore = healthScoreStore.onScoreDidChange
        healthScoreStore.onScoreDidChange = { [weak coordinator] score in
            prevScore?(score)
            coordinator?.pushCurrentCoalesced()
        }

        let prevRecent = measurementsStore.onRecentDidChange
        measurementsStore.onRecentDidChange = { [weak coordinator] recent in
            prevRecent?(recent)
            coordinator?.pushCurrentCoalesced()
        }
    }

    /// **Privacy H4 (audit-v0162) — wipe the watch on logout / account deletion.**
    ///
    /// `performFullLocalLogout` previously had NO WatchConnectivity step, so the
    /// previous user's medication names / doses / mood / latest measurement
    /// lingered in the watch app and its complications (persisted in the watch's
    /// App Group `watch-snapshot.json`) until user B signed in and the first
    /// fresh snapshot landed. `MedicationsStore.clearOnLogout` empties its arrays
    /// WITHOUT firing `onIntakesDidChange`, so the change-driven re-push never
    /// fires — this explicit reset is the robust fix and needs no change to the
    /// (out-of-scope) store internals.
    ///
    /// Pushes the PHI-free placeholder on every logout reason. Best-effort — the
    /// coordinator swallows WC failures so the cascade always proceeds.
    func resetWatchSnapshotOnLogout() {
        watchSession.pushLogoutReset()
    }
}
