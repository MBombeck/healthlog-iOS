import Foundation

/// **#115 B5 — the account preferences an extension needs, shared per account.**
///
/// The app learns the account zone and the account glucose unit from
/// `/api/auth/me` and keeps them in its own `UserDefaults.standard`
/// (``ProfileTimeZoneBox``, `SettingsStore`). A widget or intent running in the
/// widget extension has its own `.standard` domain and saw neither: its day keys
/// fell back to the device zone (``ProfileDay``) and its glucose entry had no
/// unit to read but a hard-coded mg/dL.
///
/// This mirror puts both into the shared App-Group suite
/// (`group.dev.healthlog.app`, the same container the Outbox and
/// ``LockScreenPrivacy`` use), **scoped to one account**: every write stamps the
/// signed-in user id from the shared Keychain, and every read answers only when
/// that stamp matches the user id signed in right now. A value left behind by a
/// previous account therefore reads as "unknown", never as the next account's.
/// The logout cascade removes all three keys (``clear()``).
///
/// It is a CACHE of the server's answer, exactly like the app-scoped mirrors:
/// the source stays `/me`. A missing or mismatched entry means the caller uses
/// its old default (device zone, mg/dL).
public final class SharedAccountPrefs: Sendable {
    /// Shared App-Group identifier. Must match `WidgetAppGroup.identifier` and
    /// `LockScreenPrivacy.appGroupIdentifier`; duplicated as a constant so this
    /// Core type does not reach into `WidgetShared`.
    public static let appGroupIdentifier = "group.dev.healthlog.app"

    static let userIDKey = "hl.shared.account.userID"
    static let timeZoneKey = "hl.shared.account.timeZone"
    static let glucoseUnitKey = "hl.shared.account.glucoseUnit"
    /// #115 P2 — the account's unit system and the effective weight unit, so a
    /// spoken weight or temperature is taken in the unit the account reads.
    static let unitSystemKey = "hl.shared.account.unitSystem"
    static let weightUnitKey = "hl.shared.account.weightUnit"

    /// The live mirror: App-Group suite, user id from the shared Keychain (the
    /// same service every HealthLog process reads, see `KeychainStore.appService`).
    public static let live = SharedAccountPrefs(
        defaults: UserDefaults(suiteName: appGroupIdentifier) ?? .standard,
        currentUserID: { KeychainStore().getString(forKey: KeychainKey.userID) }
    )

    /// `nonisolated(unsafe)` for the same reason as ``ProfileTimeZoneBox``:
    /// `UserDefaults` is documented thread-safe but not `Sendable`.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let currentUserID: @Sendable () -> String?

    public init(defaults: UserDefaults, currentUserID: @escaping @Sendable () -> String?) {
        self.defaults = defaults
        self.currentUserID = currentUserID
    }

    // MARK: - Reads (account-checked)

    /// The account zone the app last resolved, or `nil` when there is none for
    /// the account signed in now (no entry, another account's entry, signed out,
    /// or an identifier this device cannot resolve).
    public func timeZone() -> TimeZone? {
        guard let raw = value(forKey: Self.timeZoneKey) else { return nil }
        return TimeZone(identifier: raw)
    }

    /// The account glucose unit the app last adopted, or `nil` when unknown for
    /// the account signed in now.
    public func glucoseUnit() -> GlucoseUnit? {
        value(forKey: Self.glucoseUnitKey).flatMap(GlucoseUnit.init(rawValue:))
    }

    /// #115 P2 — the account's unit system, or `nil` when unknown for the
    /// account signed in now.
    public func unitSystem() -> HLUnitPreference? {
        value(forKey: Self.unitSystemKey).flatMap(HLUnitPreference.init(rawValue:))
    }

    /// #115 P2 — the effective weight unit (the device override, else the
    /// unit system's), or `nil` when unknown for the account signed in now.
    public func weightUnit() -> WeightUnit? {
        value(forKey: Self.weightUnitKey).flatMap(WeightUnit.init(rawValue:))
    }

    // MARK: - Writes (app process)

    /// Record the account zone. No-op without a signed-in user (standalone,
    /// mid-logout): there is no account to scope it to.
    public func setTimeZone(_ zone: TimeZone) {
        set(zone.identifier, forKey: Self.timeZoneKey)
    }

    /// Record the account glucose unit. No-op without a signed-in user.
    public func setGlucoseUnit(_ unit: GlucoseUnit) {
        set(unit.rawValue, forKey: Self.glucoseUnitKey)
    }

    /// #115 P2 — record the unit system and the effective weight unit. No-op
    /// without a signed-in user.
    public func setAccountUnits(system: HLUnitPreference, weight: WeightUnit) {
        set(system.rawValue, forKey: Self.unitSystemKey)
        set(weight.rawValue, forKey: Self.weightUnitKey)
    }

    /// Logout: the entries belong to the account that is leaving.
    public func clear() {
        for key in [Self.userIDKey, Self.timeZoneKey, Self.glucoseUnitKey, Self.unitSystemKey, Self.weightUnitKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private

    private func value(forKey key: String) -> String? {
        guard let user = currentUserID(), !user.isEmpty,
              defaults.string(forKey: Self.userIDKey) == user else { return nil }
        return defaults.string(forKey: key)
    }

    private func set(_ value: String, forKey key: String) {
        guard let user = currentUserID(), !user.isEmpty else { return }
        // A different account's leftovers must not survive under the new stamp:
        // re-stamping alone would hand them to this account.
        if defaults.string(forKey: Self.userIDKey) != user {
            clear()
            defaults.set(user, forKey: Self.userIDKey)
        }
        defaults.set(value, forKey: key)
    }
}
