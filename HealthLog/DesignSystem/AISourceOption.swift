import Foundation

/// v0.13 W3 — the per-card availability model for ``AISourceChoicePicker``.
///
/// W1 evolved the picker from a flat `[AIMode]` to a mode-aware list. W3 makes
/// each offered card *honest* about whether it can actually be picked right now:
/// a card is either freshly `.available` or `.disabledWithReason` (greyed, not
/// tappable, with a one-line reason the user can act on). Cards that can never
/// work on this device/mode are not in the list at all — they're hidden, not
/// disabled (D4: hide-permanent / disable-recoverable).
///
/// The decision of *which* cards are offered, and in *which* state, lives in
/// ``AISourceOptions/offered(operatingMode:onDeviceAvailability:)`` — a pure
/// function the hosts call and tests pin, deliberately kept out of the View.
enum AISourceCardState: Equatable {
    /// The card is selectable. Tapping it commits the mode.
    case available
    /// The card is shown greyed + non-tappable with a one-line reason. The
    /// optional `recovery` is a user action that could flip the card to
    /// `.available` (e.g. open Settings → Apple Intelligence). `nil` means the
    /// reason is passive ("preparing") — there is nothing to tap.
    case disabledWithReason(reason: String, recovery: AISourceRecovery?)
}

/// A recovery affordance attached to a `disabledWithReason` card.
enum AISourceRecovery: Equatable {
    /// Deep-link to the system Settings → Apple Intelligence pane so the user
    /// can turn it on. The picker renders this as a tappable "Open Settings"
    /// chip; the host owns the actual `openURL`.
    case openAppleIntelligenceSettings
    /// v0.14.1 — route to the in-app Settings → Assistant hub so the user can
    /// configure a server AI provider (or BYO key). Attached to the disabled
    /// "External AI" card when no server provider is configured, so the dead-end
    /// becomes an actionable "set one up" chip instead of a silent bounce. The
    /// host (Coach surface) owns the actual navigation.
    case openAssistantSettings
}

/// One offered AI-source card: a mode plus the state it renders in.
struct AISourceOption: Identifiable, Equatable {
    let mode: AIMode
    let state: AISourceCardState

    var id: String {
        mode.rawValue
    }

    var isAvailable: Bool {
        if case .available = state { return true }
        return false
    }
}

/// Pure, testable computation of the offered AI-source options for a given
/// operating mode × on-device capability. Kept free of SwiftUI so the matrix
/// logic (D2 mode axis · D4 hide-permanent / disable-recoverable) is unit-pinned
/// rather than buried in a `body`.
///
/// **`.byoKey` is offered in BOTH operating modes (v0.13 W4).** The client-side
/// BYO-key path runs device→provider directly, so it works standalone AND
/// server-connected — it is mode-invariant. The Settings/onboarding hosts reveal
/// the inline key-entry card when it is picked, so it is no longer a dead-end
/// (W4 landed the entry card + Coach transmit). The `.online` (External AI) card
/// is still dropped in standalone — a standalone install has no server provider
/// to route through.
enum AISourceOptions {
    /// Compute the cards to render, in display order.
    ///
    /// - `none` is always offered (privacy-first default, every mode).
    /// - `onDevice` is offered iff the device can ever run it: `.available`
    ///   (selectable) or recoverable (`.appleIntelligenceNotEnabled` /
    ///   `.modelNotReady`, shown disabled-with-reason). Permanent incapability
    ///   (`.deviceNotEligible` / `.unsupported`) → the card is omitted entirely.
    /// - `online` (External AI) is offered only in `.paired` mode.
    /// - `byoKey` ("Own key") is offered in BOTH modes (mode-invariant, W4).
    static func offered(
        operatingMode: BackendAvailability.Mode,
        onDeviceAvailability: LocalLLMService.Availability
    ) -> [AISourceOption] {
        var options: [AISourceOption] = []

        // Privacy-first default — always available, every mode.
        options.append(AISourceOption(mode: .none, state: .available))

        // On-device — capability-gated (D4).
        if let onDeviceState = onDeviceCardState(for: onDeviceAvailability) {
            options.append(AISourceOption(mode: .onDevice, state: onDeviceState))
        }

        // External / server AI — server-mode only (D2). Standalone has no
        // server provider to route through, so the card is dropped.
        if operatingMode == .paired {
            options.append(AISourceOption(mode: .online, state: .available))
        }

        // Own key (BYO, client-side device→provider) — offered in BOTH modes
        // (mode-invariant). v0.13 W4 un-gated it: the host reveals the inline
        // key-entry card when picked + the Coach BYO arm transmits, so it is a
        // real path, not a dead-end. Always `.available` — capability is "do you
        // have a key", which the entry card collects; there is nothing to
        // hide/disable up front.
        options.append(AISourceOption(mode: .byoKey, state: .available))

        return options
    }

    /// v0.14.1 — the two-card option list for the AskCoach source chooser
    /// (`CoachSourceChoiceView`): On-device (always `.available` there — the host
    /// only shows this picker on a capable device) + External AI. External AI is
    /// `.available` only when a server provider is configured; otherwise it is
    /// `.disabledWithReason` (greyed, non-tappable) with a "set up a provider"
    /// recovery chip routing to Settings → Assistant. This makes the no-provider
    /// dead-end unreachable in the picker rather than a path that consents to a
    /// noop and silently bounces back to the chooser. Pure + testable, mirroring
    /// ``offered(operatingMode:onDeviceAvailability:)``.
    static func coachChoice(hasServerProvider: Bool) -> [AISourceOption] {
        [
            AISourceOption(mode: .onDevice, state: .available),
            AISourceOption(mode: .online, state: externalAICardState(hasServerProvider: hasServerProvider))
        ]
    }

    /// v0.14.1 — the External AI card's state for the Coach chooser: available
    /// with a provider, disabled-with-reason (+ Assistant-settings recovery)
    /// without one.
    static func externalAICardState(hasServerProvider: Bool) -> AISourceCardState {
        if hasServerProvider {
            return .available
        }
        return .disabledWithReason(
            reason: String(
                localized: "Requires a server AI provider. Set one up in Settings → Assistant.",
                comment: "Coach source chooser — External AI disabled because no server provider is configured"
            ),
            recovery: .openAssistantSettings
        )
    }

    /// Maps on-device availability → the on-device card's state, or `nil` when
    /// the card must be hidden entirely (permanent incapability).
    ///
    /// Reuses the AskCoach kill-card reason copy, generalised from "Coach" to
    /// "on-device assistant" so we don't author a parallel string set.
    static func onDeviceCardState(
        for availability: LocalLLMService.Availability
    ) -> AISourceCardState? {
        switch availability {
        case .available:
            .available
        case .appleIntelligenceNotEnabled:
            .disabledWithReason(
                reason: String(
                    localized: "Turn on Apple Intelligence in Settings to use the on-device assistant.",
                    comment: "AI source picker — on-device card disabled because Apple Intelligence is off"
                ),
                recovery: .openAppleIntelligenceSettings
            )
        case .modelNotReady:
            .disabledWithReason(
                reason: String(
                    localized: "Apple is preparing the on-device model. It becomes available once the download finishes.",
                    comment: "AI source picker — on-device card disabled because the model is still downloading"
                ),
                recovery: nil
            )
        case .deviceNotEligible, .unsupported:
            // Permanent on this device/OS — hide rather than tease (D4).
            nil
        }
    }
}
