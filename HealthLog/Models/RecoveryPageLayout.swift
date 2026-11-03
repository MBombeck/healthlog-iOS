import Foundation

/// **1.4 B3 — what the Insights recovery page shows**, decided purely from the
/// built family so the rule is testable without a view.
///
/// Two trend cards and one calm list instead of a card per number: the
/// recovery score first, then the day strain (or, without it, the training
/// load), each with its last 30 days as a line. Every other current type is a
/// row with its latest reading and 30-day average. Only current types appear;
/// the family builder already dropped everything without a reading in the last
/// 30 days.
public struct RecoveryPageLayout: Equatable, Sendable {
    /// One current type with the two server values the page shows.
    public struct Reading: Equatable, Sendable, Identifiable {
        public let kind: MetricKind
        /// Server `latest`, wire unit.
        public let latest: Double
        /// Server `avg30`, wire unit.
        public let average30: Double

        public var id: MetricKind {
            kind
        }
    }

    /// Why the page has nothing to show.
    public enum Empty: Equatable, Sendable {
        /// No wearable reading at all: the server says so (`recoveryEmpty`,
        /// any reason), or the slice is gated or absent.
        case noWearable
        /// The server has recovery readings, none of them from the last 30 days.
        case nothingRecent
    }

    public let trends: [Reading]
    public let rows: [Reading]
    /// `nil` whenever a card or a row is shown.
    public let empty: Empty?

    /// The trend slots in order; each takes the first of its kinds that is
    /// current.
    static let trendSlots: [[MetricKind]] = [[.recoveryScore], [.dayStrain, .cardioLoad]]

    /// The days a trend line and the current-reading rule look back.
    public static let windowDays = 30

    public init(family: RecoveryInsightsDTO?) {
        let readings = (family?.items ?? []).compactMap { item -> Reading? in
            guard let kind = RecoveryInsightsRepository.familyOrder.first(where: {
                $0.availabilitySummaryKey == item.id
            }) else { return nil }
            return Reading(kind: kind, latest: item.latest, average30: item.average30)
        }
        let trends = Self.trendSlots.compactMap { slot in
            slot.lazy.compactMap { kind in readings.first { $0.kind == kind } }.first
        }
        self.trends = trends
        rows = readings.filter { reading in !trends.contains { $0.kind == reading.kind } }
        guard readings.isEmpty else {
            empty = nil
            return
        }
        // The server decides whether the page is empty and says why; with no
        // family at all (gated, absent) there is no wearable reading to show.
        if let family, family.emptyReason == nil {
            empty = .nothingRecent
        } else {
            empty = .noWearable
        }
    }

    /// The kinds whose readings the trend cards need, in card order.
    public var trendKinds: [MetricKind] {
        trends.map(\.kind)
    }

    /// The last 30 days of `kind`'s readings as a dated line, oldest first.
    /// The values are the server's readings unchanged; only the window and the
    /// order are applied here.
    public static func trendPoints(
        from readings: [Measurement],
        kind: MetricKind,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SeriesPoint] {
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
        return readings
            .filter { $0.kind == kind && $0.recordedAt >= cutoff && $0.primaryValue.isFinite }
            .sorted { $0.recordedAt < $1.recordedAt }
            .map { SeriesPoint(id: $0.id, at: $0.recordedAt, value: $0.primaryValue, secondary: nil) }
    }
}
