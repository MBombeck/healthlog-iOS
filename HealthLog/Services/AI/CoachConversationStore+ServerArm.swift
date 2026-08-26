import Foundation

/// v0.11 marathon (AI-1) — the server-arm decision gate, split out of
/// `CoachConversationStore.swift` to keep that file under the 600-line SwiftLint
/// ceiling. These computed properties decide whether a Coach send routes to the
/// server arm, asks for consent, or stays on-device.
///
/// **AI-1 fix:** the gate now consults the user's *explicit* "External AI"
/// (`.online`) pick via ``CoachConversationStore/prefersServerArm`` — when set,
/// the server arm wins even on an AI-capable device, mirroring the BYO-key arm's
/// precedence, instead of being silently overridden by on-device. Consent stays
/// fail-closed throughout: an un-granted `serverConsentGate` returns `false`
/// regardless of the explicit pick, so no health data leaves the device without
/// the per-provider consent (Apple 5.1.2(i)).
public extension CoachConversationStore {
    /// `true` when a server service is wired AND the user explicitly picked the
    /// server arm. The "honour the pick" signal: the server arm is preferred even
    /// on an AI-capable device (mirroring BYO).
    internal var explicitlyPrefersServer: Bool {
        serverService != nil && (prefersServerArm?() ?? false)
    }

    /// **v0.7.1 W-COACH-FALLBACK** — `true` when the server arm is applicable
    /// BUT the consent gate is not yet granted; the sheet surfaces a consent CTA
    /// instead of a dead kill-card. **v0.11 (AI-1):** also `true` for an explicit
    /// server pick on a capable device that hasn't consented yet — so the pick
    /// lands on the CTA rather than being silently re-routed to on-device.
    var serverFallbackNeedsConsent: Bool {
        guard serverService != nil else { return false }
        // Applicable when on-device can't serve OR the user explicitly chose the
        // server arm; either way an un-granted gate means "needs consent".
        guard !service.isReady || explicitlyPrefersServer else { return false }
        return serverConsentGate?() == false
    }

    /// `true` when sends should route through the server arm: a server service
    /// is wired, consent is granted, AND either the on-device model is not ready
    /// (legacy fallback) OR the user explicitly picked the server arm — in which
    /// case it wins even on an AI-capable device (AI-1). Fail-closed: an
    /// un-granted `serverConsentGate` returns `false` regardless of the pick, so
    /// nothing is transmitted off-device without the per-provider consent.
    var shouldUseServerFallback: Bool {
        guard serverService != nil else { return false }
        guard !service.isReady || explicitlyPrefersServer else { return false }
        return serverConsentGate?() ?? true
    }

    /// **C1 (b199 walkthrough) — seed the active-arm provenance pill BEFORE the
    /// first turn.** `usingServerFallback` / `usingBYO` were only latched inside
    /// the turn runners (`runServerTurn` / `runBYOTurn`), so the first paint of a
    /// server/BYO conversation showed the *on-device* pill until the user's first
    /// send flipped it — the jarring "it switched on me" the operator flagged.
    /// The view calls this when it routes to the conversation surface so the
    /// honest egress pill shows from first paint. Cheap; never flips a turn that
    /// is already in flight.
    func seedIntendedArm() {
        guard !isResponding else { return }
        if shouldUseBYO {
            setIntendedArm(server: false, byo: true)
        } else if shouldUseServerFallback {
            setIntendedArm(server: true, byo: false)
        } else {
            setIntendedArm(server: false, byo: false)
        }
    }
}
