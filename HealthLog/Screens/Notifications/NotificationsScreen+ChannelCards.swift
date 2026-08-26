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
            HLSettingsCard(icon: "antenna.radiowaves.left.and.right", title: "Channels") {
                ForEach(visibleChannels(payload.channels)) { channel in
                    channelRow(channel)
                    if channel.id != visibleChannels(payload.channels).last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    /// REG-12 (v0.5.6): the channel row is now status-aware. The earlier
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(channel.label).font(.hlHeadline)
                    channelStateLine(channel, resolvedState: resolvedState)
                    if let line = lastDeliveryLine(for: channel) {
                        Text(line)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                    if let reason = lastFailureLine(for: channel) {
                        Text(reason)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .accessibilityIdentifier("notifications.channel.\(channel.id).failure")
                    }
                }
                Spacer()
                // Monochrome doctrine: the state indicator is a plain ink
                // glyph (checkmark / exclamation / pause / circle) — the
                // shape + the state-line copy convey the state without a
                // coloured "bubble". Glyph + tint live on
                // `ResolvedChannelState` so the matrix stays unit-testable.
                Image(systemName: resolvedState.glyph)
                    .foregroundStyle(resolvedState.tint)
                    .accessibilityLabel(Text(resolvedState.voiceOverLabel))
            }
            if resolvedState.needsRetryAction {
                retryButton(channel: channel, isRetrying: isRetrying)
            }
            if retrySucceeded {
                retrySuccessRow()
            }
        }
        .padding(.vertical, HLSpace.xxs)
    }

    /// "Erneut versuchen" affordance — flips an auto-disabled or
    /// paused channel back to `enabled = true` and clears the
    /// dispatcher's `nextRetryAt` cooldown so the next outgoing
    /// reminder actually tries the upstream. While the POST + status
    /// reload are in flight we swap the label for an inline spinner so
    /// the operator gets immediate feedback (and the button can't be
    /// double-tapped).
    func retryButton(channel: NotificationChannel, isRetrying: Bool) -> some View {
        Button {
            Task { await store?.retry(channelId: channel.id) }
        } label: {
            HStack(spacing: HLSpace.xs) {
                if isRetrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("Try again")
            }
            .font(.hlSubhead)
        }
        .hlGlassButtonStyle()
        .controlSize(.small)
        .disabled(isRetrying)
        .accessibilityIdentifier("notifications.channel.\(channel.id).retry")
        .accessibilityHint(Text("Re-enables the paused channel."))
    }

    func retrySuccessRow() -> some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HLText.primary)
            Text("Back on — the next push will be retried.")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func channelStateLine(_ channel: NotificationChannel, resolvedState: ResolvedChannelState) -> some View {
        if !channel.globallyEnabled {
            Text("Globally disabled — please contact the operator.")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        } else {
            Text(resolvedState.stateLine)
                .font(.hlCaption)
                .foregroundStyle(resolvedState.stateLineTint)
                .accessibilityIdentifier("notifications.channel.\(channel.id).state")
        }
    }

    @ViewBuilder
    var preferencesCards: some View {
        if let payload = store?.payload, !payload.eventTypes.isEmpty {
            ForEach(visibleChannels(payload.channels)) { channel in
                preferencesCard(for: channel, payload: payload)
            }
        } else if store?.isLoading == true {
            HLSettingsCard(icon: "bell.fill", title: "Events") {
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
        // UI-Standard R2 (U6) — der Karten-Footer sagte „Persönliche Rekorde
        // sind standardmäßig aus — du kannst sie hier einschalten." Beides ist
        // verboten: die Voreinstellungs-Ansage, weil der Schalter seinen
        // Zustand selbst zeigt, und die Bedien-Nacherzählung, weil der Satz
        // genau neben dem Schalter stand, den er beschreibt.
        HLSettingsCard(
            icon: "bell.fill",
            title: title
        ) {
            if visible.isEmpty {
                emptyEventsRow(for: channel)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element) { idx, eventType in
                    eventToggleRow(channel: channel, eventType: eventType, payload: payload)
                    if idx < visible.count - 1 { Divider().opacity(0.5) }
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
                Text(NotificationEventLocalization.title(for: eventType))
                    .font(.hlHeadline)
                if let hint = NotificationEventLocalization.hint(for: eventType) {
                    Text(hint)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .disabled(!channel.enabled || !channel.globallyEnabled)
    }

    func emptyEventsRow(for channel: NotificationChannel) -> some View {
        // Server didn't ship any toggleable events for this channel (rare,
        // mostly happens during onboarding before the first webhook ping).
        // Surface a clear non-empty row so the section never collapses
        // into "title only" — user reported sections feeling unfinished.
        // UI-Standard R2 (U6) — „Tippe oben auf einen Schalter, um sie wieder
        // zu aktivieren." war eine Bedien-Nacherzählung der Schalter, die zwei
        // Karten weiter oben sichtbar sind.
        Label {
            Text("You have turned off these notifications")
                .font(.hlHeadline)
        } icon: {
            Image(systemName: "bell.slash")
                .foregroundStyle(HLText.tertiary)
        }
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
        HLSettingsCard(
            icon: "paperplane.fill",
            title: "Diagnostics",
            // UI-Standard R5 (U6) — Footer: höchstens zwei Sätze. Der dritte
            // („So prüfst du Permission + Banner-Sichtbarkeit.") ist in den
            // ersten gewandert; keine Aussage fehlt.
            footer: "Sends a local test notification to your device — no data reaches the server, so this checks permission and banner visibility. With Focus or notification summaries active, iOS may delay the banner."
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
                Label("Send test notification", systemImage: "paperplane.fill")
                    .font(.hlSubhead)
            }
            .disabled(!canSendTestPush)
            .accessibilityHint(Text("Pick a test variant — the banner appears within a second."))

            if let variant = lastTestVariant, lastTestSentAt != nil {
                confirmationRow(variant: variant)
            }
            // v0.5.5 W-MED — sub-page link to the deeper diagnostics
            // screen. Surfaces categories + pending local-notification
            // request count so an operator self-diagnosing a "Banner
            // kommt nicht" report has more than the authorization
            // status to inspect.
            Divider().opacity(0.5)
            NavigationLink {
                NotificationDiagnosticsScreen()
            } label: {
                Label("Advanced diagnostics", systemImage: "stethoscope")
                    .font(.hlSubhead)
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
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(HLText.primary)
                Text(variant.menuTitle)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// v0.14.2 FW7 — per-user notification-channel settings (ntfy + Telegram).
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

    /// UI-Standard R4 (U6) — der Footer war ein Wegweiser („… kannst du sie nur
    /// in den iOS-Einstellungen wieder aktivieren"), und der Absprung, auf den
    /// er zeigte, steht als einziger Inhalt derselben Karte direkt darunter.
    /// R4 verlangt an so einer Stelle den Absprung **oder** nichts — der
    /// Absprung war schon da.
    var systemSettingsCard: some View {
        HLSettingsCard(
            icon: "gear",
            title: "System Settings"
        ) {
            Button {
                openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gear")
                    .font(.hlSubhead)
            }
        }
    }
}
