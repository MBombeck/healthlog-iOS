import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// `NotificationsScreen` interaction logic (channel toggles, test pushes,
/// reminder edits). Extracted from `NotificationsScreen.swift` (file_length
/// discipline — pure move, no behaviour change).
extension NotificationsScreen {
    // MARK: - Logic

    func visibleChannels(_ all: [NotificationChannel]) -> [NotificationChannel] {
        // **Build 6.5 — full channel matrix.** Until v0.14.x this list was
        // APNs-only; the ntfy / Telegram / Webhook channels only had their own
        // config cards (`serviceChannelCards`) and no per-event routing. The
        // server, though, keeps a `NotificationPreference` row per (channel ×
        // event) for EVERY channel type (`api/notifications/preferences`), so a
        // user who configured Telegram / ntfy / Webhook / Email could not choose
        // WHICH events reach it from iOS. We now surface every server-returned
        // channel EXCEPT `WEB_PUSH`, which is a browser channel with no iOS
        // meaning (APNs covers native push). Order is stable: APNs first, then
        // the server's order for the rest.
        all.filter { $0.type != "WEB_PUSH" }
            .sorted { lhs, rhs in
                let lr = Self.channelRank(lhs.type)
                let rr = Self.channelRank(rhs.type)
                if lr == rr { return lhs.label < rhs.label }
                return lr < rr
            }
    }

    /// APNs sorts to the top of the matrix (the native, always-present channel);
    /// the operator-configured relays follow. Unknown future types sort last but
    /// still render.
    private static func channelRank(_ type: String) -> Int {
        switch type {
        case "APNS": 0
        case "TELEGRAM": 1
        case "NTFY": 2
        case "WEBHOOK": 3
        case "EMAIL": 4
        default: 100
        }
    }

    func visibleEvents(
        for channel: NotificationChannel,
        payload: NotificationPreferencesPayload
    ) -> [String] {
        // Order by UX priority (Daily Briefing → Meds → System).
        // Unknown types fall back to alphabetical to keep the list stable
        // when the server invents a new eventType the client doesn't know yet.
        // (v0.5.0+ R1: streak rank was removed alongside the dashboard
        // streak feature.)
        payload.eventTypes
            // MEDICATION_INTAKE_SYNC is APNs-only plumbing by construction — a
            // silent background push that keeps a user's own iOS devices coherent
            // (`lib/notifications/types.ts`). It has no meaning on Telegram / ntfy
            // / Webhook / Email, so it never appears in their matrices; the server
            // wouldn't fan it out to them either.
            .filter { !(Self.apnsOnlyEvents.contains($0) && channel.type != "APNS") }
            .sorted { lhs, rhs in
                let lp = NotificationEventPriority.rank(of: lhs)
                let rp = NotificationEventPriority.rank(of: rhs)
                if lp == rp { return lhs < rhs }
                return lp < rp
            }
    }

    /// Events that only make sense on the native APNs channel (silent
    /// cross-device sync plumbing) and are hidden from the relay channels' rows.
    private static let apnsOnlyEvents: Set<String> = ["MEDICATION_INTAKE_SYNC"]

    func lastDeliveryLine(for channel: NotificationChannel) -> String? {
        // v0.5.5.1 — operator feedback: the previous
        // `RelativeDateTimeFormatter(dateTimeStyle: .named)` rendered
        // "vor 1 Stunde" / "vor 5 Sekunden", crowding the row. Channel
        // status now uses the compact helper which yields "vor 5min",
        // "vor 2h", "vor 3d" (DE) / "5min ago", "2h ago", "3d ago" (EN).
        guard let s = store?.channelStatus(id: channel.id) else { return nil }
        if let last = s.lastSuccessAt {
            return String(localized: "Last delivered \(CompactRelativeDate.string(from: last))")
        }
        if let last = s.lastFailureAt {
            return String(localized: "Last error \(CompactRelativeDate.string(from: last))")
        }
        return String(localized: "No delivery yet")
    }

