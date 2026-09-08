import Foundation
@testable import HealthLog
import Testing

/// **v1.38.11 — "Sign out everywhere" stopped taking this device with it.**
///
/// `DELETE /api/auth/me/sessions` used to revoke every unrevoked `RefreshToken`
/// for the user with no caller exclusion, so a native caller signed itself out
/// too and the copy under `sessions.signOutAll.*` said so. From server v1.38.11
/// a Bearer caller is spared and only the OTHER devices' refresh and access
/// tokens fall. A self-hosted instance below that keeps the old behaviour, so
/// the wording has to follow the server — which is what this threshold decides.
///
/// Mirrors the shape of the sibling gates (`TwoFactorManagement`,
/// `WebHandoffLogin`, `MedicationSlotMaterialization`): a dotted-integer
/// threshold plus the fail-closed contract on an unreadable version.
@Suite("v1.38.11 — Server verschont das rufende Gerät ab 1.38.11")
struct SignOutEverywhereElseGateTests {
    /// The boundary itself, plus one build on either side and a `v`-prefixed
    /// spelling (the `/api/version` payload is not guaranteed to be bare).
    @Test(
        "threshold — the calling device is spared from v1.38.11 upward",
        arguments: [
            ("1.37.0", false),
            ("1.38.9", false),
            ("1.38.10", false),
            ("1.38.11", true),
            ("1.38.12", true),
            ("1.39.0", true),
            ("2.0.0", true),
            ("v1.38.11", true)
        ]
    )
    func thresholdVerdict(version: String, spares: Bool) {
        let info = ServerVersionInfo(version: version)
        #expect(SignOutEverywhereElse.sparesThisDevice(on: info) == spares)
    }

    /// An unreadable running version is "not known ≥ target". Closed here means
    /// the app keeps the OLD, harsher copy — which is the honest direction: a
    /// warning that this device may be signed out too costs the user a re-login
    /// at worst, while the reverse promise would be a lie.
    @Test("threshold — an unparseable version fails closed (keeps the honest old copy)")
    func unparseableVersionFailsClosed() {
        #expect(SignOutEverywhereElse.sparesThisDevice(on: ServerVersionInfo(version: "")) == false)
        #expect(SignOutEverywhereElse.sparesThisDevice(on: ServerVersionInfo(version: "unknown")) == false)
        #expect(SignOutEverywhereElse.sparesThisDevice(on: ServerVersionInfo(version: "dev")) == false)
    }

    /// Pins the documented boundary so a later edit cannot drift the constant
    /// away from the server release it names.
    @Test("threshold — the constant is the documented server release")
    func thresholdConstantIsPinned() {
        #expect(SignOutEverywhereElse.minimumServerVersion == "1.38.11")
    }
}
