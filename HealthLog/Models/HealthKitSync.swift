import Foundation

public struct HealthKitSyncConfig: Codable, Sendable, Equatable {
    public let entries: [HealthKitSyncEntry]
    public let lastSyncedAt: Date?

    // MARK: - CU-21 (C1) — Sync-Gesundheit, nur im GET

    /// Server ≥ v1.32.31 legt vier Felder dem GET von
    /// `/api/integrations/healthkit` bei; das PATCH-Echo trägt sie NICHT. Alle
    /// vier sind deshalb optional und werden beim Encodieren weggelassen — der
    /// PATCH-Body bleibt byte-identisch zur Vor-CU-21-Form (`entries` +
    /// `lastSyncedAt`), sonst schickten wir dem Server Felder zurück, die sein
    /// Schema auf dieser Route nicht kennt.
    ///
    /// Auslöser des zuletzt vom Server gesehenen Sweeps
    /// (`foreground` | `background` | `push`). Bewusst als **roher String**
    /// gehalten: ein vierter Wert vom Server soll die Integration nicht kippen,
    /// und die Fläche kann ihn wörtlich anzeigen. Typisierte Lesart über
    /// ``lastSyncTriggerKind``.
    public let lastSyncTrigger: String?
    /// Wann zuletzt ein Sweep ankam, den die App **nicht** im Vordergrund
    /// ausgelöst hat. Das ist der harte Beleg für „dieses Telefon liefert
    /// selbstständig".
    public let lastBackgroundSyncAt: Date?
    public let syncHealth: HealthKitSyncHealth?
    /// Nur Typen, die tatsächlich geliefert haben. `nil` = der Server kennt das
    /// Feld nicht (älterer Server); `[]` = er kennt es, aber noch kein Typ hat
    /// geliefert. Der Unterschied ist für die Fläche relevant, deshalb optional.
    public let metricFreshness: [MetricFreshness]?

    /// Typisierte Lesart von ``lastSyncTrigger``; `nil` sowohl bei Abwesenheit
    /// als auch bei einem Wort, das dieser Build nicht kennt.
    public var lastSyncTriggerKind: SyncTrigger? {
        lastSyncTrigger.flatMap(SyncTrigger.init(rawValue:))
    }

    public init(
        entries: [HealthKitSyncEntry],
        lastSyncedAt: Date?,
        lastSyncTrigger: String? = nil,
        lastBackgroundSyncAt: Date? = nil,
        syncHealth: HealthKitSyncHealth? = nil,
        metricFreshness: [MetricFreshness]? = nil
    ) {
        self.entries = entries
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncTrigger = lastSyncTrigger
        self.lastBackgroundSyncAt = lastBackgroundSyncAt
        self.syncHealth = syncHealth
        self.metricFreshness = metricFreshness
    }

    private enum CodingKeys: String, CodingKey {
        case entries, lastSyncedAt, lastSyncTrigger, lastBackgroundSyncAt, syncHealth, metricFreshness
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([HealthKitSyncEntry].self, forKey: .entries) ?? []
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSyncTrigger = try c.decodeIfPresent(String.self, forKey: .lastSyncTrigger)
        lastBackgroundSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastBackgroundSyncAt)
        syncHealth = try c.decodeIfPresent(HealthKitSyncHealth.self, forKey: .syncHealth)
        metricFreshness = try c.decodeIfPresent([MetricFreshness].self, forKey: .metricFreshness)
    }

    /// Schreibt ausschließlich die zwei Felder, die der PATCH-Body kennt.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
        try c.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
    }
}

public struct HealthKitSyncEntry: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier matching `DEFAULT_HEALTHKIT_ENTRIES` row id
    /// server-side (`src/app/api/integrations/healthkit/route.ts:45-67`).
    public let id: String
    /// Raw HK identifier vocabulary (`"bodyMass"`, `"bloodPressure"`,
    /// `"bloodGlucose"`, `"heartRate"`, `"stepCount"`, `"sleepAnalysis"`,
    /// future entries). Server emits the string verbatim — pre-v0.4.0 iOS
    /// tried to coerce into the domain `MetricKind` enum and `dataCorrupted`
    /// on `bodyMass`/`heartRate`/`stepCount`/`sleepAnalysis` (A4-Audit row 7).
    /// UI translates via `kindDisplayName` extension.
    public let kind: String
    public let direction: SyncDirection
    public let enabled: Bool

    public init(id: String, kind: String, direction: SyncDirection, enabled: Bool) {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.enabled = enabled
    }
}

