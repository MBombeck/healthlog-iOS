import Foundation

// Phase 07 Wave 3 — split out of `MoodRepository.swift`.
//
// The repository file crossed the 600-line gate when the durable write outcome
// landed on it. These five types were never the repository: they are the mood
// history query vocabulary the screens build and the repository merely accepts.

/// Provenance vocabulary of a stored mood entry. Mirrors the server
/// `moodSourceEnum` (`src/lib/validations/mood.ts:29-35`) verbatim.
///
/// **This is not a decode type.** `MoodEntry.source` decodes as a plain
/// `String?` (`Models/Mood.swift`), so a provenance value iOS has never heard
/// of can never break a row. The enum exists to populate the history filter
/// picker and to ride along as the `source=` query parameter.
public enum MoodEntrySource: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case manual = "MANUAL"
    /// Legacy provenance, **read/filter only**. The moodLog bridge that wrote
    /// these rows was retired server-side in v1.32.33: the routes
    /// `/api/integrations/moodlog/*` and `/api/settings/moodlog` are gone and
    /// migration 0271 dropped the columns. The value stays because the rows the
    /// bridge imported are the user's own history and keep their label — the
    /// server deliberately goes on resolving it
    /// (`src/lib/validations/mood.ts:23-31`, pinned by
    /// `src/__tests__/moodlog-removal-guard.test.ts`, which forbids every
    /// moodLog *surface* but explicitly not this value). Nothing mints new
    /// `MOODLOG` rows, so do not offer it on any write path.
    case moodlog = "MOODLOG"
    case web = "WEB"
    case telegram = "TELEGRAM"
    case daylio = "DAYLIO"

    public var id: String {
        rawValue
    }
}

public struct MoodHistoryQuery: Sendable, Equatable {
    public let from: String?
    public let to: String?
    public let mood: ServerMoodLevel?
    public let source: MoodEntrySource?
    public let limit: Int
    public let offset: Int

    public init(
        from: String? = nil,
        to: String? = nil,
        mood: ServerMoodLevel? = nil,
        source: MoodEntrySource? = nil,
        limit: Int = 25,
        offset: Int = 0
    ) {
        self.from = from
        self.to = to
        self.mood = mood
        self.source = source
        self.limit = min(max(limit, 1), 500)
        self.offset = max(offset, 0)
    }

    var queryItems: [(String, String)] {
        var items: [(String, String)] = []
        if let from { items.append(("from", from)) }
        if let to { items.append(("to", to)) }
        if let mood { items.append(("mood", mood.rawValue)) }
        if let source { items.append(("source", source.rawValue)) }
        items.append(("limit", String(limit)))
        items.append(("offset", String(offset)))
        items.append(("sortBy", "moodLoggedAt"))
        items.append(("sortDir", "desc"))
        return items
    }

    func matches(_ entry: MoodEntry, calendar: Calendar = .current) -> Bool {
        if let mood, entry.mood != mood { return false }
        if let source, entry.source?.uppercased() != source.rawValue { return false }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        if let from, let lower = formatter.date(from: from) {
            if entry.recordedAt < calendar.startOfDay(for: lower) { return false }
        }
        if let to, let upper = formatter.date(from: to) {
            guard let exclusiveUpper = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: upper)
            ) else { return false }
            if entry.recordedAt >= exclusiveUpper { return false }
        }
        return true
    }
}

public enum MoodHistoryPeriod: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all
    case last7Days
    case last30Days
    case last90Days
    case lastYear
    case custom

    public var id: String {
        rawValue
    }
}

public struct MoodHistoryFilter: Sendable, Equatable {
    public var period: MoodHistoryPeriod
    public var customFrom: String?
    public var customTo: String?
    public var mood: ServerMoodLevel?
    public var source: MoodEntrySource?

    public init(
        period: MoodHistoryPeriod = .all,
        customFrom: String? = nil,
        customTo: String? = nil,
        mood: ServerMoodLevel? = nil,
        source: MoodEntrySource? = nil
    ) {
        self.period = period
        self.customFrom = customFrom
        self.customTo = customTo
        self.mood = mood
        self.source = source
    }

    public mutating func reset() {
        self = MoodHistoryFilter()
    }

    public func query(
        limit: Int,
        offset: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MoodHistoryQuery {
        let bounds: (String?, String?) = switch period {
        case .all:
            (nil, nil)
        case .custom:
            if let customFrom, let customTo, customFrom > customTo {
                (customTo, customFrom)
            } else {
                (customFrom, customTo)
            }
        case .last7Days:
            Self.trailingBounds(days: 7, now: now, calendar: calendar)
        case .last30Days:
            Self.trailingBounds(days: 30, now: now, calendar: calendar)
        case .last90Days:
            Self.trailingBounds(days: 90, now: now, calendar: calendar)
        case .lastYear:
            Self.trailingBounds(days: 365, now: now, calendar: calendar)
        }
        return MoodHistoryQuery(
            from: bounds.0,
            to: bounds.1,
            mood: mood,
            source: source,
            limit: limit,
            offset: offset
        )
    }

    private static func trailingBounds(
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> (String?, String?) {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: first), formatter.string(from: today))
    }
}
