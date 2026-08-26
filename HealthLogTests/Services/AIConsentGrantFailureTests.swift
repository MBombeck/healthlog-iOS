import Foundation
@testable import HealthLog
import Testing

/// **Audit v0162 — AI-consent grant persistence failures are handled.**
///
/// `grant(for:)` / `grantServerManaged()` used to log success unconditionally
/// after a silent `try?` Keychain write. The grant record IS the gate for
/// off-device PHI transmission (Apple 5.1.2(i)), so a write that failed to
/// persist must NOT report success — otherwise the picker shows a phantom
/// "granted" state with no backing record.
///
/// These tests inject a Keychain whose `setString` throws and assert the store
/// leaves `lastResult == false` (grant did not claim success) instead of the
/// former unconditional `lastResult = true`.
@MainActor
@Suite("AIConsentStore grant-failure handling")
struct AIConsentGrantFailureTests {
    /// Keychain double whose writes always fail; reads return nil. Enough to
    /// exercise the grant-write failure branch.
    private struct FailingKeychain: KeychainStoring {
        struct WriteError: Error {}
        func setString(_: String, forKey _: String) throws {
            throw WriteError()
        }

        func getString(forKey _: String) -> String? {
            nil
        }

        func setData(_: Data, forKey _: String) throws {
            throw WriteError()
        }

        func getData(forKey _: String) -> Data? {
            nil
        }

        func remove(forKey _: String) throws {}
        func removeAll() throws {}
    }

    @Test("grant(for:) does not report success when the Keychain write fails")
    func perProviderGrantFailureLeavesResultFalse() {
        let store = AIConsentStore(keychain: FailingKeychain())
        store.grant(for: .openai)
        // The write threw → the store must not have flipped to a granted state.
        #expect(store.lastResult == false)
        #expect(store.hasConsent(for: .openai) == false)
    }

    @Test("grantServerManaged() does not report success when the write fails")
    func serverManagedGrantFailureLeavesResultFalse() {
        let store = AIConsentStore(keychain: FailingKeychain())
        store.grantServerManaged()
        #expect(store.lastResult == false)
        #expect(store.hasServerManagedConsent() == false)
    }

    /// audit-release 05 C-3 — `grantBYO(for:)` used the same `try?`-then-report-
    /// success shape the two grants above were already fixed for. The BYO grant
    /// record IS the off-device-transmission gate (Apple 5.1.2(i): health data
    /// leaves the device to a third-party provider), so a failed Keychain write
    /// must NOT claim success.
    @Test("grantBYO(for:) does not report success when the Keychain write fails")
    func byoGrantFailureLeavesResultFalse() {
        let store = AIConsentStore(keychain: FailingKeychain())
        store.grantBYO(for: .anthropic)
        // The write threw → the store must not have flipped to a granted state.
        #expect(store.lastResult == false)
        #expect(store.hasBYOConsent(for: .anthropic) == false)
    }
}
