import Foundation

extension AppContainer {
    /// **v0.8.4 WWIDGET-2 — drive the Home / Lock-Screen widgets from the
    /// store.**
    ///
    /// Chains onto `MedicationsStore.onIntakesDidChange` (composing with
    /// any pre-existing closure — badge refresh, Live-Activity reconcile —
    /// so all fire) and refreshes the App Group widget snapshot + reloads
    /// the widget timelines whenever the medication schedule / today's
    /// intakes change. The actual mapping is the pure
    /// ``WidgetSnapshot/make(medications:serverIntakes:now:calendar:)``; this
    /// method is the thin glue that reads the live store arrays and hands
    /// them to the ``WidgetSnapshotWriter``.
    ///
    /// **Idempotent + cheap:** the writer re-encodes a tiny JSON blob and
    /// asks WidgetKit to reload by kind. Both are safe to call after every
    /// store load — WidgetKit coalesces rapid reloads itself.
    static func wireWidgetSnapshot(
        writer: WidgetSnapshotWriter,
        medicationsStore: MedicationsStore
    ) {
        let previous = medicationsStore.onIntakesDidChange
        medicationsStore.onIntakesDidChange = { [weak medicationsStore] in
            previous?()
            guard let medicationsStore else { return }
            writer.refresh(
                medications: medicationsStore.medications,
                derivedIntakes: medicationsStore.derivedTodayIntakes,
                serverCompliancePercent: aggregateServerCompliancePercent(medicationsStore)
            )
        }
    }

    /// **W-B183 coherence — aggregate the SERVER ledger adherence into the one
    /// account-level percentage the compliance widget's ring tracks.**
    ///
    /// The widget shows a single ring for the whole account, but the server's
    /// canonical compliance lives PER medication (`complianceCardSnapshots`,
    /// fetched from `GET /api/medications/{id}/compliance` — the same value the
    /// in-app card + `LedgerHistorySection` paint). We average the per-med
    /// SHORT-window server rate (the headline rate the card shows first) across
    /// the active medications that have a server value, rounded to an integer.
    ///
    /// Returns `nil` when no active medication has a server compliance value yet
    /// (cold cache / offline / PRN-only catalog) so the widget falls back to the
    /// today-count fraction instead of painting a recomputed number. We NEVER
    /// recompute or dedup compliance here — we only read + average the server's
    /// already-canonical per-med rates.
    private static func aggregateServerCompliancePercent(
        _ store: MedicationsStore
    ) -> Int? {
        let activeIDs = Set(store.medications.filter(\.active).map(\.id))
        let rates: [Int] = store.complianceCardSnapshots
            .filter { activeIDs.contains($0.key) }
            // The card's first (short) display row is the headline server rate;
            // `displayRows` already prefers the server cadence-scaled window and
            // falls back to the 7-day rate — the SAME row the in-app card paints.
            .compactMap { $0.value.displayRows.first?.rate }
        guard !rates.isEmpty else { return nil }
        let mean = Double(rates.reduce(0, +)) / Double(rates.count)
        return Int(mean.rounded())
    }

    /// **v0.10.0 W-Mood-B** — drive the interactive mood widget glance from
    /// the mood store. Chains onto `MoodStore.onEntriesDidChange` (composing
    /// with any pre-existing closure) and refreshes ONLY the mood field of the
    /// App Group snapshot (`refreshMood`) — the med refresh path owns dose +
    /// compliance. Maps the store's most-recent entry to the tiny
    /// `RecentMood` (score + timestamp only, no note/tags).
    static func wireMoodWidgetSnapshot(
        writer: WidgetSnapshotWriter,
        moodStore: MoodStore
    ) {
        let previous = moodStore.onEntriesDidChange
        moodStore.onEntriesDidChange = { [weak moodStore] in
            previous?()
            guard let moodStore else { return }
            let recent = moodStore.recents(limit: 1).first
            writer.refreshMood(
                recentMood: recent.map {
                    WidgetSnapshot.RecentMood(score: $0.score, loggedAt: $0.recordedAt)
                }
            )
        }
    }

