import SwiftUI

// **#190 — the relay's three surfaces.** Each reads ``PushRelayStore`` from
// the container and renders nothing when the relay has nothing to say, so a
// server without the offer shows the screens exactly as before.

/// Home: the one-time opt-in card, the calm line about a disrupted sync, and
/// the note after a tap the server did not confirm.
struct PushRelayDashboardSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let relay = container?.pushRelay {
            if relay.unverifiedTapNotice {
                PushRelayNoticeLine(
                    text: "This notification was not confirmed by your server, so HealthLog did nothing.",
                    systemImage: "questionmark.circle"
                ) { relay.unverifiedTapNotice = false }
            }
            if relay.showsDegradedLine {
                PushRelayNoticeLine(
                    text: PushRelayCopy.degraded(since: relay.capability.since),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            if relay.showsOptInCard {
                PushRelayOptInCard(relay: relay)
            }
        }
    }
}

/// The card. Its text is the consent: who runs the relay, what it can see, and
/// that reminders stay on the device. "Turn on" is the only path that makes a
/// key; "Not now" hides the card for good.
struct PushRelayOptInCard: View {
    let relay: PushRelayStore
    /// The second, separate consent (#191): off by default.
    @State private var liveActivityUpdates = false

    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("Notifications from your server")
                    .hlText(.cardTitle)
                PushRelayConsentText()
                if let terms = relay.privacyURL {
                    Link(destination: terms) {
                        Text("Privacy notice")
                    }
                    .accessibilityIdentifier("pushRelay.card.privacy")
                }
                if relay.capability.isUsable {
                    PushRelayLiveActivityToggle(
                        isOn: $liveActivityUpdates,
                        isEnabled: relay.liveActivityUpdatesOffered,
                        accessibilityID: "pushRelay.card.liveActivity"
                    )
                }
                HLButtonPair {
                    HLButton("Turn on", variant: .primary, isLoading: relay.isWorking) {
                        let updates = liveActivityUpdates
                        Task { await relay.turnOn(liveActivityUpdates: updates) }
                    }
                    .accessibilityIdentifier("pushRelay.card.turnOn")
                } secondary: {
                    HLButton("Not now", variant: .secondary) { relay.answerNotNow() }
                        .accessibilityIdentifier("pushRelay.card.notNow")
                }
                .padding(.top, HLSpace.xs)
            }
        }
    }
}

/// The consent paragraphs, shared by the card and the settings footer.
struct PushRelayConsentText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("""
            So your server can tell you about doses and changes and end the Live Activity, notifications can travel \
            through the HealthLog relay to Apple. The relay is run by the HealthLog project maintainer, not by whoever \
            runs your server.
            """)
            Text("""
            Content is encrypted so that only this device can read it. The relay and Apple can still see when your \
            server sends you something, which can show when you take medication. Apple can link these times to your \
            Apple Account.
            """)
            Text("""
            Reminders stay on your device. You can turn this off at any time in Settings, even if your server is \
            unreachable. The relay is for private and household use only and is not a medical service.
            """)
        }
        .hlText(.rowSubtitle)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The switch for Live Activity start and update over the relay, with the
/// one sentence that is its consent.
struct PushRelayLiveActivityToggle: View {
    @Binding var isOn: Bool
    var isBusy = false
    /// Locked until the signed consent of #191 is specified.
    var isEnabled = true
    let accessibilityID: String

    var body: some View {
        HLSettingsToggleRow(
            title: "Live Activity updates through the relay",
            description: "The relay and Apple can see when a dose is due.",
            isOn: $isOn,
            isBusy: isBusy,
            isEnabled: isEnabled,
            accessibilityID: accessibilityID
        )
    }
}

/// The calm line on the medication screen (#190 5.6), the same as on Home.
struct PushRelayDegradedLine: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let relay = container?.pushRelay, relay.showsDegradedLine {
            PushRelayNoticeLine(
                text: PushRelayCopy.degraded(since: relay.capability.since),
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
    }
}

/// One quiet line with an optional close button.
struct PushRelayNoticeLine: View {
    let text: LocalizedStringKey
    let systemImage: String
    var onClose: (() -> Void)?

    var body: some View {
        HLCard {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Image(systemName: systemImage)
                    .hlText(.rowSubtitle)
                    .accessibilityHidden(true)
                Text(text)
                    .hlText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onClose {
                    HLIconButton(systemImage: "xmark", label: HLControlWord.close.key, action: onClose)
                }
            }
        }
    }
}

enum PushRelayCopy {
    static func degraded(since: Date?) -> LocalizedStringKey {
        guard let since else {
            return "Sync with your other devices is disrupted. Check HealthLog before taking a dose."
        }
        let time = HLTimeFormat.time(since)
        return "Sync with your other devices is disrupted since \(time). Check HealthLog before taking a dose."
    }
}

