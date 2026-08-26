import Foundation

/// **ROUTE-07 (server v1.37.20) — the reminder completion ledger.**
///
/// Decodes `GET /api/measurement-reminders/{id}/history`, whose success payload
/// is the OpenAPI `MeasurementReminderHistory` schema: an `events` array plus a
/// pagination `meta`. Every shape here comes from the accepted tag
/// (`3a2c0e757e5f0a4ea8bf6be899b3a04547ddd423`), frozen by Plan 08-18 in
/// `HealthLogTests/Fixtures/Server/v1.37.20/`, and from nothing else.
///
/// **Two different `meta` keys.** The transport envelope carries
/// `meta.requestId`; the page carries its own `data.meta.{total, limit, offset}`.
/// `APIClient` unwraps the transport envelope, so the `meta` on this type is
/// always the pagination one. Paginate on it.
///
/// **The ledger is honestly short.** It begins at the release that introduced
/// it — the single-cursor engine holds nothing to backfill from — so a reminder
/// created before v1.37.20 legitimately answers `events: []`, `total: 0`. That
/// is the correct answer, not an error and not "no data yet".
public struct MeasurementReminderHistoryPage: Codable, Sendable, Equatable {
    /// One row per satisfy (from any path) and per skip, **newest first**.
    /// Render the order as given; the server owns it.
    public let events: [MeasurementReminderEvent]
    /// Pagination truth for this page (`data.meta`, not the transport's `meta`).
    public let meta: Meta

    public init(events: [MeasurementReminderEvent], meta: Meta) {
        self.events = events
        self.meta = meta
    }

    /// `data.meta` — the page window the server actually applied. All three are
    /// required by the published schema.
    public struct Meta: Codable, Sendable, Equatable {
        /// Total ledger rows for this reminder, across all pages.
        public let total: Int
        /// Page size the server applied (the request's `limit`, or the default).
        public let limit: Int
        /// Row offset this page starts at.
        public let offset: Int

        public init(total: Int, limit: Int, offset: Int) {
            self.total = total
            self.limit = limit
            self.offset = offset
        }
    }

    /// The published `limit` default. Sent only when a caller asks for it — the
    /// route applies the same value when the parameter is omitted.
    public static let defaultLimit = 50
    /// The published `limit` bounds. A value outside them is a `422` server-side,
    /// which is why the repository passes what it is given rather than clamping:
    /// silently rewriting a caller's page window would hide the refusal.
    public static let limitRange = 1 ... 100
    /// The published `offset` floor (its default is `0`).
    public static let minimumOffset = 0
}

/// One completion-ledger row (OpenAPI `MeasurementReminderEvent`): an honest
/// fulfilment (`SATISFIED`) or an honest skip (`SKIPPED`).
///
/// All six fields are `required` in the published schema, so each decodes
/// unconditionally — a tolerant "maybe absent" model here would be modelling a
/// server that does not exist. The two *enums* are the tolerant part: both
/// decode an unrecognised future value into `.unknown(raw)` rather than failing,
/// because a ledger row dropped over an unknown `source` is a hole in a history
/// the user has no other way to see.
///
/// `onTime` is derived **server-side at write time** against the due instant
/// that was current when the event landed. iOS never re-derives it, exactly as
/// it never recomputes `nextDueAt`.
public struct MeasurementReminderEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: MeasurementReminderEventKind
    /// When the fulfilment or skip happened.
    public let occurredAt: Date
    /// Server-derived punctuality against the then-current due instant.
    public let onTime: Bool
    /// Which path produced the row.
    public let source: MeasurementReminderEventSource
    /// When the ledger row itself was written.
    public let createdAt: Date

    public init(
        id: String,
        kind: MeasurementReminderEventKind,
        occurredAt: Date,
        onTime: Bool,
        source: MeasurementReminderEventSource,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.onTime = onTime
        self.source = source
        self.createdAt = createdAt
    }
}

/// What a ledger row records. The published enum has exactly two values today.
///
/// `.unknown` keeps the raw string rather than collapsing it, so a page that
/// arrives from a newer server still renders every row, a cache round-trip is
/// lossless, and a reader can see what the server actually said.
public enum MeasurementReminderEventKind: Sendable, Equatable {
    case satisfied
    case skipped
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "SATISFIED": self = .satisfied
        case "SKIPPED": self = .skipped
        default: self = .unknown(wire)
        }
    }

    /// The exact string the server sent (or would send) for this case.
    public var wireValue: String {
        switch self {
        case .satisfied: "SATISFIED"
        case .skipped: "SKIPPED"
        case let .unknown(raw): raw
        }
    }
}

/// Which path produced a ledger row. Seven published values, and the set will
/// widen — `measurementType` on the reminder row is a tolerant `String?` for the
/// same reason, and `origin` has its own unknown fallback.
public enum MeasurementReminderEventSource: Sendable, Equatable {
    /// The owner's explicit satisfy or complete tap.
    case manual
    /// A matching measurement resolved the cycle server-side.
    case autoMeasurement
    /// A matching lab result resolved the cycle server-side.
    case autoLab
    case telegram
    case vaccination
    case encounter
    /// The skip route recorded a skipped cycle.
    case skip
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "manual": self = .manual
        case "auto_measurement": self = .autoMeasurement
        case "auto_lab": self = .autoLab
        case "telegram": self = .telegram
        case "vaccination": self = .vaccination
        case "encounter": self = .encounter
        case "skip": self = .skip
        default: self = .unknown(wire)
        }
    }

    /// The exact string the server sent (or would send) for this case.
    public var wireValue: String {
        switch self {
        case .manual: "manual"
        case .autoMeasurement: "auto_measurement"
        case .autoLab: "auto_lab"
        case .telegram: "telegram"
        case .vaccination: "vaccination"
        case .encounter: "encounter"
        case .skip: "skip"
        case let .unknown(raw): raw
        }
    }
}

// MARK: - Wire coding for the two open enums

extension MeasurementReminderEventKind: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(wire: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

extension MeasurementReminderEventSource: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(wire: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
