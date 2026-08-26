import Foundation

/// **CU-21 (C1)** — Server-Urteil über die Sync-Gesundheit dieser
/// HealthKit-Integration. Kommt seit Server v1.32.31 **nur im GET** von
/// `/api/integrations/healthkit` (das PATCH-Echo trägt es nicht).
public struct HealthKitSyncHealth: Codable, Sendable, Equatable {
    public let verdict: SyncHealthVerdict
    /// Seit wann dieses Urteil gilt. Optional — ein frisch verbundenes Konto
    /// hat noch keinen Zeitanker.
    public let since: Date?

    public init(verdict: SyncHealthVerdict, since: Date? = nil) {
        self.verdict = verdict
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, since
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decodeIfPresent(SyncHealthVerdict.self, forKey: .verdict) ?? .unknown("")
        since = try c.decodeIfPresent(Date.self, forKey: .since)
    }
}

/// Die acht Urteile, die der Server heute kennt — **plus** ein
/// Unbekannt-Auffang.
///
/// Bewusst kein `String`-RawRepresentable-Enum: ein neunter Wert vom Server darf
/// weder das Decoding der Integration kippen noch still auf einen falschen
/// bekannten Wert einrasten. `unknown(raw)` behält das Originalwort, damit die
/// Diagnostikfläche es wörtlich anzeigen kann statt zu schweigen.
public enum SyncHealthVerdict: Sendable, Hashable, Codable {
    /// Daten sind aktuell.
    case fresh
    /// Länger nichts Neues, aber kein Fehler.
    case stale
    /// Der Sync steht — nichts kommt mehr durch.
    case stalled
    /// Wiederholte Fehlschläge.
    case failing
    /// Die Verbindung braucht eine erneute Autorisierung.
    case reauthRequired
    /// Der Server hat die Integration geparkt.
    case parked
    /// Verbunden, aber der erste Sync steht noch aus.
    case pendingFirstSync
    /// Keine Verbindung (mehr).
    case disconnected
    /// Ein Urteil, das dieser Build noch nicht kennt. Trägt das Rohwort.
    case unknown(String)

    /// Wire-Wort (snake_case, exakt wie der Server es schreibt).
    public var rawValue: String {
        switch self {
        case .fresh: "fresh"
        case .stale: "stale"
        case .stalled: "stalled"
        case .failing: "failing"
        case .reauthRequired: "reauth_required"
        case .parked: "parked"
        case .pendingFirstSync: "pending_first_sync"
        case .disconnected: "disconnected"
        case let .unknown(raw): raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "fresh": self = .fresh
        case "stale": self = .stale
        case "stalled": self = .stalled
        case "failing": self = .failing
        case "reauth_required": self = .reauthRequired
        case "parked": self = .parked
        case "pending_first_sync": self = .pendingFirstSync
        case "disconnected": self = .disconnected
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// `true`, wenn das Urteil eine Nutzeraktion oder zumindest Aufmerksamkeit
    /// verlangt. `unknown` ist bewusst **nicht** alarmierend — ein neues
    /// Server-Wort darf keine rote Fläche erzeugen, bevor jemand weiß, was es
    /// bedeutet.
    public var needsAttention: Bool {
        switch self {
        case .stalled, .failing, .reauthRequired, .parked, .disconnected: true
        case .fresh, .stale, .pendingFirstSync, .unknown: false
        }
    }
}

/// **CU-21 (C1)** — pro Metrik-Typ, wann der Server zuletzt etwas von diesem
/// Gerät gesehen hat.
///
/// **Wichtig:** Die Liste enthält **nur** Typen, die tatsächlich geliefert
/// haben. Ein fehlender Typ ist Abwesenheit („davon kam noch nie etwas"), **kein
/// Nullwert** — die Fläche darf ihn deshalb nicht als „0" oder „veraltet"
/// zeichnen, sondern gar nicht.
public struct MetricFreshness: Codable, Sendable, Equatable, Identifiable {
    /// Server-Typwort (z. B. `weight`, `heart_rate`). Offen gehalten: neue
    /// Typen sollen die Liste nicht kippen.
    public let type: String
    public let lastSeenAt: Date?
    /// Server-Urteil, ob dieser Typ zu lange still ist.
    public let stale: Bool

    public var id: String {
        type
    }

    public init(type: String, lastSeenAt: Date? = nil, stale: Bool = false) {
        self.type = type
        self.lastSeenAt = lastSeenAt
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey {
        case type, lastSeenAt, stale
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }
}