/// Settings > Notifications: the switch, kept available after the card.
struct PushRelaySettingsCard: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let relay = container?.pushRelay, relay.showsSettings {
            HLCard("Notifications from your server") {
                if relay.capability.isUsable || relay.isOn {
                    HLSettingsToggleRow(
                        title: "Send through the HealthLog relay",
                        description: nil,
                        isOn: Binding(
                            get: { relay.isOn },
                            set: { on in
                                Task {
                                    if on {
                                        await relay.turnOn()
                                    } else {
                                        await relay.turnOff(reason: .person)
                                    }
                                }
                            }
                        ),
                        isBusy: relay.isWorking,
                        accessibilityID: "pushRelay.settings.toggle"
                    )
                    PushRelayConsentText()
                }
                if relay.isOn {
                    PushRelayLiveActivityToggle(
                        isOn: Binding(
                            get: { relay.liveActivityUpdatesOn },
                            set: { on in Task { await relay.setLiveActivityUpdates(on) } }
                        ),
                        isBusy: relay.isWorking,
                        isEnabled: relay.liveActivityUpdatesAvailable,
                        accessibilityID: "pushRelay.settings.liveActivity"
                    )
                }
                if relay.isOn, relay.needsReconnect {
                    Text("This device needs to connect to the relay again, for example after a restore.")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                    HLSettingsActionRow(icon: "arrow.clockwise", title: "Connect again", presents: .confirm) {
                        Task { await relay.reconnect() }
                    }
                    .accessibilityIdentifier("pushRelay.settings.reconnect")
                }
                if relay.unavailable == .otherRelay {
                    Text("Your server uses a different relay than this app, so the relay is not available here.")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if relay.unavailable == .blocked {
                    Text("The relay can no longer reach this device for this server. Reinstalling HealthLog brings it back.")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if relay.deviceLimitReached, !relay.isOn {
                    Text(
                        "Five devices of this account already use the relay. HealthLog turned it off on this device; reminders work as before."
                    )
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if relay.operatorTurnedOff, !relay.isOn {
                    Text("Your server no longer offers the relay. HealthLog turned it off on this device; reminders work as before.")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Advanced diagnostics: the state, the instance id for an abuse report, and
/// the stop that works while the server does not answer.
struct PushRelayDiagnosticsCard: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let relay = container?.pushRelay, relay.isOn || relay.capability.offered || relay.capability.seals {
            HLCard("Relay", footer: "Stop pushes from this server works even when the server does not respond.", layout: .rows) {
                HLSettingsRow(
                    icon: "lock",
                    title: "Encrypted pushes",
                    value: relay.capability.sealsForThisDevice ? String(localized: "On") : String(localized: "Off")
                )
                HLSettingsRow(icon: "dot.radiowaves.up.forward", title: "State", value: PushRelayDiagnostics.stateLabel(relay))
                if let instance = relay.capability.instanceId {
                    HLSettingsRow(icon: "number", title: "Instance", value: instance)
                }
                HLSettingsRow(
                    icon: "envelope.badge",
                    title: "Opened envelopes",
                    value: PushRelayDiagnostics.receiptsLabel(relay.receiptCounts)
                )
                if relay.isOn {
                    HLSettingsActionRow(
                        icon: "hand.raised",
                        title: "Stop pushes from this server",
                        role: .standard,
                        presents: .confirm
                    ) {
                        Task { await relay.stopPushesFromThisServer() }
                    }
                    .accessibilityIdentifier("pushRelay.diagnostics.stop")
                }
            }
        }
    }
}

/// The relay row of the sync diagnostics, with the local push counters:
/// received, opened and discarded per class, the last delivery and, when the
/// server sends it, the remaining quota. Nothing here leaves the device.
struct PushRelaySyncDiagnosticsRow: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let relay = container?.pushRelay {
            if relay.isOn || relay.capability.offered || relay.capability.seals {
                HLSettingsStatRow(label: Text("Push relay"), value: PushRelayDiagnostics.stateLabel(relay), tint: HLText.secondary)
            }
            let snapshot = relay.deliveryCounters.snapshot()
            ForEach(PushDeliveryCounters.PushClass.allCases, id: \.self) { pushClass in
                HLSettingsStatRow(
                    label: Text(PushRelayDiagnostics.classLabel(pushClass)),
                    value: PushRelayDiagnostics.countsLabel(snapshot, pushClass),
                    tint: HLText.secondary
                )
            }
            HLSettingsStatRow(
                label: Text("push.diag.last_delivery"),
                value: snapshot.lastDeliveryAt.map { $0.formatted(.relative(presentation: .named)) }
                    ?? String(localized: "push.diag.never"),
                tint: HLText.secondary
            )
        }
    }
}

enum PushRelayDiagnostics {
    @MainActor
    static func stateLabel(_ relay: PushRelayStore) -> String {
        guard relay.isOn else {
            return relay.capability.offered ? String(localized: "Offered, off") : String(localized: "Off")
        }
        if relay.capability.isDegraded { return String(localized: "Disrupted") }
        switch relay.capability.device?.relayState ?? .none {
        case .bound: return String(localized: "On")
        case .rebindNeeded, .none: return String(localized: "Connecting")
        case .conflict: return String(localized: "Confirming this device")
        }
    }

    static func classLabel(_ pushClass: PushDeliveryCounters.PushClass) -> LocalizedStringKey {
        switch pushClass {
        case .alert: "push.diag.class.alert"
        case .silent: "push.diag.class.silent"
        case .liveActivity: "push.diag.class.live_activity"
        }
    }

    /// "12 received, 11 opened, 1 discarded".
    static func countsLabel(_ snapshot: PushDeliveryCounters.Snapshot, _ pushClass: PushDeliveryCounters.PushClass) -> String {
        String(
            format: String(localized: "push.diag.counts"),
            snapshot.count(.received, pushClass),
            snapshot.count(.opened, pushClass),
            snapshot.count(.discarded, pushClass)
        )
    }

    static func receiptsLabel(_ counts: [RelayPushClass: Int]) -> String {
        let alert = counts[.alert] ?? 0
        let silent = counts[.silent] ?? 0
        return String(format: String(localized: "%lld visible, %lld silent"), alert, silent)
    }
}
