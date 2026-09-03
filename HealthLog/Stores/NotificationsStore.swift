import Foundation

/// MainActor + @Observable Store für den Settings → Benachrichtigungen-
/// Screen. Optimistic-toggle: UI flippt sofort, Server-PUT folgt; bei
/// Fehler wird der Toggle revertiert + ein \`HLError\` gesetzt damit die
/// Screen einen Toast anzeigen kann.
///
/// **SWR adoption (PA5 Bottleneck #2, v0.5.x):** preferences (the bulk
/// of the screen) now ride the SWR cache via `.notificationsPreferences`
/// (`staleAfter: 5 * 60`). Cold-tab-open previously fired two fresh
/// network requests with zero cache-paint capability — now the
/// previous-session prefs paint sub-100ms while the revalidate rides
/// behind the curtain. The status endpoint stays direct-fetch because
/// it's a "nice to have" surface whose failures must not block prefs
/// AND it has no dedicated cache key (per-channel reliability state is
/// inherently fresh-or-not). Direct-fetch path preserved for unit tests
/// constructing the store without a coordinator.
@MainActor
@Observable
public final class NotificationsStore {
    public private(set) var payload: NotificationPreferencesPayload?
    public private(set) var status: NotificationStatusPayload?
    public private(set) var isLoading: Bool = false
    public var error: HLError?
    /// Set when the visible preferences payload was served from cache
    /// (SWR `.cached` arm). Drives the "showing cached" affordance.
    public private(set) var isShowingStaleCache: Bool = false
    /// Channel-IDs that currently have a `retry()` POST in flight.
    /// REG-12 (v0.5.6): the screen uses this to disable the retry
    /// button + show a `ProgressView` while the server clears the
    /// cooldown so the operator can't double-tap. Tracked as a Set
    /// rather than a single flag because the user may eventually own
    /// multiple paused channels (web-push, ntfy, telegram) and the UI
    /// shouldn't gate one retry on another.
    public private(set) var retryingChannelIds: Set<String> = []
    /// Channel-IDs whose most-recent `retry()` call returned 2xx and we
    /// haven't yet auto-cleared the success badge. Drives the inline
    /// "Wieder aktiv" confirmation row so the operator gets immediate
    /// feedback instead of having to interpret the next status refresh.
    /// Cleared automatically ~3 s after the status refresh lands.
    public private(set) var lastRetrySucceededIds: Set<String> = []

    /// **MED-4 / AUDIT-PARITY C3** — the configured low-supply runway threshold
    /// in days (1–60), or `nil` when the alert is off. Initialised from the
    /// local mirror so the Settings card reflects the last-known value
    /// immediately, then refreshed from the server `medication` block on load.
    public private(set) var lowStockRunwayDays: Int? = LowStockRunwayPrefStore.days()

    /// **W-B189 / #23** — whether the preventive-care (Vorsorge) push is
    /// **suppressed** (`notificationPrefs.measurementReminder.clientManaged`).
    /// **CU-26: `true` means muted, not enrolled** — see the type docblock.
    /// Initialised from the local mirror so the Settings toggle reflects the
    /// last-known value immediately, then refreshed from the server
    /// `measurementReminder` block on load. Default off (opt-in).
    public private(set) var measurementReminderClientManaged: Bool =
        MeasurementReminderPrefStore.clientManaged()

    private let repo: NotificationsRepository
    private let swr: SWRCoordinator?

    /// Build 272 — announced right after the local hour mirror is written, so
    /// the composition root can re-arm the iOS-local evening reminder at the
    /// new hour immediately. Wired in `AppContainer+Wiring`.
    public var onMoodReminderHourChanged: ((Int) -> Void)?

