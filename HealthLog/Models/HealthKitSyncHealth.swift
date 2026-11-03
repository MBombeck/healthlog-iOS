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
    /// **V1 (Server v1.42, #123)** — wann ein Live-Batch diesen Typ zuletzt
    /// trug (auch nur Duplikate). `lastSeenAt` ist, wann die neueste Messung
    /// *entstand*; das hier ist, wann der Server den Typ *empfing*. Fehlt auf
    /// älteren Servern und auf dem `WORKOUTS`-Eintrag.
    public let lastReceivedAt: Date?
    /// Der `syncTrigger` dieses Batches, als Text: ein künftiges Wort darf die
    /// Liste nicht kippen.
    public let lastTrigger: String?
    /// Wann ein Batch zuletzt eine neue oder geänderte Messung brachte.
    public let lastNewSampleAt: Date?
    /// **W5 (1.3, server v1.42.4, #126 S3)** — when a batch sent with
    /// `syncTrigger: "background"` last carried this type. A later
    /// `foreground`, `push` or `manual` batch leaves it alone, so opening the
    /// app to look at the diagnostics no longer hides the earlier background
    /// arrival. Absent on older servers and on `WORKOUTS`.
    public let lastBackgroundAt: Date?
    /// **INT-Q (1.3, server v1.43, #138 / #77)** — when a batch sent
    /// with `syncTrigger: "backfill"` (X4's hourly catch-up) last carried this
    /// type. A backfill moves only this, never the live stamps above. Absent
    /// on older servers.
    public let lastBackfillAt: Date?
    /// **#146 / server #1247 (v1.43.7)** — only on a type the server also
    /// writes back to Apple Health (weight, blood pressure, glucose): when the
    /// newest reading of the type was entered in HealthLog rather than arriving
    /// from Apple Health. `stale` already counts it, and since v1.43.9
    /// `lastSeenAt` is the newer of the two, so the app shows it beside them
    /// and recomputes neither. Absent on every other type and on older servers.
    public let lastEnteredHereAt: Date?

    public var id: String {
        type
    }

    public init(
        type: String,
        lastSeenAt: Date? = nil,
        stale: Bool = false,
        lastReceivedAt: Date? = nil,
        lastTrigger: String? = nil,
        lastNewSampleAt: Date? = nil,
        lastBackgroundAt: Date? = nil,
        lastBackfillAt: Date? = nil,
        lastEnteredHereAt: Date? = nil
    ) {
        self.type = type
        self.lastSeenAt = lastSeenAt
        self.stale = stale
        self.lastReceivedAt = lastReceivedAt
        self.lastTrigger = lastTrigger
        self.lastNewSampleAt = lastNewSampleAt
        self.lastBackgroundAt = lastBackgroundAt
        self.lastBackfillAt = lastBackfillAt
        self.lastEnteredHereAt = lastEnteredHereAt
    }

    private enum CodingKeys: String, CodingKey {
        case type, lastSeenAt, stale, lastReceivedAt, lastTrigger, lastNewSampleAt, lastBackgroundAt, lastBackfillAt
        case lastEnteredHereAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        // Tolerant: a malformed value on a diagnostics field is absence, never
        // a failed card.
        lastReceivedAt = try? c.decodeIfPresent(Date.self, forKey: .lastReceivedAt)
        lastTrigger = try? c.decodeIfPresent(String.self, forKey: .lastTrigger)
        lastNewSampleAt = try? c.decodeIfPresent(Date.self, forKey: .lastNewSampleAt)
        lastBackgroundAt = try? c.decodeIfPresent(Date.self, forKey: .lastBackgroundAt)
        lastBackfillAt = try? c.decodeIfPresent(Date.self, forKey: .lastBackfillAt)
        lastEnteredHereAt = try? c.decodeIfPresent(Date.self, forKey: .lastEnteredHereAt)
    }
}
