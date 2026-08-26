import SwiftUI

/// G1/G7 (AUDIT-ONBOARDING) — the medical-disclaimer gate that sits in FRONT of
/// the authenticated/standalone shell. Split out of `RootView.swift` (file_length
/// discipline — PROJECT_GUIDE.md): pure relocation of the gate decision + the
/// phase-routed read/acknowledge helpers, no behaviour change.
///
/// **Timing (G7):** the disclaimer ack is acknowledged BEFORE the product is
/// usable, matching web ("acknowledge on Get-started, before the wizard
/// proceeds"). `RootView.rootBody` renders the blocking `MedicalDisclaimerAckSheet`
/// INSTEAD of `AuthenticatedShell` while `needsDisclaimerGate` is true, so the
/// shell is never constructed behind the gate.
///
/// **Standalone (G1):** the gate covers BOTH the server-authed and the standalone
/// entry. The standalone branch reads/writes a local UserDefaults flag (no server
/// to stamp); it is only reachable when standalone is enabled
/// (`FeatureFlags.standaloneModeAvailable`, false today), so the wiring is correct
/// the instant that flag flips back on — no dead/foot-gun path.
extension RootView {
    /// Resolve the one-time medical-disclaimer acknowledgment state on the
    /// authentication tick. Drives the BEFORE-shell gate AND the app-wide
    /// suppression of the scattered per-screen informational disclaimers.
    ///
    /// - Authenticated (server): reads `disclaimerAcknowledgedAt` off
    ///   `/api/auth/me`. Fail-soft inside the store (a network blip leaves the
    ///   state unchanged; the gate also keys on `hasLoaded`), so a transient
    ///   `/me` error never locks the user out.
    /// - Standalone (no server): reads the local UserDefaults flag — there is no
    ///   `/me` to ask, so the disclaimer is acknowledged + persisted locally.
    func refreshDisclaimerAckIfReady() async {
        switch authStore.phase {
        case .authenticated:
            await disclaimerAck.refresh()
        case .standalone:
            disclaimerAck.refreshStandalone()
        case .unknown, .unauthenticated, .authenticating:
            break
        }
    }

    /// Whether the medical-disclaimer gate must sit in FRONT of the shell. True
    /// only once the ack read RESOLVED (`hasLoaded`) and the resolved value is a
    /// definitive not-acknowledged. Fail-soft: a transient `/me` error leaves
    /// `hasLoaded` unchanged, so the gate never shows on a blip (the user is never
    /// locked out). Covers BOTH the authenticated (server) and the standalone
    /// (local) entry.
    var needsDisclaimerGate: Bool {
        switch authStore.phase {
        case .authenticated, .standalone:
            DisclaimerAckStore.shouldGate(
                hasLoaded: disclaimerAck.hasLoaded,
                isAcknowledged: disclaimerAck.isAcknowledged
            )
        case .unknown, .unauthenticated, .authenticating:
            false
        }
    }

    /// Acknowledge the disclaimer through the path that matches the current
    /// phase: server-persisted for the authenticated user, local-persisted for
    /// the standalone user (no server). Either way `isAcknowledged` flips and the
    /// gate dismisses, mounting the shell.
    func acknowledgeDisclaimer() async {
        switch authStore.phase {
        case .authenticated:
            await disclaimerAck.acknowledge()
        case .standalone:
            disclaimerAck.acknowledgeStandalone()
        case .unknown, .unauthenticated, .authenticating:
            break
        }
    }
}
