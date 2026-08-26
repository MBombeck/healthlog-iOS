import Foundation

// **CU-32 — effektiv-datierte, verschlüsselte Anamnese-Fakten.**
//
// Wire: `GET|POST /api/anamnesis/facts`, `PATCH|DELETE /api/anamnesis/facts/{id}`
// (Server ≥ v1.34.0). Der serialisierte Server-Typ heisst
// `HealthProfileFactRevisionDto`; hier ``AnamnesisFactRevision``.
//
// **Zwei Dinge, die diese Fläche von einem gewöhnlichen Settings-Feld
// unterscheiden — und die das Modell deshalb explizit macht:**
//
// 1. **Abwesenheit ist nicht `NONE`.** „Nie erfasst" und „trinkt nicht" sind
//    zwei verschiedene Aussagen. Der Server drückt das über
//    `current[kind] == null` (nie erfasst) gegen eine Revision mit
//    `value == "NONE"` (erfasst, und die Antwort lautet: keine) aus. Auf iOS
//    trägt ``AnamnesisFactState`` diese Unterscheidung bis in die Oberfläche;
//    es gibt bewusst **keinen** Default-Wert und kein `?? .declaredNone`.
// 2. **Effektiv-Datierung.** Jede Revision gilt `validFrom ..< validUntil`;
//    `validUntil == nil` heisst „gilt heute". Eine Korrektur erzeugt eine
//    **neue** Revision (`provenance == .userCorrection`) und schliesst die
//    alte — der Verlauf ist damit die eigentliche Aussage der Fläche, nicht
//    nur der aktuelle Stand.
//
// **Nebenläufigkeit.** Es gibt kein `baseUpdatedAt`, kein `If-Match`, kein
// ETag: **die Revisions-ID im Pfad ist das optimistische Token** (anders als
// bei den Lock-Routen, die `OptimisticWriteBody` benutzen). Eine veraltete ID
// beantwortet der Server mit **404** (Torwächter), eine Kollision zwischen
// Torwächter und bewachtem Update mit **409** — beides bedeutet für uns
// dasselbe: neu laden, frische ID nehmen. Siehe ``AnamnesisFactFailure``.

// MARK: - Kind

/// Die drei Fakten-Arten. Serverseitig eine geschlossene Konstantenliste;
/// `current` trägt **immer** alle drei Schlüssel (ggf. `null`).
public enum AnamnesisFactKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case smokingStatus = "SMOKING_STATUS"
    case alcoholPattern = "ALCOHOL_PATTERN"
    case shiftSchedule = "SHIFT_SCHEDULE"

    public var id: String {
        rawValue
    }

    /// Die erlaubte Wertemenge dieser Art, in Server-Reihenfolge. Der POST ist
    /// eine diskriminierte Union über `kind` — ein Wert aus einer fremden Menge
    /// ist ein 422, deshalb prüfen wir vor dem Senden mit ``allows(_:)``.
    ///
    /// Beachten: `NONE` kommt in **zwei** Mengen vor (Alkohol + Schicht),
    /// `NEVER` nur beim Rauchen. Die Bedeutung von `NONE` unterscheidet sich
    /// je Art — deshalb liegen die Beschriftungen bei der Art, nicht beim Wert.
    public var allowedValues: [AnamnesisFactValue] {
        switch self {
        case .smokingStatus: [.never, .former, .current]
        case .alcoholPattern: [.declaredNone, .occasional, .weekly, .mostDays]
        case .shiftSchedule: [.declaredNone, .fixedShift, .rotating]
        }
    }

    public func allows(_ value: AnamnesisFactValue) -> Bool {
        allowedValues.contains(value)
    }
}

// MARK: - Value

/// Ein Fakten-Wert. Bewusst **eine** Aufzählung über alle Arten hinweg (statt
/// drei), weil `NONE` von zwei Arten geteilt wird; die Zuordnung Art → Menge
/// macht ``AnamnesisFactKind/allowedValues``.
///
/// `unknown` ist die Toleranz-Senke für Server-Enum-Wachstum: ein unbekanntes
/// Literal ist nie fatal, es rendert als „unbekannter Wert" und lässt sich
/// überschreiben. Der Fall `declaredNone` (`"NONE"`) heisst **nicht** „nichts
/// erfasst", sondern „ausdrücklich keine" — die Abwesenheit trägt
/// ``AnamnesisFactState/neverRecorded``.
public enum AnamnesisFactValue: Sendable, Hashable, Codable {
    /// `SMOKING_STATUS`
    case never
    case former
    case current
    /// `ALCOHOL_PATTERN` + `SHIFT_SCHEDULE` — ausdrücklich „keine".
    case declaredNone
    /// `ALCOHOL_PATTERN`
    case occasional
    case weekly
    case mostDays
    /// `SHIFT_SCHEDULE`
    case fixedShift
    case rotating
    /// Vorwärtskompatibilität — ein Literal, das dieser Build nicht kennt.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "NEVER": self = .never
        case "FORMER": self = .former
        case "CURRENT": self = .current
        case "NONE": self = .declaredNone
        case "OCCASIONAL": self = .occasional
        case "WEEKLY": self = .weekly
        case "MOST_DAYS": self = .mostDays
        case "FIXED_SHIFT": self = .fixedShift
        case "ROTATING": self = .rotating
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .never: "NEVER"
        case .former: "FORMER"
        case .current: "CURRENT"
        case .declaredNone: "NONE"
        case .occasional: "OCCASIONAL"
        case .weekly: "WEEKLY"
        case .mostDays: "MOST_DAYS"
        case .fixedShift: "FIXED_SHIFT"
        case .rotating: "ROTATING"
        case let .unknown(raw): raw
        }
    }

    /// `true` für ein Literal, das dieser Build nicht kennt.
    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Provenance