    /// REG-12 (v0.5.6): when the server flagged the channel as
    /// auto-disabled (hard reject) or paused (transient backoff),
    /// surface the upstream's stable reason code so the operator can
    /// tell *why* the channel stopped working. Reason strings come
    /// from `lib/notifications/retry-policy.ts` (BadDeviceToken,
    /// give_up_after_5_failures, apns_not_configured, …) — we render
    /// them as a localised human-readable line below the timestamp.
    func lastFailureLine(for channel: NotificationChannel) -> String? {
        guard let s = store?.channelStatus(id: channel.id) else { return nil }
        // Only render the reason while the channel is actively unhappy.
        // For an `active` channel a recovered failure reason is noise.
        guard s.state == .autoDisabled || s.state == .sendingPaused else { return nil }
        let raw = s.disabledReason ?? s.lastFailureReason
        guard let raw, !raw.isEmpty else { return nil }
        return String(localized: "Grund: \(NotificationFailureReason.label(for: raw))")
    }

    /// Resolve the effective channel state from the live `status`
    /// endpoint and fall back to the static `enabled` flag from
    /// `/preferences` when status hasn't loaded yet. Encapsulates the
    /// glyph / tint / copy decision so the row can stay declarative.
    func resolveChannelState(_ channel: NotificationChannel) -> ResolvedChannelState {
        let status = store?.channelStatus(id: channel.id)
        if !channel.globallyEnabled {
            return ResolvedChannelState(
                glyph: "exclamationmark.triangle.fill",
                // Monochrome doctrine: warning/error states drop their
                // coloured tint — the distinct glyph + the state-line copy
                // carry the meaning, no coloured bubble.
                tint: HLText.secondary,
                stateLine: String(localized: "Disabled globally"),
                stateLineTint: HLText.secondary,
                voiceOverLabel: String(localized: "notifications.channel.state.inactive"),
                needsRetryAction: false
            )
        }
        if let status {
            switch status.state {
            case .active:
                return .activeState
            case .autoDisabled:
                return ResolvedChannelState(
                    glyph: "exclamationmark.circle.fill",
                    tint: HLText.secondary,
                    stateLine: String(localized: "Channel disabled automatically"),
                    stateLineTint: HLText.secondary,
                    voiceOverLabel: String(localized: "notifications.channel.state.autoDisabled"),
                    needsRetryAction: true
                )
            case .sendingPaused:
                return ResolvedChannelState(
                    glyph: "pause.circle.fill",
                    tint: HLText.secondary,
                    stateLine: String(localized: "Channel paused"),
                    stateLineTint: HLText.secondary,
                    voiceOverLabel: String(localized: "notifications.channel.state.paused"),
                    needsRetryAction: true
                )
            case .manuallyDisabled:
                return ResolvedChannelState(
                    glyph: "circle",
                    tint: HLText.tertiary,
                    stateLine: String(localized: "Channel disabled"),
                    stateLineTint: HLText.secondary,
                    voiceOverLabel: String(localized: "notifications.channel.state.inactive"),
                    needsRetryAction: false
                )
            }
        }
        // Status hasn't loaded yet — fall back to the static `enabled`
        // flag so the row still renders something sensible on a fresh
        // launch where `/status` is in flight.
        return channel.enabled ? .activeState : ResolvedChannelState(
            glyph: "circle",
            tint: HLText.tertiary,
            stateLine: String(localized: "Channel paused"),
            stateLineTint: HLText.secondary,
            voiceOverLabel: String(localized: "notifications.channel.state.inactive"),
            needsRetryAction: false
        )
    }

