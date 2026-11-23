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
/// **UI-Standard R15:** dieser Store trägt nur noch das blockierende Gate
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

    public init(repo: DisclaimerAckRepository) {
        self.repo = repo
    }

    #if DEBUG
        /// The UI-test override of the acknowledgment state, or `nil` when no
        /// launch argument asks for one.
        ///
        /// `-uitest-ack-disclaimer` forces ACKNOWLEDGED: the demo tenant runs
        /// read-only, so `acknowledge()`'s POST can never succeed there and the
        /// gesture-undismissible gate would block every capture run forever.
        ///
        /// `-uitest-disclaimer-unacked` (1.0.3, App Review 1.4.1) forces the
        /// opposite, and is the ONLY way to photograph the first-launch
        /// disclaimer sheet hermetically: the hermetic `/api/auth/me` fixture
        /// stamps the acknowledgment, so the gate is always already satisfied.
        /// The reviewer's first screen carries the app's first pointer at the
        /// medical-sources hub, which is evidence the 1.4.1 reply needs.
        /// Refusal wins over forcing if both are passed, so an existing test
        /// that inherits the ack flag can never be flipped by accident.
        ///
        /// DEBUG-gated, so neither compliance-gate override
        /// exists in a shipping (Release) build.
        static var uiTestForcedAcknowledgment: Bool? {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uitest-disclaimer-unacked") { return false }
            if args.contains("-uitest-ack-disclaimer") { return true }
            return nil
        }
    #endif

    /// Refresh acknowledgment state from the server. Fail-soft: a network error
    /// leaves `isAcknowledged` unchanged (we never force the sheet on a transient
    /// blip — the gate also keys on `hasLoaded`).
    public func refresh() async {
        // UI-test seam — see `uiTestForcedAcknowledgment` above.
        #if DEBUG
            if let forced = Self.uiTestForcedAcknowledgment {
                isAcknowledged = forced
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

    public func clearOnLogout() {
        isAcknowledged = false
        hasLoaded = false
        isAcknowledging = false
        error = nil
    }

    /// Test-only — set the acknowledgment state without a network round-trip so
    /// the logout-wipe suite can prove `clearOnLogout` purges it.
    func seedForTesting(isAcknowledged: Bool, hasLoaded: Bool) {
        self.isAcknowledged = isAcknowledged
        self.hasLoaded = hasLoaded
    }

    /// Pure gate decision used by `RootView` to decide
    /// whether the medical-disclaimer must sit in FRONT of the shell. Extracted
    /// `static` so the
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
