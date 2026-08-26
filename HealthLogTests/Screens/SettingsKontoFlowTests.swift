import Foundation
@testable import HealthLog
import Testing

/// Locks the Konto-section destructive-flow contract per M2-A3 §5.4:
///
/// - "Abmelden" routes to `AuthStore.logout()` (no confirmation sheet —
///   sign-out is recoverable since data stays on the server).
/// - "Konto löschen" routes through a `DeleteAccountScreen` sheet with
///   two-step type-confirm — never a one-tap `NavigationLink` (the previous
///   pattern leaked a gray chevron and didn't tint the row).
///
/// These tests assert at the *interface level* — we verify the symbols exist
/// with the expected signatures rather than driving the SwiftUI hierarchy
/// (which is fragile and brings the test back into pixel-snapshot territory).
@Suite("Settings Konto flow")
struct SettingsKontoFlowTests {
    @Test("AuthStore.logout is async and discardable")
    @MainActor
    func logoutSignature() {
        // Compile-time check: this is the only contract SettingsScreen
        // depends on for the sign-out row.
        let probe: @MainActor (AuthStore) async -> Void = { store in
            await store.logout()
        }
        #expect(type(of: probe) == ((AuthStore) async -> Void).self ||
            type(of: probe) == (@MainActor (AuthStore) async -> Void).self)
    }

    @Test("DeleteAccountScreen exposes type-confirm accessibility identifiers")
    @MainActor
    func deleteAccountScreenAccessibility() {
        // The Konto-löschen row presents this screen via `.sheet`. The
        // identifiers are the contract UITests will assert against.
        // `DeleteAccountScreen: View` is implicitly `@MainActor`, so its
        // static constants are MainActor-isolated under Swift 6 strict
        // concurrency — the test must be `@MainActor` too.
        #expect(!DeleteAccountScreen.consentToggleIdentifier.isEmpty)
        #expect(!DeleteAccountScreen.continueButtonIdentifier.isEmpty)
        #expect(!DeleteAccountScreen.confirmFieldIdentifier.isEmpty)
        #expect(!DeleteAccountScreen.deleteButtonIdentifier.isEmpty)
    }

    @Test("AuthStore.deleteAccount returns Bool so caller can branch on success")
    @MainActor
    func deleteAccountSignature() {
        let probe: @MainActor (AuthStore) async -> Bool = { store in
            await store.deleteAccount()
        }
        // Compile-time only — if AuthStore.deleteAccount() ever changes its
        // signature (e.g. throws instead of returning Bool), this fails to
        // compile and we know the Konto-section flow needs revisiting.
        _ = probe
    }
}