    func initializeStore() async {
        if store == nil, let api = container?.api {
            store = NotificationsStore(repo: NotificationsRepository(api: api), swr: container?.swr)
        }
        // v0.14.2 FW7 — ntfy + Telegram channel settings store. Server-first,
        // built off the same pinned `APIClient`.
        if servicesStore == nil, let api = container?.api {
            servicesStore = NotificationServicesStore(repo: NotificationServicesRepository(api: api))
        }
        await refreshSystemStatus()
        await store?.load()
        await servicesStore?.load()
        // v0.5.4.3 HP5 — the screen renders the mood-reminder toggle off
        // the SettingsStore.profile snapshot. Deep-links into this
        // screen (notification → settings/notifications) skip the
        // parent SettingsScreen .task so the profile may not be hot —
        // hydrate it ourselves when missing. Idempotent + cheap (SWR
        // serves from cache when warm).
        if container?.settingsStore.profile == nil {
            await container?.settingsStore.load()
        }
    }

    func refreshSystemStatus() async {
        #if canImport(UserNotifications) && canImport(UIKit)
            guard let notif = container?.notifications else { return }
            let settings = await notif.currentSettings()
            systemAuthorizationStatus = NotificationsSystemStatus(authorization: settings.authorizationStatus)
        #endif
    }

    /// Schedules a local UNNotificationRequest with the given variant.
    ///
    /// **B3 §3 changes:**
    /// - Trigger window 5s → 1s — Apple's own test buttons fire instantly,
    ///   5 seconds is too long for the user to wait without UI feedback.
    /// - Bumps `testTapCount` immediately on entry so the success-haptic
    ///   fires regardless of whether `add()` later succeeds; the user
    ///   needs to feel the press registered before the banner appears.
    /// - Asserts the foreground delegate is installed so we have evidence
    ///   in OSLog if a future regression breaks `AppContainer` wiring.
    /// - Sets `categoryIdentifier` per variant so the tap-routing path can
    ///   surface the right deep-link destination (mirrors server payload).
    /// - Auto-dismiss confirmation row after 4 seconds; cancels prior task
    ///   so back-to-back taps don't overlap timers.
    func sendTestNotification(variant: TestPushVariant) async {
        #if canImport(UserNotifications)
            // Defensive haptic + UI confirmation BEFORE the system call —
            // even if `add()` fails, the user knows the press registered.
            testTapCount += 1
            assertForegroundDelegateInstalled()

            let content = UNMutableNotificationContent()
            content.title = variant.title
            content.body = variant.body
            content.sound = .default
            content.categoryIdentifier = variant.categoryIdentifier
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let id = "healthlog.test.\(variant.id).\(UUID().uuidString)"
            let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            do {
                try await UNUserNotificationCenter.current().add(req)
                lastTestSentAt = .now
                lastTestVariant = variant
                HLLog.notifications.info("Test-Benachrichtigung geplant für +1 Sek (id=\(id), variant=\(variant.id))")
                // Auto-dismiss the confirmation row after 4 seconds —
                // long enough to be noticed, short enough to clear up.
                confirmationDismissTask?.cancel()
                confirmationDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                            lastTestVariant = nil
                            lastTestSentAt = nil
                        }
                    }
                }
            } catch {
                HLLog.notifications.error("Test-Benachrichtigung konnte nicht geplant werden: \(error.localizedDescription)")
            }
        #endif
    }

    /// Defensive check that the foreground UNUserNotificationCenter delegate
    /// is installed. The actual install happens in `AppContainer.init`
    /// (NotificationService super.init) — this just logs a warning if a
    /// future refactor moves the install elsewhere and breaks the contract.
    /// Without the delegate, iOS routes foreground notifications silently
    /// to Notification Center with no banner — exactly the "passiert gar
    /// nix" symptom users would report.
    func assertForegroundDelegateInstalled() {
        #if canImport(UserNotifications)
            if UNUserNotificationCenter.current().delegate == nil {
                HLLog.notifications.warning(
                    "UNUserNotificationCenter.delegate=nil — Banner werden im Foreground nicht angezeigt. AppContainer-Wiring prüfen."
                )
            }
        #endif
    }

    func openSystemSettings() {
        #if canImport(UIKit)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
}
