import Foundation

/// The energy balance under Ernährung (server 1.49.0): the list's summary
/// row and the page behind it read the same state, held by the list.
@MainActor
@Observable
final class EnergyBalanceModel {
    enum State: Equatable {
        /// Not read yet.
        case idle
        /// Nothing to show: the module is off, the server is older than 1.49,
        /// or no day of the window holds an intake yet.
        case hidden
        case loaded(EnergyBalanceDTO)
        /// The read failed for another reason; the row offers a retry.
        case failed
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var fetch: (@MainActor () async throws -> EnergyBalanceDTO)?

    func load(fetch: @escaping @MainActor () async throws -> EnergyBalanceDTO) async {
        self.fetch = fetch
        await reload()
    }

    func reload() async {
        guard let fetch else { return }
        do {
            state = try await Self.state(for: fetch())
        } catch {
            state = Self.state(after: error) ?? state
        }
    }

    /// A balance with no intake anywhere in the window has nothing to say
    /// (the web card renders nothing then).
    nonisolated static func state(for balance: EnergyBalanceDTO) -> State {
        balance.hasIntake ? .loaded(balance) : .hidden
    }

    /// `nil` keeps the current state (a cancelled read changes nothing).
    nonisolated static func state(after error: Error) -> State? {
        if error is CancellationError { return nil }
        if case .canceled? = error as? HLError { return nil }
        return EnergyBalanceRepository.hidesCard(error) ? .hidden : .failed
    }
}

/// The page's wording, pure so tests can pin it. Every number is the
/// server's; nothing is recomputed here.
enum EnergyBalanceFormat {
    /// A balance with its sign: "+120 kcal", "-340 kcal". Never coloured as
    /// good or bad: a deficit is a goal for one person and a warning for
    /// another.
    static func signedKcal(_ value: Double) -> String {
        "\(HLValueFormat.signedNumber(value, fractionDigits: 0 ... 0)) kcal"
    }

    static func kcal(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 0 ... 0)
    }

    /// The headline's line under the figure: the trend's seven days, or the
    /// window mean over the days that carry a balance.
    static func headlineMeta(_ balance: EnergyBalanceDTO) -> String {
        let days = balance.summary.daysWithBalance
        if balance.headlineIsTrend { return String(localized: "nutrients.energyBalance.trendMeta") }
        return days == 1
            ? String(localized: "nutrients.energyBalance.meanMeta.one")
            : String(localized: "nutrients.energyBalance.meanMeta \(days)")
    }

    /// The list row's side line, short.
    static func rowDetail(_ balance: EnergyBalanceDTO) -> String {
        guard balance.headlineKcal != nil else { return String(localized: "nutrients.energyBalance.row.none") }
        let days = balance.summary.daysWithBalance
        if balance.headlineIsTrend { return String(localized: "nutrients.energyBalance.row.trend") }
        return days == 1
            ? String(localized: "nutrients.energyBalance.row.mean.one")
            : String(localized: "nutrients.energyBalance.row.mean \(days)")
    }

    /// "Über 21 Tage im Mittel 2.150 kcal gegessen und 2.300 kcal verbraucht."
    /// `nil` while either mean is missing.
    static func means(_ balance: EnergyBalanceDTO) -> String? {
        guard let intake = balance.summary.meanIntakeKcal, let used = balance.summary.meanExpenditureKcal else { return nil }
        let days = balance.summary.daysWithBalance
        return days == 1
            ? String(localized: "nutrients.energyBalance.means.one \(kcal(intake)) \(kcal(used))")
            : String(localized: "nutrients.energyBalance.means \(days) \(kcal(intake)) \(kcal(used))")
    }

    /// "2.150 kcal gegessen, 2.300 kcal verbraucht"; `nil` while either is
    /// missing.
    static func dayLine(_ day: EnergyBalanceDTO.Day) -> String? {
        guard let intake = day.intakeKcal, let used = day.expenditureKcal else { return nil }
        return String(localized: "nutrients.energyBalance.dayLine \(kcal(intake)) \(kcal(used))")
    }

    /// Why there is no headline yet.
    static func missing(_ reason: EnergyBalanceDTO.MissingReason) -> String {
        switch reason {
        case .needsProfile: String(localized: "nutrients.energyBalance.needsProfile")
        case .needsExpenditure: String(localized: "nutrients.energyBalance.needsExpenditure")
        }
    }

    /// The note under the days when some balances rest on an estimate.
    static func estimatedNote(_ balance: EnergyBalanceDTO) -> String? {
        let count = balance.estimatedDayCount
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "nutrients.energyBalance.estimated.one")
            : String(localized: "nutrients.energyBalance.estimated \(count)")
    }

    /// The day in the user's date format; today and yesterday by name.
    static func dayTitle(_ day: EnergyBalanceDTO.Day, now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = day.day.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3,
           let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        {
            if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
        }
        return RelatedRecordFormat.date(day.day) ?? day.day
    }
}
