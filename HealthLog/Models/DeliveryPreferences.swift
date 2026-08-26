import Foundation

/// **v0.9.0 RA3 (Option B) — unified per-medication delivery-preference
/// model.**
///
/// Supersedes the two stand-alone, device-local opt-in stores
/// (`LiveActivityPreferences` + the planned `CriticalAlarmPreferences`)
/// with one scoped abstraction that is **sync-ready** without yet
/// requiring any server work.
///
/// Each delivery pref (Live Activity, AlarmKit critical alarm) is resolved
/// as `localOverride ?? serverDefault ?? hardcodedDefault`. Today the
/// server-default layer is a no-op stub (`NoServerDeliveryDefaults`), so
/// the effective value is purely the local override — i.e. behaviour is
/// identical to the pre-v0.9.0 `LiveActivityPreferences`. When the server
/// fields land (SB-LA-1 / SB-AK-1) the stub is swapped for the real repo
/// and the "Alle Geräte" scope lights up with **no View / call-site
/// change**.
public enum DeliveryChannel: String, Codable, Sendable, CaseIterable, Hashable {
    /// Lock-Screen / Dynamic-Island dose countdown (ActivityKit).
    case liveActivity
    /// AlarmKit loud break-through alarm (iOS 26, v0.9.0).
    case criticalAlarm

    /// The hardcoded fallback used when neither a local override nor a
    /// server default exists. Both channels are **opt-in** (default OFF) —
    /// a Live Activity should not clutter the Lock Screen by surprise and a
    /// loud alarm is the most intrusive affordance the app has.
    public var hardcodedDefault: Bool {
        switch self {
        case .liveActivity: false
        case .criticalAlarm: false
        }
    }
}

/// Where a delivery-pref value applies. Mirrors Apple's per-device Focus
/// model — the *intent* ("this med is critical") can roam, but the
/// *mechanism* ("loud alarm on THIS device") stays device-tunable.
public enum DeliveryScope: String, Codable, Sendable, CaseIterable, Hashable {
    /// A local override that stays on this device only (UserDefaults).
    case thisDevice
    /// The user-level default that roams across devices (server-backed).
    /// Until the server fields ship this degrades to local-only with a
    /// non-blocking "Server-Sync folgt" hint in the UI.
    case allDevices
}

/// One resolved delivery pref for a `(medication × channel)` pair.
public struct DeliveryPreference: Codable, Sendable, Equatable, Hashable {
    /// The effective enabled state after `localOverride ?? serverDefault
    /// ?? hardcodedDefault` resolution.
    public let enabled: Bool
    /// Where the *current* value came from. `thisDevice` when a local
    /// override is present; otherwise `allDevices` (server default /
    /// hardcoded fallback are both conceptually user-level).
    public let scope: DeliveryScope

    public init(enabled: Bool, scope: DeliveryScope) {
        self.enabled = enabled
        self.scope = scope
    }
}

/// Server wire shape for the user-level delivery defaults of one
/// medication. Matches the **SB-LA-1 / SB-AK-1** follow-up contract (see
/// `RA3-settings-sync-plan.md` §7). Until the server ships these fields the
/// `DeliveryDefaultsProviding` stub returns `nil` for every lookup, so this
/// type is currently only exercised by tests + the seam.
public struct MedicationDeliveryDefaultsDTO: Codable, Sendable, Equatable, Hashable {
    public let medicationId: String
    public let liveActivityEnabled: Bool?
    public let criticalAlarmEnabled: Bool?

    public init(
        medicationId: String,
        liveActivityEnabled: Bool?,
        criticalAlarmEnabled: Bool?
    ) {
        self.medicationId = medicationId
        self.liveActivityEnabled = liveActivityEnabled
        self.criticalAlarmEnabled = criticalAlarmEnabled
    }

    /// Read the server-default for a single channel, if present.
    public func value(for channel: DeliveryChannel) -> Bool? {
        switch channel {
        case .liveActivity: liveActivityEnabled
        case .criticalAlarm: criticalAlarmEnabled
        }
    }
}