    public init(repo: NotificationsRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    public func load() async {
        // Status is always direct-fetched (no cache key, best-effort).
        // Run it in parallel with the prefs stream so a slow status
        // endpoint doesn't gate the cached prefs paint.
        async let statusTask: () = loadStatus()
        async let prefsTask: () = loadPreferences()
        async let moodHourTask: () = loadMoodReminderHour()
        _ = await (statusTask, prefsTask, moodHourTask)
    }

    /// **AUDIT-G A1-B1 (v0.11)** — cold-read the server-canonical mood-reminder
    /// hour from `GET /api/auth/me/notification-prefs` (the source of truth —
    /// `/api/notifications/preferences` carries no `mood` block) and refresh the
    /// local mirror so the Settings picker shows the server value on a fresh
    /// screen open instead of the local default 22. Best-effort + fail-open:
    /// any error leaves the existing mirror untouched.
    private func loadMoodReminderHour() async {
        do {
            let prefs = try await repo.authNotificationPrefs()
            if let hour = prefs.moodReminderHour {
                MoodReminderPrefStore.setHour(hour)
            }
            // MED-4 / C3 — cold-read the low-supply runway threshold from the
            // same auth-prefs payload (the only endpoint that carries the
            // `medication` block) and mirror it so med screens render the runway
            // before this screen is opened. Only writes when the server actually
            // surfaced the `medication` block — a legacy/drifted server that
            // omits it leaves the local mirror untouched.
            if prefs.medication != nil {
                lowStockRunwayDays = prefs.lowStockRunwayDays
                LowStockRunwayPrefStore.setDays(prefs.lowStockRunwayDays)
            }
            // W-B189 / #23 — cold-read the preventive-care reminder opt-in from
            // the same auth-prefs payload (the only endpoint that carries the
            // `measurementReminder` block) and mirror it. Only writes when the
            // server actually surfaced the block — a legacy/drifted server that
            // omits it leaves the local mirror (default off) untouched.
            if let clientManaged = prefs.measurementReminderClientManaged {
                measurementReminderClientManaged = clientManaged
                MeasurementReminderPrefStore.setClientManaged(clientManaged)
            }
        } catch {
            HLLog.notifications.warning(
                "Mood-Reminder-Stunde cold-read fehlgeschlagen — lokaler Mirror bleibt. err=\(error.localizedDescription)"
            )
        }
    }

    private func loadPreferences() async {
        // 14-06 — see `MedicationsStore.load`.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .notifications)
            }
            isLoading = false
        }
        guard let swr else {
            await loadPreferencesDirect()
            return
        }
        let repo = repo
        for await state in await swr.observe(
            .notificationsPreferences,
            decoding: NotificationPreferencesPayload.self,
            fetch: { try await repo.preferences() }
        ) {
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                payload = value
                mirrorMoodReminderHour(value)
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                payload = value
                mirrorMoodReminderHour(value)
                isShowingStaleCache = false
                isLoading = false
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown {
                    payload = lastKnown
                    mirrorMoodReminderHour(lastKnown)
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
                HLLog.notifications.error("Preferences laden fehlgeschlagen: \(err.localizedDescription)")
            }
        }
    }

    /// Direct-fetch path used when `swr` is nil (unit tests). Kept on
    /// the original single-emit shape so existing test expectations hold.
    private func loadPreferencesDirect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await repo.preferences()
            payload = value
            mirrorMoodReminderHour(value)
            error = nil
        } catch let err as HLError {
            error = err
            HLLog.notifications.error("Preferences laden fehlgeschlagen: \(err.localizedDescription)")
        } catch {
            self.error = .unknown(error.localizedDescription)
            HLLog.notifications.error("Preferences laden fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// **v0.10.0 W-Mood-B** — mirror the server's
    /// `notificationPrefs.mood.reminderHour` into the local
    /// ``MoodReminderPrefStore`` whenever a payload lands, so the foreground
    /// reminder scheduler always reads the server-authoritative hour even
    /// before this screen is opened. Only writes when the server actually
    /// surfaced a value (legacy servers omit it → keep the local default).
    private func mirrorMoodReminderHour(_ payload: NotificationPreferencesPayload) {
        if let hour = payload.mood?.reminderHour {
            MoodReminderPrefStore.setHour(hour)
        }
    }

    /// **v0.10.0 W-Mood-B** — set the evening mood-reminder hour (0–23).
    /// Optimistically mirrors locally (so the foreground scheduler + the
    /// Settings UI reflect it immediately), then PATCHes the server. On a
    /// server failure the local mirror stays (the iOS-local reminder is the
    /// load-bearing path); the error surfaces for a toast.
    public func setMoodReminderHour(_ hour: Int) async {
        MoodReminderPrefStore.setHour(hour)
        // Build 272 — the local mirror is the load-bearing path for the iOS
        // repeating trigger, so re-arm right away (not on the next foreground).
        onMoodReminderHourChanged?(hour)
        do {
            try await repo.setMoodReminderHour(hour)
            error = nil
        } catch let err as HLError {
            error = err
            HLLog.notifications.error("Mood-Reminder-Stunde speichern fehlgeschlagen: \(err.localizedDescription)")
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    /// **MED-4 / AUDIT-PARITY C3** — set the low-supply runway threshold
    /// (1–60 days, or `nil` to turn the alert off). Optimistically mirrors
    /// locally (so the medication card runway + the Settings UI reflect it
    /// immediately), then PATCHes the server. On a server failure the PATCH
    /// rides the outbox (idempotency-keyed); the local mirror stays so the
    /// runway display is consistent, and the error surfaces for a toast.
    public func setLowStockRunwayDays(_ days: Int?) async {
        let clamped = days.map { max(medicationLowStockRunwayMin, min(medicationLowStockRunwayMax, $0)) }
        lowStockRunwayDays = clamped
        LowStockRunwayPrefStore.setDays(clamped)
        do {
            try await repo.setLowStockRunwayDays(clamped)
            error = nil
        } catch let err as HLError {
            error = err
            HLLog.notifications.error("Low-Stock-Schwelle speichern fehlgeschlagen: \(err.localizedDescription)")
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    /// **W-B189 / #23** — set the preventive-care (Vorsorge) reminder opt-in.
    /// Optimistically mirrors locally (so the Settings toggle reflects it
    /// immediately), then PATCHes the server. On a server failure the PATCH
    /// rides the outbox (idempotency-keyed); the local mirror stays so the
    /// toggle is consistent, and the error surfaces for a toast.
    public func setMeasurementReminderClientManaged(_ enabled: Bool) async {
        measurementReminderClientManaged = enabled
        MeasurementReminderPrefStore.setClientManaged(enabled)
        do {
            try await repo.setMeasurementReminderClientManaged(enabled)
            error = nil
        } catch let err as HLError {
            error = err
            HLLog.notifications.error(
                "Measurement-reminder opt-in speichern fehlgeschlagen: \(err.localizedDescription)"
            )
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    /// The current evening mood-reminder hour for the Settings UI: the
    /// server-surfaced value if present, else the local mirror / default.
    public var moodReminderHour: Int {
        payload?.mood?.reminderHour.map { max(0, min(23, $0)) }
            ?? MoodReminderPrefStore.hour()
    }

    /// Status endpoint — per-channel reliability state. No cache key
    /// (see type-level doc). Failures only surface to logs; the screen
    /// renders happily with `status == nil` (no last-delivery line).
    private func loadStatus() async {
        do {
            status = try await repo.status()
        } catch {
            HLLog.notifications.warning(
                "Status-Endpoint laden fehlgeschlagen — letzte Zustellungs-Zeile bleibt leer. err=\(error.localizedDescription)"
            )
        }
    }

    /// Per-channel status lookup. Returns `nil` when the status endpoint
    /// hasn't been hydrated yet (network failure, fresh launch, …). Callers
    /// should render a "—" line in that case rather than hiding the row.
    public func channelStatus(id: String) -> NotificationChannelStatus? {
        status?.channels.first(where: { $0.id == id })
    }

    /// Optimistic Toggle. Ändert \`payload.preferences\` sofort + ruft
    /// \`repo.setPreference\` async auf. Bei Fehler wird der Wert revertiert.
    public func toggle(channelId: String, eventType: String, to newValue: Bool) async {
        guard var current = payload else { return }
        let previous = current.preferences

        // Optimistic local update.
        if let idx = current.preferences.firstIndex(where: { $0.channelId == channelId && $0.eventType == eventType }) {
            current = NotificationPreferencesPayload(
                channels: current.channels,
                preferences: current.preferences.replacing(
                    at: idx,
                    with: NotificationPreference(channelId: channelId, eventType: eventType, enabled: newValue)
                ),
                eventTypes: current.eventTypes
            )
        } else {
            current = NotificationPreferencesPayload(
                channels: current.channels,
                preferences: current.preferences + [NotificationPreference(channelId: channelId, eventType: eventType, enabled: newValue)],
                eventTypes: current.eventTypes
            )
        }
        payload = current

        do {
            try await repo.setPreference(channelId: channelId, eventType: eventType, enabled: newValue)
            error = nil
            // Refresh the cache with the optimistic payload so the next
            // observe sees the latest writer-truth (next tab-open hits the
            // cache hot). Cheap — single SwiftData write-through.
            if let swr {
                await swr.writeThrough(.notificationsPreferences, value: current)
            }
        } catch let err as HLError {
            // Revert.
            payload = NotificationPreferencesPayload(
                channels: current.channels,
                preferences: previous,
                eventTypes: current.eventTypes
            )
            error = err
            HLLog.notifications.error("Toggle PUT fehlgeschlagen — revert. err=\(err.localizedDescription)")
        } catch {
            payload = NotificationPreferencesPayload(
                channels: current.channels,
                preferences: previous,
                eventTypes: current.eventTypes
            )
            self.error = .unknown(error.localizedDescription)
            HLLog.notifications.error("Toggle PUT fehlgeschlagen — revert. err=\(error.localizedDescription)")
        }
    }

    /// Re-enable an auto-disabled / paused channel from the Settings UI.
    ///
    /// REG-12 (v0.5.6): the previous Notifications screen surfaced the
    /// "channel paused" state purely as text — no affordance to clear
    /// the cooldown. Users hit "kann ich nicht manuell triggern" and
    /// had to wait for the dispatcher's next retry slot (≤ 2 h on the
    /// 4th transient failure, never on a hard reject). This method
    /// wraps `POST /api/notifications/status` so the row's "Erneut
    /// versuchen" button can flip `enabled=true` + clear
    /// `nextRetryAt`, then immediately reloads `status` so the badge
    /// re-paints as `.active`.
    ///
    /// Concurrency model: the channel-id lives in `retryingChannelIds`
    /// while the POST + status reload are in flight so the view can
    /// disable the button + show a spinner. On 2xx we briefly add the
    /// id to `lastRetrySucceededIds` (auto-cleared after ~3 s) so the
    /// row can render an inline "Wieder aktiv" confirmation. On error
    /// the standard `error: HLError?` slot is set so the screen's
    /// existing alert binding surfaces the failure.
    public func retry(channelId: String) async {
        // Re-entry guard: a double-tap from a fast operator would
        // otherwise queue two POSTs racing against the status reload.
        guard !retryingChannelIds.contains(channelId) else { return }
        retryingChannelIds.insert(channelId)
        defer { retryingChannelIds.remove(channelId) }

        do {
            try await repo.reEnableChannel(channelId: channelId)
            // Refresh the per-channel status row so the badge flips from
            // `paused` → `active` and the failure counter resets. Done
            // serially after the POST so the badge can't briefly show
            // the stale `paused` state in between.
            await loadStatus()
            error = nil
            lastRetrySucceededIds.insert(channelId)
            // Auto-clear the success confirmation after 3 s so the row
            // settles back into its steady-state. Captured weakly so the
            // store can be released while the sleep is pending.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.lastRetrySucceededIds.remove(channelId)
            }
            HLLog.notifications.info("Channel re-enable OK — id=\(channelId, privacy: .private)")
        } catch let err as HLError {
            error = err
            HLLog.notifications.error(
                "Channel re-enable fehlgeschlagen — id=\(channelId, privacy: .private) err=\(err.localizedDescription)"
            )
        } catch {
            self.error = .unknown(error.localizedDescription)
            HLLog.notifications.error(
                "Channel re-enable fehlgeschlagen — id=\(channelId, privacy: .private) err=\(error.localizedDescription)"
            )
        }
    }

    public func clearOnLogout() {
        payload = nil
        status = nil
        error = nil
        isShowingStaleCache = false
        retryingChannelIds.removeAll()
        lastRetrySucceededIds.removeAll()
    }
}

private extension Array {
    func replacing(at index: Int, with element: Element) -> [Element] {
        var copy = self
        copy[index] = element
        return copy
    }
}
