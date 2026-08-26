import Foundation
import Observation

/// App-wide one-time medical-disclaimer acknowledgment state (v1.18.6 / DISC-02).
///
/// **Server path: in-memory cache only** — for an authenticated user the
/// authoritative value lives on the user row (`User.disclaimerAcknowledgedAt`),
/// re-read from `GET /api/auth/me`. No Keychain / UserDefaults persistence on
/// that path: a server-side disclaimer reset must be able to re-prompt, and
/// keeping the server the single source of truth is what makes that possible.
///
/// **Standalone path (G1): local UserDefaults flag** — standalone mode has no
/// server, so there is no user row to stamp. The acknowledgment is persisted
/// locally (`standaloneAckKey`). This path is only reachable when the standalone
/// entry is enabled (`FeatureFlags.standaloneModeAvailable`).
///
/// **UI-Standard R15 (U1):** dieser Store trägt nur noch das blockierende Gate
/// vor der App (`RootView+DisclaimerGate`). Der v1.18.6-Zwischenschritt, seinen
/// Zustand als `\.medicalDisclaimerAcknowledged` in die Environment zu
/// injizieren und sechs Flächen ihre Hinweise ausblenden zu lassen, ist
/// entfallen — die Hinweise selbst sind gefallen bzw. auf ihre Zuschreibung
/// gekürzt, es gibt also nichts mehr zu unterdrücken. Der Pauschaltext lebt an
/// genau zwei Orten: hier und in Einstellungen → Über diese App.
@MainActor
@Observable
public final class DisclaimerAckStore {
    /// The copy version the client renders, echoed to the server as a freshness
    /// signal. Kept in lockstep with the server's `DISCLAIMER_VERSION` and the
    /// `onboarding.disclaimer.*` copy. Bump on a substantive wording change.
    public nonisolated static let clientDisclaimerVersion = "2026-06-18"

    /// `true` once the server confirms an acknowledgment. `nil`-timestamp ⇒
    /// `false`. Drives both the one-time gate AND the app-wide suppression.
    public private(set) var isAcknowledged: Bool = false
    /// Whether the first `/me` read has completed. The one-time gate waits on
    /// this so it never flashes the sheet before the server answers.
    public private(set) var hasLoaded: Bool = false
    public private(set) var isAcknowledging: Bool = false
    public private(set) var error: HLError?

    private let repo: DisclaimerAckRepository
    private let defaults: UserDefaults

    /// G1 (AUDIT-ONBOARDING) — local standalone acknowledgment flag. Standalone
    /// has NO server, so the server `disclaimerAcknowledgedAt` round-trip is
    /// impossible; the not-a-medical-device / not-for-diagnosis disclaimer is
    /// instead acknowledged locally and persisted here. Per-install only (no
    /// iCloud), mirroring `SyncModeStore`'s UI-routing-prefs rationale — the
    /// acknowledgment is a local routing decision when there is no user row to
    /// stamp. This path is only ever exercised when the app is in standalone
    /// mode (the entry to which is itself gated behind
    /// `FeatureFlags.standaloneModeAvailable`); the server path is untouched.
    public nonisolated static let standaloneAckKey = "hl.disclaimer.standaloneAckVersion"

    public init(repo: DisclaimerAckRepository, defaults: UserDefaults = .standard) {
        self.repo = repo
        self.defaults = defaults
    }

    /// Refresh acknowledgment state from the server. Fail-soft: a network error
    /// leaves `isAcknowledged` unchanged (we never force the sheet on a transient
    /// blip — the gate also keys on `hasLoaded`).
    public func refresh() async {
        // UI-test seam (`-uitest-ack-disclaimer`): the demo tenant runs in a
        // read-only "modifications disabled" mode, so the acknowledge() POST can
        // never succeed there and the gesture-undismissible gate would block
        // every marketing/walkthrough capture forever. This flag forces the
        // acknowledged state without a round-trip. Mirrors the existing
        // `-uitest-*` launch seams. W-RECONCILE MED-1: DEBUG-gated so this
        // compliance-gate bypass cannot exist in a shipping (Release) build.
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-ack-disclaimer") {
                isAcknowledged = true
                hasLoaded = true
                error = nil
                return
            }
        #endif
        error = nil
        do {
            let at = try await repo.fetchAcknowledgedAt()
            isAcknowledged = (at != nil)
            hasLoaded = true
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Acknowledge the one-time disclaimer. Optimistically flips `isAcknowledged`
    /// on success so the gate dismisses immediately.
    public func acknowledge() async {
        guard !isAcknowledging else { return }
        isAcknowledging = true
        error = nil
        defer { isAcknowledging = false }
        do {
            _ = try await repo.acknowledge(version: Self.clientDisclaimerVersion)
            isAcknowledged = true
            hasLoaded = true
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    // MARK: - Standalone (local) path — G1 (AUDIT-ONBOARDING)

    /// Load the local standalone acknowledgment state. Standalone has no server,
    /// so there is no `/me` to read — the flag lives in `UserDefaults`. Never
    /// fails (a local read can't blip), so `hasLoaded` always becomes `true`,
    /// which is what gates the standalone disclaimer in front of the shell.
    public func refreshStandalone() {
        // W-RECONCILE MED-1: DEBUG-gated bypass (see `refresh()`).
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-ack-disclaimer") {
                isAcknowledged = true
                hasLoaded = true
                error = nil
                return
            }
        #endif
        error = nil
        isAcknowledged = defaults.string(forKey: Self.standaloneAckKey) != nil
        hasLoaded = true
    }

    /// Acknowledge the disclaimer in standalone (local) mode. Persists the copy
    /// version to `UserDefaults` and flips `isAcknowledged` so the local gate
    /// dismisses immediately. No network — cannot fail.
    public func acknowledgeStandalone() {
        guard !isAcknowledging else { return }
        isAcknowledging = true
        error = nil
        defer { isAcknowledging = false }
        defaults.set(Self.clientDisclaimerVersion, forKey: Self.standaloneAckKey)
        isAcknowledged = true
        hasLoaded = true
    }

    public func clearOnLogout() {
        isAcknowledged = false
        hasLoaded = false
        isAcknowledging = false
        error = nil
        // G1 — purge the local standalone flag too so a subsequent standalone
        // user on the same install re-acknowledges (parity with the server path,
        // where the next user re-reads their own `/me`).
        defaults.removeObject(forKey: Self.standaloneAckKey)
    }

    /// Test-only — set the acknowledgment state without a network round-trip so
    /// the logout-wipe suite can prove `clearOnLogout` purges it (DISC-02).
    func seedForTesting(isAcknowledged: Bool, hasLoaded: Bool) {
        self.isAcknowledged = isAcknowledged
        self.hasLoaded = hasLoaded
    }

    /// G7 (AUDIT-ONBOARDING) — pure gate decision used by `RootView` to decide
    /// whether the medical-disclaimer must sit in FRONT of the shell. Extracted
    /// `static` (mirroring `OnboardingFlow.stepAfterWelcome`) so the
    /// before-the-product gating + its fail-soft contract is unit-testable
    /// without standing up the view tree.
    ///
    /// The gate shows iff the ack read RESOLVED (`hasLoaded == true`) and the
    /// resolved value is a definitive not-acknowledged. While `hasLoaded` is
    /// `false` (read not yet returned, OR a transient `/me` error left it
    /// untouched), the gate stays DOWN — a network blip can never lock the user
    /// out, and the gate never flashes before the server answers.
    public nonisolated static func shouldGate(hasLoaded: Bool, isAcknowledged: Bool) -> Bool {
        hasLoaded && !isAcknowledged
    }
}
