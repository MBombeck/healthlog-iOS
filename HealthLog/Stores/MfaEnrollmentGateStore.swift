import Foundation
import Observation

/// Forced second-factor enrolment state (parity item 2.3).
///
/// Web ships `/enroll-mfa` (`src/app/enroll-mfa/page.tsx:22-64`) as an
/// interstitial the proxy redirects to whenever the operator mandates MFA and
/// the account has no active second factor. iOS had no counterpart at all, so on
/// such an instance the app was **unusable**: every surface worked, nothing told
/// the user why the operator expected a second factor, and there was no path to
/// enrol one. This store drives the equivalent modal gate.
///
/// **No persistence.** The requirement is server-derived and re-read on every
/// authentication tick, exactly like `DisclaimerAckStore`'s server path. Caching
/// it would let a lifted policy keep gating, or a newly-applied one stay
/// invisible.
@MainActor
@Observable
public final class MfaEnrollmentGateStore {
    /// `true` when the server says this account must enrol a second factor.
    public private(set) var isRequired: Bool = false
    /// Whether the first resolve has completed. The gate waits on this so it
    /// never flashes before the server answers.
    public private(set) var hasLoaded: Bool = false
    public private(set) var error: HLError?

    private let repo: MfaEnrollmentRepository

    public init(repo: MfaEnrollmentRepository) {
        self.repo = repo
    }

    /// Refresh from the server. **Fail-soft in the safe direction:** a network
    /// error leaves `isRequired` untouched and does NOT set `hasLoaded`, so a
    /// blip can never raise the gate on a healthy account. See
    /// `MfaEnrollmentRepository` for why fail-open is the correct bias here.
    public func refresh() async {
        error = nil
        do {
            isRequired = try await repo.fetchEnrollmentRequired()
            hasLoaded = true
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearError() {
        error = nil
    }

    public func clearOnLogout() {
        isRequired = false
        hasLoaded = false
        error = nil
    }

    /// Test-only seam — set the resolved state without a round-trip, mirroring
    /// `DisclaimerAckStore.seedForTesting`.
    func seedForTesting(isRequired: Bool, hasLoaded: Bool) {
        self.isRequired = isRequired
        self.hasLoaded = hasLoaded
    }

    /// Pure gate decision, extracted `static` (the `DisclaimerAckStore
    /// .shouldGate` precedent) so the before-the-product gating contract is
    /// unit-testable without standing up the view tree.
    ///
    /// The gate shows iff the resolve COMPLETED and the resolved answer is a
    /// definitive "required". While `hasLoaded` is false — first read pending,
    /// or a transient error left it untouched — the gate stays DOWN.
    public nonisolated static func shouldGate(hasLoaded: Bool, isRequired: Bool) -> Bool {
        hasLoaded && isRequired
    }
}
