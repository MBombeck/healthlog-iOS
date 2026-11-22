import Foundation

// MARK: - Merged and restored cycle starts (#137, server v1.43)

/// A cycle start the server folded into another start, or gave back after
/// the start it was folded into went away (`CycleRestoredStart` in
/// `docs/api/openapi.yaml` at `v1.43.0`).
public struct CycleRestoredStart: Codable, Sendable, Equatable, Hashable {
    public let cycleId: String
    /// `YYYY-MM-DD`, a date-only key (never shifted by a zone).
    public let startDate: String

    public init(cycleId: String, startDate: String) {
        self.cycleId = cycleId
        self.startDate = startDate
    }

    /// Reads a list row by row; a row without both fields is dropped.
    static func decodeList<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) -> [CycleRestoredStart] {
        guard let rows = try? c.decodeIfPresent([Lossy].self, forKey: key) else { return [] }
        return rows.compactMap(\.start)
    }

    private struct Lossy: Decodable {
        let start: CycleRestoredStart?

        init(from decoder: Decoder) throws {
            start = try? CycleRestoredStart(from: decoder)
        }
    }
}

/// What `POST /api/cycle/period` with `action: "start"` reports beyond the
/// write: the later start it folded in (`absorbed`, v1.43) and the start it
/// stored. Every field is optional and read tolerantly, so a v1.42 answer
/// (`{ cycle, dayLog }` only), a `data: null` answer and an unreadable block
/// all decode to "nothing to say", never a failed write.
public struct CyclePeriodOutcome: Decodable, Sendable, Equatable {
    public let absorbed: CycleRestoredStart?
    /// `cycle.startDate` of the answer: the start the person logged.
    public let startDate: String?

    public init(absorbed: CycleRestoredStart? = nil, startDate: String? = nil) {
        self.absorbed = absorbed
        self.startDate = startDate
    }

    private enum CodingKeys: String, CodingKey {
        case absorbed, cycle
    }

    private enum CycleKeys: String, CodingKey {
        case startDate
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        var startDate: String?
        if let cycle = try? c.nestedContainer(keyedBy: CycleKeys.self, forKey: .cycle) {
            startDate = try? cycle.decodeIfPresent(String.self, forKey: .startDate)
        }
        self.init(absorbed: try? c.decodeIfPresent(CycleRestoredStart.self, forKey: .absorbed), startDate: startDate)
    }
}

/// `PATCH /api/cycle/day-logs/{id}` answers the day log; since v1.43 the same
/// object also lists the starts the edit gave back (`restored`, clearing the
/// flow on a start day). Absent on older servers: an empty list.
public struct CycleDayLogPatchResult: Decodable, Sendable, Equatable {
    public let dayLog: CycleDayLogDTO
    public let restored: [CycleRestoredStart]

    public init(dayLog: CycleDayLogDTO, restored: [CycleRestoredStart] = []) {
        self.dayLog = dayLog
        self.restored = restored
    }

    private enum CodingKeys: String, CodingKey {
        case restored
    }

    public init(from decoder: Decoder) throws {
        dayLog = try CycleDayLogDTO(from: decoder)
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            restored = CycleRestoredStart.decodeList(from: c, forKey: .restored)
        } else {
            restored = []
        }
    }
}

/// What `DELETE /api/cycle/cycles/{id}` and `DELETE /api/cycle/day-logs/{id}`
/// changed, answered with 200 when the request sent
/// `Prefer: return=representation` (v1.43). An older server answers 204 with
/// no body, exactly as before: ``unchanged``, a successful delete with nothing to
/// say.
public struct CycleDeleteOutcome: Decodable, Sendable, Equatable {
    public let removedCycleId: String?
    public let restored: [CycleRestoredStart]

    public static let unchanged = CycleDeleteOutcome(removedCycleId: nil, restored: [])

    public init(removedCycleId: String?, restored: [CycleRestoredStart]) {
        self.removedCycleId = removedCycleId
        self.restored = restored
    }

    private enum CodingKeys: String, CodingKey {
        case removedCycleId, restored
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .unchanged
            return
        }
        removedCycleId = try? c.decodeIfPresent(String.self, forKey: .removedCycleId)
        restored = CycleRestoredStart.decodeList(from: c, forKey: .restored)
    }

    /// The body of a delete answer: 204 or an empty body is ``unchanged``; a 200
    /// envelope carries the outcome. Never throws: the delete itself already
    /// succeeded when this runs.
    public static func decode(_ data: Data, decoder: JSONDecoder = .hlDefault) -> CycleDeleteOutcome {
        guard !data.isEmpty,
              let envelope = try? decoder.decode(APIEnvelope<CycleDeleteOutcome>.self, from: data),
              let outcome = envelope.data else { return .unchanged }
        return outcome
    }
}

/// The one calm sentence the cycle calendar shows after the server merged or
/// gave back a start. Built from the server's dates only.
public struct CycleStartNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// `absorbed` start folded into `into`.
        case merged(absorbed: String, into: String)
        /// Starts given back, oldest first.
        case restored([String])
    }

    public let kind: Kind

    public var id: String {
        switch kind {
        case let .merged(absorbed, into): "merged.\(absorbed).\(into)"
        case let .restored(dates): "restored.\(dates.joined(separator: "."))"
        }
    }

    public init(kind: Kind) {
        self.kind = kind
    }

    /// A merge notice for a start answer, or `nil` when nothing was folded in.
    public static func merged(_ outcome: CyclePeriodOutcome?, requestedDate: String) -> CycleStartNotice? {
        guard let absorbed = outcome?.absorbed else { return nil }
        return CycleStartNotice(kind: .merged(absorbed: absorbed.startDate, into: outcome?.startDate ?? requestedDate))
    }

    /// A restore notice, or `nil` when the list is empty.
    public static func restored(_ starts: [CycleRestoredStart]) -> CycleStartNotice? {
        let dates = Array(Set(starts.map(\.startDate))).sorted()
        guard !dates.isEmpty else { return nil }
        return CycleStartNotice(kind: .restored(dates))
    }

    /// "Your start on 17 Sep was merged into 14 Sep." in the person's language.
    public func sentence(locale: Locale = .current) -> String {
        switch kind {
        case let .merged(absorbed, into):
            let from = Self.dayLabel(absorbed, locale: locale)
            let target = Self.dayLabel(into, locale: locale)
            return String(localized: "cycle.startNotice.merged \(from) \(target)")
        case let .restored(dates):
            let days = dates.map { Self.dayLabel($0, locale: locale) }
            if days.count == 1 {
                return String(localized: "cycle.startNotice.restoredOne \(days[0])")
            }
            let list = days.formatted(.list(type: .and).locale(locale))
            return String(localized: "cycle.startNotice.restoredMany \(list)")
        }
    }

    /// "17 Sep" for a `YYYY-MM-DD` key, read in UTC so no zone moves the day.
    static func dayLabel(_ key: String, locale: Locale) -> String {
        guard let anchor = ProfileDay.anchor(forKey: key) else { return key }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(.abbreviated).locale(locale)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return anchor.formatted(style)
    }
}
