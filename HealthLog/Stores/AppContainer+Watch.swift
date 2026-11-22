import Foundation

extension AppContainer {
    /// **Wire the watchOS companion onto the live stores.**
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
        // WW/F4 — the phone can accept a watch write when it's signed in (has a
        // server token).
        // #9 — every snapshot names the account it was built for, and an
        // action tapped on another account's snapshot is dropped.
        coordinator.ownerHashProvider = { WatchOwnerHash.of(userID: keychain.getString(forKey: KeychainKey.userID)) }
        coordinator.snapshotProvider = { [weak medicationsStore, weak moodStore, weak coordinator] in
            guard let medicationsStore else { return .placeholder }
            let hasToken = keychain.getString(forKey: KeychainKey.authToken) != nil
            let canLog = hasToken
            guard WatchSnapshotPushGate.allowsPush(
                signedIn: canLog,
                hasLoadedMedications: medicationsStore.hasLoadedMedications,
                hasLoadedTodayList: coordinator?.hasSeenTodayIntakes ?? false
            ) else { return nil }
            return watchSnapshot(
                medicationsStore: medicationsStore, moodStore: moodStore, coordinator: coordinator, signedIn: canLog
            )
        }

        coordinator.onMarkIntake = { [weak medicationsStore] intakeId, status, at in
            guard let medicationsStore else { return .failed }
            return await handleWatchMark(intakeId: intakeId, status: status.intakeStatus, at: at, in: medicationsStore)
        }

        coordinator.onLogMood = { [weak moodStore] score, at in
            guard let moodStore else { return .failed }
            let result = await moodStore.logReturningOutcome(score: score, tags: [], note: nil, recordedAt: at)
            return result.outcome.watchAckOutcome
        }

        // Quick-capture a manual measurement from the wrist through the SAME
        // server-first capture path the app's `MeasureSheet` uses (server write
        // + Outbox + HK mirror). The watch never holds a token or talks to the
        // server itself — it just hands the phone a kind + value.
        coordinator.onLogMeasurement = { [weak measurementsStore] kind, value, secondary, at in
            guard let measurementsStore else { return .failed }
            let measured = kind.measurementValue(value: value, secondary: secondary)
            let outcome = await measurementsStore.captureReturningOutcome(
                kind: kind.metricKind,
                value: measured,
                note: nil,
                recordedAt: at
            )
            // A worrying value from the wrist keeps the review prompt quiet too.
            ReviewPromptCoordinator.live.noteMeasurement(
                kind: kind.metricKind, value: measured, glucoseContext: nil, outcome: outcome
            )
            return outcome.watchAckOutcome
        }