/// Woher eine Revision stammt. Eine **Korrektur** ist etwas anderes als eine
/// Änderung: `USER_REPORTED` schreibt der POST (Erstangabe), `USER_CORRECTION`
/// der PATCH-Nachfolger. Die Oberfläche zeigt das, statt es zu verschlucken.
public enum AnamnesisFactProvenance: Sendable, Hashable, Codable {
    case userReported
    case userCorrection
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "USER_REPORTED": self = .userReported
        case "USER_CORRECTION": self = .userCorrection
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .userReported: "USER_REPORTED"
        case .userCorrection: "USER_CORRECTION"
        case let .unknown(raw): raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Revision

/// Eine effektiv-datierte Revision eines Anamnese-Faktums.
///
/// `value == nil` ⇔ `unreadable == true`: die Zeile steht in der Datenbank,
/// liess sich aber nicht entschlüsseln (oder der Klartext ist kein legales
/// Literal dieser Art). Das ist die **ehrliche** Variante von „da ist etwas,
/// wir kommen nur nicht dran" — die Zeile wird deshalb angezeigt, nicht
/// versteckt, und ist von „nie erfasst" klar unterschieden.
public struct AnamnesisFactRevision: Decodable, Sendable, Hashable, Identifiable {
    /// Opaker String (POST: cuid, PATCH-Nachfolger: UUID) — **kein Format
    /// annehmen**. Zugleich das Nebenläufigkeits-Token für PATCH/DELETE.
    public let id: String
    public let kind: AnamnesisFactKind
    /// `nil` genau dann, wenn ``unreadable`` gesetzt ist.
    public let value: AnamnesisFactValue?
    public let unreadable: Bool
    public let validFrom: Date
    /// `nil` bedeutet „gilt aktuell".
    public let validUntil: Date?
    public let provenance: AnamnesisFactProvenance
    /// Auf dem Vorgänger gesetzt, sobald ein PATCH ihn abgelöst hat. Seine ID
    /// ist damit als Token dauerhaft tot.
    public let supersededByRevisionId: String?
    public let createdAt: Date

    public init(
        id: String,
        kind: AnamnesisFactKind,
        value: AnamnesisFactValue?,
        unreadable: Bool,
        validFrom: Date,
        validUntil: Date?,
        provenance: AnamnesisFactProvenance,
        supersededByRevisionId: String?,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.unreadable = unreadable
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.provenance = provenance
        self.supersededByRevisionId = supersededByRevisionId
        self.createdAt = createdAt
    }

    /// Die Bedingung, unter der der Server diese Zeile als „aktuell" führt —
    /// identisch zum partiellen Unique-Index
    /// (`valid_until IS NULL AND superseded_by_revision_id IS NULL`).
    public var isCurrent: Bool {
        validUntil == nil && supersededByRevisionId == nil
    }

    /// Eine Korrektur (gegen eine Erstangabe).
    public var isCorrection: Bool {
        provenance == .userCorrection
    }
}

// MARK: - State (Abwesenheit ist nicht NONE)

/// Der Zustand **einer** Fakten-Art — die drei Aussagen, die die Fläche
/// auseinanderhalten muss. Es gibt bewusst keinen vierten „Default"-Fall:
/// ein leeres Feld darf nirgends als „keine" gerendert werden.
public enum AnamnesisFactState: Sendable, Hashable {
    /// Nie erfasst. **Nicht** `NONE` — die Frage wurde schlicht nie beantwortet.
    case neverRecorded
    /// Erfasst, aber nicht lesbar (`unreadable == true`).
    case unreadable(AnamnesisFactRevision)
    /// Erfasst und lesbar.
    case recorded(AnamnesisFactRevision, AnamnesisFactValue)

    /// Die aktuell gültige Revision, sofern eine existiert. `nil` genau bei
    /// ``neverRecorded`` — das ist der einzige Fall ohne Revisions-ID und damit
    /// der einzige, in dem POST (statt PATCH) der richtige Verb ist.
    public var revision: AnamnesisFactRevision? {
        switch self {
        case .neverRecorded: nil
        case let .unreadable(revision): revision
        case let .recorded(revision, _): revision
        }
    }

    public var value: AnamnesisFactValue? {
        if case let .recorded(_, value) = self { return value }
        return nil
    }