public extension HealthKitSyncEntry {
    /// User-facing label for the HK kind identifier. The translation table is
    /// finite — extend when the server adds new defaults to
    /// `DEFAULT_HEALTHKIT_ENTRIES`.
    var kindDisplayName: String {
        switch kind {
        case "bodyMass": "Weight"
        case "bloodPressure": "Blood pressure"
        case "bloodGlucose": "Blood glucose"
        case "heartRate": "Pulse"
        case "stepCount": "Steps"
        case "sleepAnalysis": "Sleep"
        case "oxygenSaturation": "Oxygen saturation"
        case "bodyFatPercentage": "Body fat"
        case "bodyTemperature": "Body temperature"
        default: kind // Unknown kind from a newer server — render verbatim.
        }
    }
}

public enum SyncDirection: String, Codable, Sendable {
    case readOnly
    case writeOnly
    case bidirectional
    /// Server v1.4.x adds `disabled` as a fourth case for explicitly-
    /// turned-off entries (`src/app/api/integrations/healthkit/route.ts:24`).
    /// Pre-v0.4.0 iOS rejected the whole config payload with `dataCorrupted`
    /// when any row was disabled (A4-Audit row 6) — settings screen broke
    /// for every user who ever toggled an entry off.
    case disabled
}

/// APNs-Environment-Marker, den iOS pro Build-Config setzt + Server zur
/// Wahl des korrekten APNs-Endpoints (sandbox vs. production) verwendet.
/// Eine .p8-Auth-Key dient beiden — Apple unterscheidet über den HTTP/2-Host.
public enum APNsEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case production
}

/// Body für `POST /api/devices`. Server-Schema (Zod, src/app/api/devices/route.ts):
/// `apnsToken` + `apnsEnvironment` müssen entweder beide gesetzt oder beide
/// `nil` sein — die `precondition` im Initializer spiegelt das, damit ein
/// Programmer-Error sofort crasht statt als opaker 422 vom Server zurückkommt.
///
/// `token` ist hier die per-Install-Device-UUID aus dem Keychain (siehe
/// `KeychainKey.deviceID`), NICHT der APNs-Token. Server bindet den Refresh-
/// Token an diese Device-Row + nutzt sie für Audit + Revocation.
public struct DeviceRegistration: Codable, Sendable, Equatable {
    public let token: String
    public let bundleId: String
    public let locale: String
    public let appVersion: String
    public let model: String
    public let apnsToken: String?
    public let apnsEnvironment: APNsEnvironment?
    /// W-B189 (#22) — ActivityKit push token for a running medication Live
    /// Activity (hex). When present, the server (≥ v1.17.1) sends a direct
    /// `apns-push-type: liveactivity` `end`/`update` push to the running
    /// Activity so a remote intake clears the lock-screen countdown even
    /// with the app fully closed — not only on the silent-push reconcile.
    /// Optional + omitted from the encoded body when `nil` so pre-1.17.1
    /// servers (and devices with no running Activity) see the unchanged
    /// shape. This is the per-Activity **update** token (a push-to-start
    /// token can only start an Activity, not push to a running one).
    public let liveActivityPushToken: String?

    public init(
        token: String,
        bundleId: String,
        locale: String,
        appVersion: String,
        model: String,
        apnsToken: String? = nil,
        apnsEnvironment: APNsEnvironment? = nil,
        liveActivityPushToken: String? = nil
    ) {
        precondition(
            (apnsToken == nil) == (apnsEnvironment == nil),
            "DeviceRegistration: apnsToken + apnsEnvironment müssen gemeinsam gesetzt sein."
        )
        self.token = token
        self.bundleId = bundleId
        self.locale = locale
        self.appVersion = appVersion
        self.model = model
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.liveActivityPushToken = liveActivityPushToken
    }

    /// Custom encoding so `liveActivityPushToken` is **omitted** from the
    /// JSON body when `nil` (rather than serialized as `null`). Keeps the
    /// request shape byte-identical to the pre-W-B189 body for servers
    /// that do not know the field. The remaining keys encode unconditionally
    /// to match the synthesized behaviour the server schema already accepts.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(locale, forKey: .locale)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(apnsToken, forKey: .apnsToken)
        try container.encodeIfPresent(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encodeIfPresent(liveActivityPushToken, forKey: .liveActivityPushToken)
    }
}