        // WW/F7 — re-push the snapshot to the watch whenever the medication
        // intakes change, but COALESCE a burst (e.g. "mark all taken") into a
        // single push (compose onto the existing widget-refresh closure).
        let prevIntakes = medicationsStore.onIntakesDidChange
        medicationsStore.onIntakesDidChange = { [weak coordinator] in
            prevIntakes?()
            coordinator?.hasSeenTodayIntakes = true
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

    /// **A dose marked on the wrist (#9, D3 #10).**
    ///
    /// The watch names the dose by the id of the snapshot it was tapped on. A
    /// durable transfer can wake the app before today's list has loaded (or
    /// after it was replaced), and the store's quick mark then found no row
    /// and answered "saved" without writing anything. The list is loaded once
    /// more; a dose still not in it is answered `failed`, so the wrist says
    /// "couldn't save" instead of showing a check the server never got.
    /// Placeholder ids carry their own medication and slot and need no row.
    ///
    /// `at` is the tap time: the dose is recorded as taken then, not when the
    /// transfer arrived.
    @MainActor
    static func markWatchIntake(
        intakeId: String,
        status: IntakeStatus,
        at: Date,
        in store: MedicationsStore
    ) async -> MedicationsStore.WriteOutcome {
        await markWatchIntakeReturningUndo(intakeId: intakeId, status: status, at: at, in: store).outcome
    }

    /// A dose marked on the wrist: written through the phone's store, and a
    /// take is offered for undo on the next open, bound to the row it wrote
    /// (#188 (7), R1 (1)).
    @MainActor
    static func handleWatchMark(
        intakeId: String,
        status: IntakeStatus,
        at: Date,
        in store: MedicationsStore
    ) async -> WatchAckOutcome {
        let dose = store.derivedTodayIntakes.first { $0.id == intakeId }
        let result = await markWatchIntakeReturningUndo(intakeId: intakeId, status: status, at: at, in: store)
        if status == .taken, let dose, result.outcome == .success || result.outcome == .queued {
            ExternalTakeLog().record(
                medicationId: dose.medicationId,
                scheduledFor: dose.scheduledAt,
                source: .watch,
                binding: result.undo.flatMap(Self.externalTakeBinding(for:))
            )
        }
        return result.outcome.watchAckOutcome
    }

    /// ``markWatchIntake`` plus the reversal descriptor of the row it wrote,
    /// so the wrist take's undo offer binds to that row (R1 (1)).
    @MainActor
    static func markWatchIntakeReturningUndo(
        intakeId: String,
        status: IntakeStatus,
        at: Date,
        in store: MedicationsStore
    ) async -> (outcome: MedicationsStore.WriteOutcome, undo: MedicationsStore.IntakeMarkUndo?) {
        let isPlaceholder = intakeId.hasPrefix(MedicationIntake.synthesizedPlaceholderPrefix)
        if !isPlaceholder, !store.todayIntakes.contains(where: { $0.id == intakeId }) {
            await store.load(force: true)
            guard store.todayIntakes.contains(where: { $0.id == intakeId }) else {
                HLLog.watch.warning("watch dose not in today's list after a reload — not marked")
                return (.failed(.unknown("watch dose not found")), nil)
            }
        }
        return await store.markIntakeQuickReturningUndo(intakeId: intakeId, status: status, now: min(at, Date()))
    }

    /// **Feed the watch-face score-ring +
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
        coordinator.glucoseUnitProvider = { unitPreferences().glucose }
        coordinator.scoreProvider = { [weak healthScoreStore] in
            WatchSnapshot.HealthScoreGlance.make(from: healthScoreStore?.score)
        }
        coordinator.latestMeasurementProvider = { [weak measurementsStore] in
            // See the widget glance: the complication shows the
            // newest reading this build can name, never the sentinel.
            let latest = Measurement.latestNamedReading(in: measurementsStore?.recent ?? [])
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

    /// **Privacy H4 — wipe the watch on logout / account deletion.**
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

    /// The snapshot the watch renders. "Today" is the account's day, the same
    /// zone the medication list is anchored on, for doses and mood alike.
    private static func watchSnapshot(
        medicationsStore: MedicationsStore,
        moodStore: MoodStore?,
        coordinator: WatchSessionCoordinator?,
        signedIn: Bool
    ) -> WatchSnapshot {
        let now = Date.now
        let calendar = WatchSnapshot.dayCalendar(accountTimeZone: medicationsStore.profileTimeZone)
        return WatchSnapshot.make(
            medications: medicationsStore.medications,
            derivedIntakes: medicationsStore.derivedTodayIntakes,
            recentMoods: moodStore?.entries ?? [],
            moodCountToday: moodStore?.todayCount(now: now, calendar: calendar) ?? 0,
            signedIn: signedIn,
            // Fold the latest score + newest
            // measurement glances (wired lazily by `wireWatchGlances` after
            // those stores exist) into the snapshot the watch complications
            // read. Absent when not yet wired → complications show em-dash.
            healthScore: coordinator?.scoreProvider?(),
            latestMeasurement: coordinator?.latestMeasurementProvider?(),
            // The wrist enters glucose in the account's unit.
            glucoseUnit: coordinator?.glucoseUnitProvider?() ?? .mgdL,
            ownerHash: coordinator?.ownerHashProvider?(),
            now: now,
            calendar: calendar
        )
    }
}

extension AppContainer {
    /// R1 (1) — what ties a take from the wrist to its row: the real row it
    /// marked, or the row (or key) the slot's first write created.
    nonisolated static func externalTakeBinding(for undo: MedicationsStore.IntakeMarkUndo) -> ExternalTakeLog.Binding? {
        let binding = switch undo.kind {
        case let .realIntake(snapshot):
            ExternalTakeLog.Binding(rowID: snapshot.id, idempotencyKey: nil)
        case let .synthesized(_, _, _, serverEventID, _):
            ExternalTakeLog.Binding(rowID: serverEventID, idempotencyKey: undo.idempotencyKey)
        }
        return binding.isEmpty ? nil : binding
    }
}
