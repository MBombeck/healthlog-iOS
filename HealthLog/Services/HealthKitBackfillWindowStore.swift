import Foundation

/// Persistierung des HealthKitBackfillWindow per-User in UserDefaults.
///
/// Schluessel-Shape: `hl.healthkit.backfillWindow.<userId-token>`. Die
/// Per-User-Partitionierung folgt dem gleichen Pattern wie HK-Anchors
/// (siehe `HealthKitService.partitionToken`) — gleicher Trade-Off (UserDefaults
/// statt Keychain, weil das Window kein Secret ist und Battery-Cost zaehlt).
///
/// **Re-Install-Verhalten:** UserDefaults wird mit dem App-Bundle deinstalliert,
/// also macht ein Re-Install + restored Keychain auch ein fresh-onboarding inkl.
/// neuer Window-Wahl. Bewusst nicht in den Server gepusht — die Wahl ist
/// device-spezifisch (Apple Watch sync vs iPhone-only User), Server-side wuerde
/// es nur Verwirrung schaffen.
enum HealthKitBackfillWindowStore {
    static let defaultsKeyPrefix = "hl.healthkit.backfillWindow."

    /// Persist die User-Wahl. nil-userId → Anonymous-Partition (z. B. wenn der
    /// Picker im Pre-Login-Onboarding gesetzt wird; nach erfolgreichem Login
    /// wird der Wert beim naechsten activate-Run mit der echten User-ID
    /// re-keyed — den Migrations-Pfad implementieren wir wenn der Use-Case
    /// auftaucht; aktuell ruft das Onboarding HK-Permissions VOR Auth ab,
    /// also matched Anonymous-Partition den State im first-launch-Flow).
    static func persist(
        _ window: HealthKitBackfillWindow,
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) {
        let userId = keychain.getString(forKey: KeychainKey.userID)
        let key = key(for: userId)
        defaults.set(window.rawValue, forKey: key)
    }

    /// Lade die User-Wahl. Liefert `nil` wenn noch nichts persistiert wurde
    /// (Pre-Onboarding) ODER wenn der persistierte rawValue nicht mehr im Enum
    /// vorhanden ist (Forward-Compat-Drift — sollte nie auftreten, defensiv
    /// trotzdem sauber).
    static func load(
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) -> HealthKitBackfillWindow? {
        let userId = keychain.getString(forKey: KeychainKey.userID)
        let key = key(for: userId)
        guard let raw = defaults.string(forKey: key) else { return nil }
        return HealthKitBackfillWindow(rawValue: raw)
    }

    /// Loescht die persistierte Wahl. Wird vom AuthStore-Logout-Cleanup
    /// aufgerufen, damit ein Re-Login mit anderem Account die Wahl des
    /// vorigen Users nicht uebernimmt.
    static func clear(
        for userId: String?,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(for: userId))
    }

    /// Test-Hook: erzeugt den Schluessel ohne Side-Effects. Internal.
    static func key(for userId: String?) -> String {
        defaultsKeyPrefix + partitionToken(for: userId)
    }

    /// Mirror der `HealthKitService.partitionToken`-Logik — bewusst dupliziert
    /// statt cross-importiert, damit der Store iOS-frei (kein HealthKit-Import)
    /// kompiliert und in HealthLogCore lebt. Drift-Test in
    /// `HealthKitBackfillWindowStoreTests` lockt die Konvention.
    ///
    /// **M-6 hardening (v0.6.2):** the legacy implementation only stripped
    /// dots + trimmed whitespace, so a user-id containing `/` or `..` would
    /// have survived into the UserDefaults key (`hl.healthkit.backfillWindow.<token>`).
    /// We now apply a strict allowlist (`[A-Za-z0-9_-]`) + cap at 64 chars.
    /// Any character outside the allowlist is dropped (not replaced — a
    /// replacement char would still be predictable across inputs and could
    /// alias two distinct user-ids onto the same partition; dropping keeps
    /// the partition shape determined by the surviving safe chars only).
    /// Empty result after filtering falls back to `_anonymous`.
    static func partitionToken(for userId: String?) -> String {
        guard let raw = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "_anonymous"
        }
        let filtered = raw.unicodeScalars.lazy.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F // _
                || scalar.value == 0x2D // -
        }
        let sanitized = String(String.UnicodeScalarView(filtered))
        guard !sanitized.isEmpty else { return "_anonymous" }
        return String(sanitized.prefix(64))
    }
}