    /// **v0.15 companion-#3** — drive the Personal Health Score ring widget from
    /// the dashboard score store. Chains onto `HealthScoreStore.onScoreDidChange`
    /// (composing with any pre-existing closure) and refreshes ONLY the score
    /// field of the App Group snapshot (`refreshHealthScore`). Mirrors the
    /// server score + band verbatim — never recomputes (server-first).
    static func wireHealthScoreWidgetSnapshot(
        writer: WidgetSnapshotWriter,
        healthScoreStore: HealthScoreStore
    ) {
        let previous = healthScoreStore.onScoreDidChange
        healthScoreStore.onScoreDidChange = { score in
            previous?(score)
            writer.refreshHealthScore(WidgetSnapshot.HealthScoreGlance.make(from: score))
        }
    }

    /// **v0.15 companion-#3** — drive the latest-measurement glance widget from
    /// the measurements store. Chains onto `MeasurementsStore.onRecentDidChange`
    /// (composing with any pre-existing closure) and refreshes ONLY the
    /// latest-measurement field of the App Group snapshot
    /// (`refreshLatestMeasurement`). The default metric is simply the most
    /// recent reading across all kinds (the newest `recordedAt`) — the
    /// glanceable "your last measurement", formatted exactly like the dashboard
    /// tile via the user's unit preferences.
    static func wireLatestMeasurementWidgetSnapshot(
        writer: WidgetSnapshotWriter,
        measurementsStore: MeasurementsStore,
        unitPreferences: @escaping @MainActor () -> UnitPreferences
    ) {
        let previous = measurementsStore.onRecentDidChange
        measurementsStore.onRecentDidChange = { recent in
            previous?(recent)
            let latest = recent.max { $0.recordedAt < $1.recordedAt }
            writer.refreshLatestMeasurement(
                WidgetSnapshot.LatestMeasurement.make(from: latest, units: unitPreferences())
            )
        }
    }

    /// **v0.10.0 W-Mood-B** — reconcile the iOS-local evening mood reminder on
    /// every mood entry change. Chains onto `MoodStore.onEntriesDidChange`
    /// (composing with the widget refresh wired above) so logging a mood while
    /// the app is open immediately cancels the pending reminder — it never
    /// double-fires with the server push. Reads the toggle + today-state
    /// lazily so a later settings change is honoured.
    static func wireMoodReminderReconcile(
        moodStore: MoodStore,
        notifications: NotificationService,
        settingsStore: SettingsStore
    ) {
        let previous = moodStore.onEntriesDidChange
        moodStore.onEntriesDidChange = { [weak moodStore, weak notifications, weak settingsStore] in
            previous?()
            guard moodStore != nil, let notifications, let settingsStore else { return }
            let enabled = settingsStore.profile?.moodReminderEnabled ?? false
            // v0.14.1 H2 — repeating trigger; the "logged today" suppression is a
            // foreground `willPresent` concern, not a re-arm input.
            Task {
                await notifications.reconcileMoodReminder(
                    enabled: enabled,
                    hour: MoodReminderPrefStore.hour()
                )
            }
        }
        // Build 272 — the toggle itself re-arms/cancels immediately. Until now
        // only the next foreground pass did, so "off" at 21:50 still fired at
        // 22:00 and "on" armed nothing until the app was reopened.
        settingsStore.onMoodReminderEnabledChanged = { [weak notifications] enabled in
            guard let notifications else { return }
            Task {
                await notifications.reconcileMoodReminder(
                    enabled: enabled,
                    hour: MoodReminderPrefStore.hour()
                )
            }
        }
    }

    /// Build 272 — re-arm the iOS-local evening reminder the moment the user
    /// picks a new hour on the Notifications screen (the store is screen-owned,
    /// so it is wired at construction, not in the composition root).
    func wireMoodReminderHourChanges(on store: NotificationsStore) {
        store.onMoodReminderHourChanged = { [weak self] hour in
            guard let self else { return }
            let enabled = settingsStore.profile?.moodReminderEnabled ?? false
            Task {
                await self.notifications.reconcileMoodReminder(enabled: enabled, hour: hour)
            }
        }
    }
}
