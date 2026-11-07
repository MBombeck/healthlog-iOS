import Foundation

/// **1.5 VISIT** — `GET /api/day/notable` read without `from`: what stood out
/// and what changed in the window the next booked visit prepares
/// (`anchor: nextVisit`), as keys and the record's own names. The app words
/// the rows from its own bundle and recomputes nothing.
///
/// Tolerant like ``UpcomingEncounters``: an unreadable row is skipped, an
/// unknown `anchor` is kept as sent (the section treats anything but the
/// visit's own window like `fallback`), missing lists read empty.
public struct DayNotableWindow: Decodable, Sendable, Equatable {
    /// `YYYY-MM-DD`, the first day of the window the server chose.
    public let from: String
    public let to: String
    /// `nextVisit`, `lastVisit`, `requested`, `fallback`, or newer.
    public let anchor: String?
    public let observations: [Observation]
    public let changes: [Change]

    /// A deterministic observation (`extremeHigh`, `extremeLow`, `firstValue`,
    /// `gap`) on a measurement `type`, with the parameters of its sentence.
    public struct Observation: Decodable, Sendable, Equatable {
        public let date: String
        public let kind: String
        public let type: String?
        /// `since` (a day key) for the extremes.
        public let since: String?
        /// `days` for a gap.
        public let days: Int?

        public init(date: String, kind: String, type: String?, since: String? = nil, days: Int? = nil) {
            self.date = date
            self.kind = kind
            self.type = type
            self.since = since
            self.days = days
        }

        private enum CodingKeys: String, CodingKey { case date, kind, type, params }
        private enum ParamKeys: String, CodingKey { case since, days }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            kind = try c.decode(String.self, forKey: .kind)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            let params = try? c.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
            since = try? params?.decodeIfPresent(String.self, forKey: .since)
            if let whole = try? params?.decodeIfPresent(Int.self, forKey: .days) {
                days = whole
            } else if let number = try? params?.decodeIfPresent(Double.self, forKey: .days) {
                days = Int(exactly: number)
            } else {
                days = nil
            }
        }
    }

    /// A context change: a dose change, a medication or course that started
    /// or ended, an illness that began, a lab day ...; `title` is the
    /// record's own name for it.
    public struct Change: Decodable, Sendable, Equatable {
        public let date: String
        public let kind: String
        public let id: String
        public let title: String
        public let count: Int

        public init(date: String, kind: String, id: String, title: String, count: Int = 1) {
            self.date = date
            self.kind = kind
            self.id = id
            self.title = title
            self.count = count
        }

        private enum CodingKeys: String, CodingKey { case date, kind, id, title, count }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            kind = try c.decode(String.self, forKey: .kind)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 1
        }
    }

    public init(from: String, to: String, anchor: String?, observations: [Observation], changes: [Change]) {
        self.from = from
        self.to = to
        self.anchor = anchor
        self.observations = observations
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey { case from, to, anchor, observations, changes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        anchor = try? c.decodeIfPresent(String.self, forKey: .anchor)
        observations = ((try? c.decodeIfPresent([Lenient<Observation>].self, forKey: .observations)) ?? [])
            .compactMap(\.value)
        changes = ((try? c.decodeIfPresent([Lenient<Change>].self, forKey: .changes)) ?? [])
            .compactMap(\.value)
    }
}
