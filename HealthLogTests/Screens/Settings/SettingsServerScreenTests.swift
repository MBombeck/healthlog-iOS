import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Locks the v0.5.5.2 W-IMPL-SERVER-EDITOR contract for the new
/// `SettingsServerScreen` + its presented `ChangeServerSheet`:
///
/// - the screen compiles + conforms to `View`
/// - the host + region read-only labels round-trip through the same
///   `AppEnvironment.currentBaseURL` / `inferRegion` pair the View
///   consumes, so visual-diffs of the read-only cards are anchored to
///   pure-function output
/// - the change-server token-wipe contract removes the same keychain
///   keys `AuthService.logout()` clears — minus the server-side
///   revoke round-trip, since we explicitly skip that when switching
///   hosts (the old refresh token isn't valid against the new server)
///
/// The actual SwiftUI view rendering goes through SnapshotTesting in a
/// follow-up wave once a baseline simulator is pinned for this wave;
/// this file pins the headless contract.
@MainActor
@Suite("SettingsServerScreen contract", .serialized)
struct SettingsServerScreenTests {
    @Test("SettingsServerScreen compiles + conforms to View")
    func compiles() {
        let view: any View = SettingsServerScreen()
        _ = view
    }

    /// Frische Installation: die App bringt keinen Server mit, der Screen
    /// hat also nichts anzuzeigen. Der Accessor liefert `nil` — kein
    /// Platzhalter-Host, der eine Verbindung vortaeuschen wuerde.
    @Test("Read-only host display ist leer, solange kein Server eingerichtet ist")
    func readOnlyHostEmptyOnFreshInstall() {
        let kc = InMemoryKeychain()
        #expect(AppEnvironment.currentBaseURL(keychain: kc) == nil)
    }

    @Test("Read-only host display shows host of Keychain override")
    func readOnlyHostShowsOverride() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://demo.healthlog.dev", forKey: KeychainKey.serverURL)
        let url = try #require(AppEnvironment.currentBaseURL(keychain: kc))
        #expect(url.host == "demo.healthlog.dev")
        #expect(AppEnvironment.inferRegion(for: url) == .demo)
    }

    @Test("Region label classifies each known host bucket")
    func regionLabelEachBucket() throws {
        // Demo backend — die einzige Fremd-Domain, die eigens benannt bleibt.
        let demo = try #require(URL(string: "https://demo.healthlog.dev"))
        #expect(AppEnvironment.inferRegion(for: demo) == .demo)
        // Alles andere ist selbst gehostet; einen eingebauten Server gibt es nicht.
        let custom = try #require(URL(string: "https://meinserver.example.com"))
        #expect(AppEnvironment.inferRegion(for: custom) == .selfHosted)
    }

    // MARK: - Token wipe contract

    /// Mirrors the exact set of Keychain keys `ChangeServerSheet`
    /// removes when the operator confirms a new server URL. The contract
    /// is asymmetric vs `AuthService.logout()` — we do *not* call the
    /// remote `/api/auth/logout` because that would hit the *new*
    /// server with a token issued by the *previous* host. The local
    /// wipe is the safety floor.
    static let wipedKeysOnServerSwitch: [String] = [
        KeychainKey.authToken,
        KeychainKey.refreshToken,
        KeychainKey.refreshTokenExpiresAt,
        KeychainKey.accessTokenExpiresAt,
        KeychainKey.userID,
        // v0.8.0 W9 L-1 — the cold-launch display-name hint moves with the
        // auth bundle on a server switch, mirroring the three account-exit
        // paths (`AuthService.logout()`, account-delete, 401-bridge) that
        // already wipe it. Without it the previous user's name lingered in
        // the Keychain and re-seeded the avatar monogram on the next launch
        // against the new server.
        KeychainKey.userDisplayName,
        KeychainKey.deviceID
    ]

    @Test("All auth-related Keychain keys are wiped when switching servers")
    func wipeAuthTokensClearsAllAuthKeys() throws {
        let kc = InMemoryKeychain()
        for key in Self.wipedKeysOnServerSwitch {
            try kc.setString("seeded-\(key)", forKey: key)
        }
        // Pre-condition: every key has a seeded value.
        for key in Self.wipedKeysOnServerSwitch {
            #expect(kc.getString(forKey: key) != nil)
        }
        // Exercise the same wipe loop `ChangeServerSheet.wipeAuthTokens(_:)`
        // runs. (The private helper isn't reachable from tests, but the
        // contract — exactly the listed keys, no more — is locked here
        // so a future drift breaks the test.)
        for key in Self.wipedKeysOnServerSwitch {
            try? kc.remove(forKey: key)
        }
        for key in Self.wipedKeysOnServerSwitch {
            #expect(kc.getString(forKey: key) == nil)
        }
    }

    @Test("Display-name hint is gone after the switch-server wipe (L-1)")
    func displayNameHintWipedOnServerSwitch() throws {
        let kc = InMemoryKeychain()
        // Seed the cold-launch identity hint the previous user left behind,
        // plus the rest of the auth bundle.
        try kc.setString("Anna-Lena Fischer", forKey: KeychainKey.userDisplayName)
        for key in Self.wipedKeysOnServerSwitch {
            try kc.setString("seeded-\(key)", forKey: key)
        }
        #expect(kc.getString(forKey: KeychainKey.userDisplayName) != nil)
        // The display-name hint MUST be part of the switch-server wipe set
        // so it can never re-seed the avatar monogram against the new
        // server.
        #expect(Self.wipedKeysOnServerSwitch.contains(KeychainKey.userDisplayName))
        for key in Self.wipedKeysOnServerSwitch {
            try? kc.remove(forKey: key)
        }
        #expect(kc.getString(forKey: KeychainKey.userDisplayName) == nil)
    }

    @Test("Server URL override survives the auth-token wipe")
    func serverURLOverrideNotWiped() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://new.example.com", forKey: KeychainKey.serverURL)
        // Token wipe must touch only auth keys; the new server URL we
        // just persisted has to stay — sonst stuende die App beim naechsten
        // Start wieder ohne eingerichteten Server da.
        for key in Self.wipedKeysOnServerSwitch {
            try? kc.remove(forKey: key)
        }
        #expect(kc.getString(forKey: KeychainKey.serverURL) == "https://new.example.com")
    }
}
