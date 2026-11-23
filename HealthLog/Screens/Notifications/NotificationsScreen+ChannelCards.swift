import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// `NotificationsScreen` channel + per-event preference + test-push card
/// subviews. Extracted from `NotificationsScreen.swift` (file_length discipline
/// — pure move, no behaviour change).
extension NotificationsScreen {
    @ViewBuilder
    var channelsCard: some View {
        if let payload = store?.payload, !payload.channels.isEmpty {
            HLCard("Channels") {
                ForEach(visibleChannels(payload.channels)) { channel in
                    channelRow(channel)
                }
            }
        }
    }

    /// The channel row is now status-aware. The earlier
    /// version derived its on/off state from the static
    /// `NotificationChannel.enabled` flag and showed an empty circle for
    /// paused/auto-disabled channels with no affordance to recover. We
    /// now consult `NotificationsStore.channelStatus(id:)` so the row
    /// reflects the live reliability state (`active` /
    /// `auto_disabled` / `sending_paused` / `manually_disabled`),
    /// surfaces the last-failure reason when the server provides one,
    /// and renders an "Erneut versuchen" button that calls
    /// `POST /api/notifications/status` to clear the cooldown.
    func channelRow(_ channel: NotificationChannel) -> some View {
        let resolvedState = resolveChannelState(channel)
        let isRetrying = store?.retryingChannelIds.contains(channel.id) ?? false
        let retrySucceeded = store?.lastRetrySucceededIds.contains(channel.id) ?? false
        return VStack(alignment: .leading, spacing: HLSpace.sm) {
            // Name and last delivery on the left, the state with its sign as
            // the row's status. The state stays monochrome: shape and word
            // carry it, not a coloured bubble.
            HLRow(
                title: Text(verbatim: channel.label),
                detail: lastDeliveryLine(for: channel).map { Text($0) },
                status: channelStatus(channel, resolvedState: resolvedState)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notifications.channel.\(channel.id).state")
            // Why the last push failed is a sentence, so it stands under the
            // row with the retry, not cut into the row.
            if let reason = lastFailureLine(for: channel) {
                Text(reason)
                    .hlText(.rowStatus)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notifications.channel.\(channel.id).failure")
            }
            if resolvedState.needsRetryAction {
                retryButton(channel: channel, isRetrying: isRetrying)
            }
            if retrySucceeded {
                retrySuccessRow()
            }
        }
    }

    /// "Erneut versuchen" affordance — flips an auto-disabled or
    /// paused channel back to `enabled = true` and clears the
    /// dispatcher's `nextRetryAt` cooldown so the next outgoing
    /// reminder actually tries the upstream. While the POST + status
    /// reload are in flight we swap the label for an inline spinner so
    /// the operator gets immediate feedback (and the button can't be
    /// double-tapped).
    func retryButton(channel: NotificationChannel, isRetrying: Bool) -> some View {
        HLButton(
            HLControlWord.retry.key,
            systemImage: "arrow.clockwise",
            variant: .secondary,
            isLoading: isRetrying
        ) {
            Task { await store?.retry(channelId: channel.id) }
        }
        .disabled(isRetrying)
        .accessibilityIdentifier("notifications.channel.\(channel.id).retry")
        .accessibilityHint(Text("Re-enables the paused channel."))
    }

    func retrySuccessRow() -> some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HLText.primary)
            Text("Back on — the next push will be retried.")
                .hlText(.rowStatus)
        }
        .accessibilityElement(children: .combine)
    }

    /// The channel's state as the row's status text with its sign; a channel
    /// the server has not switched on says so in plain words.
    func channelStatus(_ channel: NotificationChannel, resolvedState: ResolvedChannelState) -> HLRowStatus {
        if !channel.globallyEnabled {
            return HLRowStatus(String(localized: "notifications.channel.notEnabled"))
        }
        return HLRowStatus(resolvedState.stateLine, icon: resolvedState.glyph)
    }

    @ViewBuilder
    var preferencesCards: some View {
        if let payload = store?.payload, !payload.eventTypes.isEmpty {
            ForEach(visibleChannels(payload.channels)) { channel in
                preferencesCard(for: channel, payload: payload)
            }
        } else if store?.isLoading == true {
            HLCard("Events") {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    func preferencesCard(for channel: NotificationChannel, payload: NotificationPreferencesPayload) -> some View {
        let visible = visibleEvents(for: channel, payload: payload)
        // Build 6.5 — with the matrix opened to the relay channels
        // (Telegram / ntfy / Webhook / Email), more than one card can render.
        // A single visible channel keeps the plain "Events" title (no redundant
        // "— APNs" suffix); with several, each card is disambiguated by its
        // channel label so the user can tell which relay a toggle governs.
        let title: LocalizedStringKey = visibleChannels(payload.channels).count > 1
            ? LocalizedStringKey("Events — \(channel.label)")
            : "Events"
        // UI-Standard R2 — der Karten-Footer sagte „Persönliche Rekorde
        // sind standardmäßig aus — du kannst sie hier einschalten." Beides ist
        // verboten: die Voreinstellungs-Ansage, weil der Schalter seinen
        // Zustand selbst zeigt, und die Bedien-Nacherzählung, weil der Satz
        // genau neben dem Schalter stand, den er beschreibt.
        HLCard(title) {
            if visible.isEmpty {
                emptyEventsRow(for: channel)
            } else {
                ForEach(visible, id: \.self) { eventType in
                    eventToggleRow(channel: channel, eventType: eventType, payload: payload)
                }
            }
        }
    }

    func eventToggleRow(
        channel: NotificationChannel,
        eventType: String,
        payload: NotificationPreferencesPayload
    ) -> some View {
        Toggle(
            isOn: Binding(
                // Build 6.5 — reflect the server's default-policy for events with
                // no explicit preference row (default-ON events read as on), not a
                // flat "off". Writing a toggle still persists an explicit row.
                get: { payload.effectiveEnabled(channelId: channel.id, eventType: eventType) },
                set: { newValue in
                    Task {
                        await store?.toggle(channelId: channel.id, eventType: eventType, to: newValue)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HLRowTitle(Text(verbatim: NotificationEventLocalization.title(for: eventType)))
                if let hint = NotificationEventLocalization.hint(for: eventType) {
                    Text(hint)
                        .hlText(.rowSubtitle)
                }
            }
        }
        .frame(minHeight: HLLayout.rowMinHeight)
        .disabled(!channel.enabled || !channel.globallyEnabled)
    }

    func emptyEventsRow(for channel: NotificationChannel) -> some View {
        // Server didn't ship any toggleable events for this channel (rare,
        // mostly happens during onboarding before the first webhook ping).
        // Surface a clear non-empty row so the section never collapses
        // into "title only" — user reported sections feeling unfinished.
        // UI-Standard R2 — „Tippe oben auf einen Schalter, um sie wieder
        // zu aktivieren." war eine Bedien-Nacherzählung der Schalter, die zwei
        // Karten weiter oben sichtbar sind.
        HLIconTextRow(icon: "bell.slash", "You have turned off these notifications")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("NotificationsScreen.empty.\(channel.id)")
    }

    /// Returns true when the user has either `.authorized` or `.provisional`
    /// notification permission — required for the test-push to fire.
    var canSendTestPush: Bool {
        systemAuthorizationStatus == .authorized || systemAuthorizationStatus == .provisional
    }

    /// Diagnose section — test-push button + prominent confirmation row.
    ///
    /// **B3 §3 fix:** the previous version used a 5-second trigger + a
    /// faint `.hlCaption` caption below the button. Users tapped, waited,
    /// saw nothing visible immediately, and concluded "passiert gar nix"
    /// (M2-A4 §5). The new version:
    ///
    /// - `Menu` with two payload variants (Standard, Stimmung) so the user
    ///   can verify each notification category renders correctly.
    ///   `categoryIdentifier` is set per-variant so deep-link routing can
    ///   surface the right destination on tap. (v0.5.0+ R1: the third
    ///   variant — Streak — was removed alongside the dashboard streak
    ///   feature.)
    /// - Trigger reduced to 1 second — Apple's own Settings test buttons
    ///   fire instantly; 5 seconds was long enough that the user assumed
    ///   failure.
    /// - `.sensoryFeedback(.success, trigger: testTapCount)` on the screen
    ///   fires a success-haptic immediately on tap.
    /// - Confirmation row uses `.hlSubhead.weight(.medium)` at full ink
    ///   (`HLText.primary`) — visible at a glance instead of a quiet
    ///   caption, but monochrome (no coloured bubble).
    /// - Auto-dismiss after 4 seconds via a cancellable Task.
    var testPushCard: some View {
        HLCard(
            "Diagnostics",
            // UI-Standard R5 — Footer: höchstens zwei Sätze. One,
            // in the reader's words (no "server").
            footer: "notifications.test.footer"
        ) {
            Menu {
                ForEach(TestPushVariant.allCases) { variant in
                    Button {
                        Task { await sendTestNotification(variant: variant) }
                    } label: {
                        Label(variant.menuTitle, systemImage: variant.symbol)
                    }
                }
            } label: {
                HLSettingsRow(icon: "paperplane.fill", title: "Send test notification")
            }
            .disabled(!canSendTestPush)
            .accessibilityHint(Text("Pick a test variant — the banner appears within a second."))

            if let variant = lastTestVariant, lastTestSentAt != nil {
                confirmationRow(variant: variant)
            }
            // Sub-page link to the deeper diagnostics
            // screen. Surfaces categories + pending local-notification
            // request count so an operator self-diagnosing a "Banner
            // kommt nicht" report has more than the authorization
            // status to inspect.
            HLSettingsActionRow(icon: "stethoscope", title: "Advanced diagnostics", presents: .push) {
                NotificationDiagnosticsScreen()
            }
            .accessibilityIdentifier("notifications.diagnostics.entry")
        }
    }

    func confirmationRow(variant: TestPushVariant) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HLText.primary)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text("Notification sent — should appear shortly")
                    .hlText(.rowTitle)
                Text(variant.menuTitle)
                    .hlText(.rowSubtitle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// Per-user notification-channel settings (ntfy + Telegram).
    /// The web exposes these under `settings → notifications`; iOS previously
    /// hard-suppressed all non-APNs channels. Each card is gated on its
    /// server-wide availability flag (`/api/settings/global-services`), so a
    /// channel the operator disabled globally stays hidden.
    @ViewBuilder
    var serviceChannelCards: some View {
        if let servicesStore {
            if servicesStore.showNtfyCard {
                NtfyChannelCard()
                    .environment(servicesStore)
            }
            if servicesStore.showTelegramCard {
                TelegramChannelCard()
                    .environment(servicesStore)
            }
            // v1.18.x parity — generic outbound webhook (Gotify / Discord /
            // Slack / Matrix-bridge / Home Assistant). No global availability
            // flag gates this channel, so it always renders.
            WebhookChannelCard()
                .environment(servicesStore)
        }
    }

    /// UI-Standard R4 — der Footer war ein Wegweiser („… kannst du sie nur
    /// in den iOS-Einstellungen wieder aktivieren"), und der Absprung, auf den
    /// er zeigte, steht als einziger Inhalt derselben Karte direkt darunter.
    /// R4 verlangt an so einer Stelle den Absprung **oder** nichts — der
    /// Absprung war schon da.
    var systemSettingsCard: some View {
        HLCard("System Settings", layout: .rows) {
            HLSettingsActionRow(icon: "gear", title: "Open System Settings", presents: .external) {
                openSystemSettings()
            }
        }
    }
}