    public var isRecorded: Bool {
        revision != nil
    }
}

// MARK: - Payload

/// `GET /api/anamnesis/facts` → `{ current, history }`.
///
/// `current` trägt serverseitig immer alle drei Schlüssel (ggf. `null`); wir
/// speichern nur die **nicht**-null Einträge, damit ein fehlender Schlüssel und
/// ein `null`-Schlüssel im Modell dasselbe bedeuten: nie erfasst.
///
/// `history` enthält **jede** Revision **jeder** Art — kein Filter, kein Limit,
/// kein Cursor — sortiert `kind ASC, validFrom DESC`. Der Array-Decode ist
/// verlustbehaftet: eine Zeile, deren `kind` dieser Build nicht kennt, wird
/// übersprungen statt die ganze Antwort zu versenken.
public struct AnamnesisFactsPayload: Decodable, Sendable, Hashable {
    public let current: [AnamnesisFactKind: AnamnesisFactRevision]
    public let history: [AnamnesisFactRevision]

    public init(
        current: [AnamnesisFactKind: AnamnesisFactRevision],
        history: [AnamnesisFactRevision]
    ) {
        self.current = current
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case current, history
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCurrent = try container.decodeIfPresent(
            [String: LossyAnamnesisRevision].self, forKey: .current
        ) ?? [:]
        var mapped: [AnamnesisFactKind: AnamnesisFactRevision] = [:]
        for (rawKind, slot) in rawCurrent {
            guard let kind = AnamnesisFactKind(rawValue: rawKind), let revision = slot.value else {
                continue
            }
            mapped[kind] = revision
        }
        current = mapped
        let lossyHistory = try container.decodeIfPresent(
            [LossyAnamnesisRevision].self, forKey: .history
        ) ?? []
        history = lossyHistory.compactMap(\.value)
    }

    /// Der Zustand einer Art — die einzige Stelle, an der aus „Schlüssel fehlt"
    /// eine Aussage wird.
    public func state(for kind: AnamnesisFactKind) -> AnamnesisFactState {
        guard let revision = current[kind] else { return .neverRecorded }
        guard let value = revision.value, !revision.unreadable else {
            return .unreadable(revision)
        }
        return .recorded(revision, value)
    }

    /// Der Verlauf einer Art, neueste Gültigkeit zuerst. Der Server sortiert
    /// bereits `validFrom DESC`; wir sortieren defensiv noch einmal, damit die
    /// Anzeige nicht von der Server-Sortierung abhängt.
    public func history(for kind: AnamnesisFactKind) -> [AnamnesisFactRevision] {
        history.filter { $0.kind == kind }.sorted { $0.validFrom > $1.validFrom }
    }

    /// Arten, für die überhaupt schon einmal etwas erfasst wurde.
    public var recordedKinds: [AnamnesisFactKind] {
        AnamnesisFactKind.allCases.filter { current[$0] != nil }
    }

    public static let empty = AnamnesisFactsPayload(current: [:], history: [])
}

/// Ein Array-/Dictionary-Element, das genau eine Revision konsumiert und
/// **nie** wirft — eine Zeile mit unbekanntem `kind` (oder kaputter Shape)
/// ergibt `nil`, statt den gesamten Decode zu versenken.
struct LossyAnamnesisRevision: Decodable {
    let value: AnamnesisFactRevision?

    init(from decoder: Decoder) throws {
        value = try? AnamnesisFactRevision(from: decoder)
    }
}

// MARK: - Write bodies

/// `POST /api/anamnesis/facts` — diskriminierte Union über `kind`.
/// Legt den **ersten** Wert einer Art an; sobald eine aktuelle Revision
/// existiert, ist PATCH das richtige Verb (sonst 409 `currentExists`).
public struct AnamnesisFactCreate: Encodable, Sendable, Hashable {
    public let kind: AnamnesisFactKind
    public let value: AnamnesisFactValue

    public init(kind: AnamnesisFactKind, value: AnamnesisFactValue) {
        self.kind = kind
        self.value = value
    }
}

/// `PATCH /api/anamnesis/facts/{id}` — der Body trägt **nur** `value`.
/// Die Art liest der Server aus der gespeicherten Zeile; die ID im Pfad ist
/// das Nebenläufigkeits-Token.
public struct AnamnesisFactCorrection: Encodable, Sendable, Hashable {
    public let value: AnamnesisFactValue

    public init(value: AnamnesisFactValue) {
        self.value = value
    }
}

/// `DELETE /api/anamnesis/facts/{id}` → 200 (kein 204) mit einer **anderen,
/// kleineren** Shape: kein `value`.
public struct RemovedAnamnesisFact: Decodable, Sendable, Hashable {
    public let id: String
    public let kind: AnamnesisFactKind
    /// Das gerade geschriebene `validUntil`.
    public let removedAt: Date

    public init(id: String, kind: AnamnesisFactKind, removedAt: Date) {
        self.id = id
        self.kind = kind
        self.removedAt = removedAt
    }
}
