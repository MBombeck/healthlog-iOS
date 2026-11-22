import SwiftUI

/// G1/G7 — the medical-disclaimer gate that sits in FRONT of
/// the authenticated shell. Split out of `RootView.swift` (file_length
/// discipline — PROJECT_GUIDE.md): pure relocation of the gate decision + the
/// phase-routed read/acknowledge helpers, no behaviour change.
///
/// **Timing:** the disclaimer ack is acknowledged BEFORE the product is
/// usable, matching web ("acknowledge on Get-started, before the wizard
/// proceeds"). `RootView.rootBody` renders the blocking `MedicalDisclaimerAckSheet`
/// INSTEAD of `AuthenticatedShell` while `needsDisclaimerGate` is true, so the
/// shell is never constructed behind the gate.
extension RootView {
    /// Resolve the one-time medical-disclaimer acknowledgment state on the
    /// authentication tick. Drives the BEFORE-shell gate AND the app-wide
    /// suppression of the scattered per-screen informational disclaimers.
    ///
    /// - Authenticated (server): reads `disclaimerAcknowledgedAt` off
    ///   `/api/auth/me`. Fail-soft inside the store (a network blip leaves the
    ///   state unchanged; the gate also keys on `hasLoaded`), so a transient
    ///   `/me` error never locks the user out.
    func refreshDisclaimerAckIfReady() async {
        switch authStore.phase {
        case .authenticated:
            await disclaimerAck.refresh()
        case .unknown, .unauthenticated, .authenticating:
            break
        }
    }

    /// Whether the medical-disclaimer gate must sit in FRONT of the shell. True
    /// only once the ack read RESOLVED (`hasLoaded`) and the resolved value is a
    /// definitive not-acknowledged. Fail-soft: a transient `/me` error leaves
    /// `hasLoaded` unchanged, so the gate never shows on a blip (the user is never
    /// locked out).
    var needsDisclaimerGate: Bool {
        switch authStore.phase {
        case .authenticated:
            DisclaimerAckStore.shouldGate(
                hasLoaded: disclaimerAck.hasLoaded,
                isAcknowledged: disclaimerAck.isAcknowledged
            )
        case .unknown, .unauthenticated, .authenticating:
            false
        }
    }

    /// Acknowledge the disclaimer server-side for the authenticated user.
    /// `isAcknowledged` flips and the gate dismisses, mounting the shell.
    func acknowledgeDisclaimer() async {
        switch authStore.phase {
        case .authenticated:
            await disclaimerAck.acknowledge()
        case .unknown, .unauthenticated, .authenticating:
            break
        }
    }
}
