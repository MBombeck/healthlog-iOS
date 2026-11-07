import Foundation

/// **1.5 VISIT (#149 item 2)** — the slice of `GET /api/encounters` the
/// "Nächster Termin" section on Vorsorge reads: the booked visits ahead and the
/// window the server resolved before each (`preparation`, server v1.43.11).
///
/// Only what the section shows is decoded. Every field past `id` and
/// `occurredAt` is optional and every enum is open, so an older server (no
/// `preparation`), a newer one (a `basis` or `kind` this build does not know)
/// or a key-rotation gap (`null` names) never fails the list. A row without an
/// `id` or a readable `occurredAt` is skipped, the rest keep the server's order.
public struct UpcomingEncounters: Decodable, Sendable, Equatable {
    /// `upcoming`, soonest first, as the server orders it.
    public let upcoming: [EncounterDTO]

    public init(upcoming: [EncounterDTO]) {
        self.upcoming = upcoming
    }

    private enum CodingKeys: String, CodingKey { case upcoming }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decodeIfPresent([Lenient<EncounterDTO>].self, forKey: .upcoming)) ?? []
        upcoming = rows.compactMap(\.value)
    }
}

/// One visit, booked or done.
public struct EncounterDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let occurredAt: Date
    /// `PLANNED`, `DONE`, `CANCELLED`, `NO_SHOW`, or a newer value as sent.
    public let status: String?
    /// `ROUTINE`, `SPECIALIST`, ... as sent.
    public let kind: String?
    public let practitioner: Practitioner?
    /// The window before this visit. Only on a booked visit of the list read,
    /// and only from v1.43.11; `nil` otherwise.
    public let preparation: EncounterPreparation?

    public struct Practitioner: Decodable, Sendable, Equatable {
        public let name: String?
        public let specialty: String?
        public let practice: String?

        public init(name: String?, specialty: String?, practice: String?) {
            self.name = name
            self.specialty = specialty
            self.practice = practice
        }
    }

    public init(
        id: String,
        occurredAt: Date,
        status: String? = "PLANNED",
        kind: String? = nil,
        practitioner: Practitioner? = nil,
        preparation: EncounterPreparation? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.status = status
        self.kind = kind
        self.practitioner = practitioner
        self.preparation = preparation
    }

    private enum CodingKeys: String, CodingKey {
        case id, occurredAt, status, kind, practitioner, preparation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        practitioner = try? c.decodeIfPresent(Practitioner.self, forKey: .practitioner)
        preparation = try? c.decodeIfPresent(EncounterPreparation.self, forKey: .preparation)
    }
}

/// `preparation` on a booked visit: where the visit preparation and the doctor
/// report offered for it start (`from`), where they end (`to`, the visit's own
/// day), and why there (`basis`, `since`). Day keys stay strings: they are
/// calendar days on the record's own calendar, not instants.
public struct EncounterPreparation: Decodable, Sendable, Equatable {
    public enum Basis: Equatable, Sendable {
        case practitioner
        case specialty
        case kind
        case `default`
        /// A rule this build does not know: shown like `default`.
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "practitioner": self = .practitioner
            case "specialty": self = .specialty
            case "kind": self = .kind
            case "default": self = .default
            default: self = .unknown(raw)
            }
        }
    }

    /// The visit the window starts at (`since`), `nil` on `default`.
    public struct Since: Decodable, Sendable, Equatable {
        public let occurredAt: Date?
        public let kind: String?
        public let practitionerName: String?
        public let specialty: String?

        public init(occurredAt: Date?, kind: String?, practitionerName: String?, specialty: String?) {
            self.occurredAt = occurredAt
            self.kind = kind
            self.practitionerName = practitionerName
            self.specialty = specialty
        }

        private enum CodingKeys: String, CodingKey { case occurredAt, kind, practitionerName, specialty }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            occurredAt = try? c.decodeIfPresent(Date.self, forKey: .occurredAt)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            practitionerName = try? c.decodeIfPresent(String.self, forKey: .practitionerName)
            specialty = try? c.decodeIfPresent(String.self, forKey: .specialty)
        }
    }

    /// First day of the window, `YYYY-MM-DD`.
    public let from: String
    /// The visit's own day, `YYYY-MM-DD`.
    public let to: String
    public let basis: Basis
    public let since: Since?
    /// v1.47.1: `since` lies further back than a health report covers, so
    /// `from` is the first day of the last 730 days ending on `to`. `nil` from
    /// an older server (or a value that is not a boolean): no cap is known.
    public let capped: Bool?

    public init(from: String, to: String, basis: Basis, since: Since?, capped: Bool? = nil) {
        self.from = from
        self.to = to
        self.basis = basis
        self.since = since
        self.capped = capped
    }

    private enum CodingKeys: String, CodingKey { case from, to, basis, since, capped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        basis = try Basis(raw: (c.decodeIfPresent(String.self, forKey: .basis)) ?? "default")
        since = try? c.decodeIfPresent(Since.self, forKey: .since)
        capped = try? c.decodeIfPresent(Bool.self, forKey: .capped)
    }
}

/// Decodes one element of a list, or `nil` when that element is unreadable, so
/// one bad row never fails the whole list.
struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
