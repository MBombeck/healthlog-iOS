import Foundation

/// `GET /api/nutrients/energy-balance?days=N` (server 1.49.0): what was eaten
/// against resting plus active energy, day by day, with a seven-day trend.
///
/// Every figure is the server's. A `null` is "no data", never zero: a day that
/// misses any input has no balance, and the app shows none rather than
/// guessing one. A resting figure the server estimated from the profile
/// (Mifflin-St Jeor) carries `restingEstimated`; today is `partial`, still
/// running, and stands outside the trend and the means.
///
/// Tolerant like the other nutrient reads: a day this build cannot read costs
/// that day, never the answer.
public struct EnergyBalanceDTO: Decodable, Sendable, Equatable {
    public struct Day: Decodable, Sendable, Equatable, Identifiable {
        /// `YYYY-MM-DD`, the account's local day.
        public let day: String
        public let intakeKcal: Double?
        public let restingKcal: Double?
        public let restingEstimated: Bool
        public let activeKcal: Double?
        public let expenditureKcal: Double?
        public let balanceKcal: Double?
        public let trendKcal: Double?
        public let partial: Bool

        public var id: String {
            day
        }

        public init(
            day: String,
            intakeKcal: Double?,
            restingKcal: Double?,
            restingEstimated: Bool = false,
            activeKcal: Double?,
            expenditureKcal: Double?,
            balanceKcal: Double?,
            trendKcal: Double? = nil,
            partial: Bool = false
        ) {
            self.day = day
            self.intakeKcal = intakeKcal
            self.restingKcal = restingKcal
            self.restingEstimated = restingEstimated
            self.activeKcal = activeKcal
            self.expenditureKcal = expenditureKcal
            self.balanceKcal = balanceKcal
            self.trendKcal = trendKcal
            self.partial = partial
        }

        private enum CodingKeys: String, CodingKey {
            case day, intakeKcal, restingKcal, restingEstimated, activeKcal, expenditureKcal, balanceKcal, trendKcal,
                 partial
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            intakeKcal = EnergyBalanceDTO.number(c, .intakeKcal)
            restingKcal = EnergyBalanceDTO.number(c, .restingKcal)
            restingEstimated = (try? c.decodeIfPresent(Bool.self, forKey: .restingEstimated)).flatMap { $0 } ?? false
            activeKcal = EnergyBalanceDTO.number(c, .activeKcal)
            expenditureKcal = EnergyBalanceDTO.number(c, .expenditureKcal)
            balanceKcal = EnergyBalanceDTO.number(c, .balanceKcal)
            trendKcal = EnergyBalanceDTO.number(c, .trendKcal)
            partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)).flatMap { $0 } ?? false
        }
    }

    public struct Summary: Decodable, Sendable, Equatable {
        public let daysWithBalance: Int
        public let meanIntakeKcal: Double?
        public let meanExpenditureKcal: Double?
        public let meanBalanceKcal: Double?

        public init(daysWithBalance: Int, meanIntakeKcal: Double?, meanExpenditureKcal: Double?, meanBalanceKcal: Double?) {
            self.daysWithBalance = daysWithBalance
            self.meanIntakeKcal = meanIntakeKcal
            self.meanExpenditureKcal = meanExpenditureKcal
            self.meanBalanceKcal = meanBalanceKcal
        }

        private enum CodingKeys: String, CodingKey {
            case daysWithBalance, meanIntakeKcal, meanExpenditureKcal, meanBalanceKcal
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            daysWithBalance = (try? c.decodeIfPresent(Int.self, forKey: .daysWithBalance)).flatMap { $0 } ?? 0
            meanIntakeKcal = EnergyBalanceDTO.number(c, .meanIntakeKcal)
            meanExpenditureKcal = EnergyBalanceDTO.number(c, .meanExpenditureKcal)
            meanBalanceKcal = EnergyBalanceDTO.number(c, .meanBalanceKcal)
        }
    }

    public let windowDays: Int
    public let days: [Day]
    public let summary: Summary
    /// What the resting estimate lacks (`weight`, `height`, `birthDate`,
    /// `sex`), raw; empty when the estimate can be made.
    public let estimateGaps: [String]

    public init(windowDays: Int, days: [Day], summary: Summary, estimateGaps: [String] = []) {
        self.windowDays = windowDays
        self.days = days
        self.summary = summary
        self.estimateGaps = estimateGaps
    }

    private enum CodingKeys: String, CodingKey {
        case windowDays, days, summary, estimateGaps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowDays = (try? c.decodeIfPresent(Int.self, forKey: .windowDays)).flatMap { $0 } ?? 0
        days = ((try? c.decodeIfPresent([Lossy].self, forKey: .days)).flatMap { $0 } ?? []).compactMap(\.day)
        summary = (try? c.decodeIfPresent(Summary.self, forKey: .summary)).flatMap { $0 }
            ?? Summary(daysWithBalance: 0, meanIntakeKcal: nil, meanExpenditureKcal: nil, meanBalanceKcal: nil)
        estimateGaps = (try? c.decodeIfPresent([String].self, forKey: .estimateGaps)).flatMap { $0 } ?? []
    }

    /// A finite number, or `nil` for null, absent or unreadable.
    fileprivate static func number<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        guard let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite else {
            return nil
        }
        return value
    }

    private struct Lossy: Decodable {
        let day: Day?

        init(from decoder: Decoder) throws {
            day = try? Day(from: decoder)
        }
    }
}

// MARK: - What the page shows

public extension EnergyBalanceDTO {
    /// The days the server closed, oldest first: today (`partial`) left out.
    var completeDays: [Day] {
        days.filter { !$0.partial }
    }

    /// Today while it runs, when the server sent it.
    var runningDay: Day? {
        days.last { $0.partial }
    }

    /// The headline: the latest seven-day trend, else the window's mean
    /// balance. `nil` when neither exists (no complete day with a balance).
    var headlineKcal: Double? {
        latestTrendKcal ?? summary.meanBalanceKcal
    }

    /// The most recent trend over complete days, `nil` before four days
    /// carry a balance.
    var latestTrendKcal: Double? {
        completeDays.last { $0.trendKcal != nil }?.trendKcal
    }

    /// `true` when the headline is the trend rather than the window mean.
    var headlineIsTrend: Bool {
        latestTrendKcal != nil
    }

    /// The card is shown once any day of the window holds an intake; before
    /// that there is nothing to balance (web: the card renders nothing).
    var hasIntake: Bool {
        days.contains { $0.intakeKcal != nil }
    }

    /// Complete days with a balance, newest first, at most `limit`.
    func listedDays(limit: Int = 7) -> [Day] {
        Array(completeDays.filter { $0.balanceKcal != nil }.suffix(limit).reversed())
    }

    /// Complete days whose balance rests on an estimated resting figure.
    var estimatedDayCount: Int {
        completeDays.filter { $0.restingEstimated && $0.balanceKcal != nil }.count
    }

    /// Why there is no headline: the profile lacks what the estimate needs,
    /// or no active energy arrived on the days with an intake.
    enum MissingReason: Equatable, Sendable {
        case needsProfile
        case needsExpenditure
    }

    var missingReason: MissingReason? {
        guard headlineKcal == nil else { return nil }
        return estimateGaps.isEmpty ? .needsExpenditure : .needsProfile
    }
}
