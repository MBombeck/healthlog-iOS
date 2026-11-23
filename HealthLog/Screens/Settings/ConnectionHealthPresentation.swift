import SwiftUI

/// How the app shows a connection's ``ConnectionHealth``.
///
/// One pill per `state`, one sentence per `reason`, at most one button for
/// `action`. Nothing here looks at the legacy status fields. Kept off the views
/// so the mapping is pinned by tests without asserting on localized text.
struct ConnectionHealthPresentation: Equatable {
    let health: ConnectionHealth

    /// The status pill of a connected integration.
    var pill: HLStatusPill.State {
        switch health.state {
        case .ok: .connected(label: stateLabel)
        case .limited, .degraded: .warning(label: stateLabel)
        case .actionRequired: .error(label: stateLabel)
        case .unknown: .unknown(label: stateLabel)
        }
    }

    /// The state in one or two words (the pill's label).
    var stateLabel: String {
        switch health.state {
        case .ok: String(localized: "Connected")
        case .limited: String(localized: "integration.health.pill.limited")
        case .degraded: String(localized: "integration.health.pill.degraded")
        case .actionRequired: String(localized: "integration.health.pill.actionRequired")
        case .unknown: String(localized: "integration.health.pill.unknown")
        }
    }

    /// Whether the state asks for attention (warm tint, never for an unknown word).
    var needsAttention: Bool {
        switch health.state {
        case .degraded, .actionRequired: true
        case .ok, .limited, .unknown: false
        }
    }

    /// Whether the card shows the health line at all. A healthy connection is
    /// said by the pill alone; every other state gets its sentence.
    var showsDetail: Bool {
        health.state != .ok
    }

    /// The localization key of the one sentence for this `reason`.
    var sentenceKey: String {
        switch health.reason {
        case .dataArriving: "integration.health.reason.dataArriving"
        case .firstSyncPending: "integration.health.reason.firstSyncPending"
        case .planLimited: "integration.health.reason.planLimited"
        case .permissionLimited: "integration.health.reason.permissionLimited"
        case .providerErrors: "integration.health.reason.providerErrors"
        case .syncStalled: "integration.health.reason.syncStalled"
        case .noNewData: "integration.health.reason.noNewData"
        case .unexpectedSilence: "integration.health.reason.unexpectedSilence"
        case .reauthRequired: "integration.health.reason.reauthRequired"
        case .pausedAfterErrors: "integration.health.reason.pausedAfterErrors"
        case .unknown: "integration.health.reason.unknown"
        }
    }

    var sentence: String {
        String(localized: String.LocalizationValue(sentenceKey))
    }

    /// The button this surface offers, or `nil`. `supported` is what the
    /// surface can actually do (a provider without a resume route cannot offer
    /// "Resume"), so a server action the app cannot carry out shows no button.
    func action(supported: Set<ConnectionHealth.Action>) -> ConnectionHealth.Action? {
        guard let action = health.action, supported.contains(action) else { return nil }
        return action
    }

    static func actionTitleKey(_ action: ConnectionHealth.Action) -> String {
        switch action {
        case .reconnect: "integration.health.action.reconnect"
        case .resume: "integration.health.action.resume"
        }
    }

    /// The withheld data types as one line, or `nil` when nothing is withheld.
    /// The server sends provider keys (`spo2`, `vo2Max`); they are shown as
    /// given, there is no label for them on the wire.
    var unavailableLine: String? {
        let items = health.unavailable.map(\.item).filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        let list = items.formatted(.list(type: .and))
        return String(localized: "integration.health.unavailable \(list)")
    }

    /// "Since 15 Oct 2026 at 08:00" for a degraded or action-required state.
    var sinceLine: String? {
        guard let since = health.since else { return nil }
        let when = HLDateFormat.dateTime(since)
        return String(localized: "integration.health.since \(when)")
    }
}

/// The health line of an integration card: the sentence for `reason`,
/// when it started, what is withheld, and at most one button.
struct ConnectionHealthSection: View {
    let health: ConnectionHealth
    var supportedActions: Set<ConnectionHealth.Action> = []
    var isWorking = false
    var onAction: (ConnectionHealth.Action) -> Void = { _ in }

    private var presentation: ConnectionHealthPresentation {
        ConnectionHealthPresentation(health: health)
    }

    var body: some View {
        if presentation.showsDetail {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(verbatim: presentation.sentence)
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let since = presentation.sinceLine {
                        Text(verbatim: since)
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.tertiary)
                    }
                    if let unavailable = presentation.unavailableLine {
                        Text(verbatim: unavailable)
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("integration.health.detail")
                if let action = presentation.action(supported: supportedActions) {
                    HLButton(
                        LocalizedStringKey(ConnectionHealthPresentation.actionTitleKey(action)),
                        systemImage: action == .reconnect ? "link" : "play.circle",
                        variant: .primary,
                        isLoading: isWorking
                    ) {
                        onAction(action)
                    }
                    .accessibilityIdentifier("integration.health.action")
                }
            }
        }
    }
}
