import Foundation
import Observation

/// **1.5 MOVE (#133)** — the state behind ``EnvironmentMovementSection``,
/// "Unterwegs" on the environment screen.
///
/// Owned by the section, so it lives as long as the open screen and never
/// outlives an account switch. Stale while revalidate within the screen: a
/// day already read paints its last answer at once and is re-read behind it.
///
/// The section starts on the last day the server holds (`latestDay` of
/// `GET /api/dawarich/status`) and steps one day back or forward, never past
/// today and never before the oldest stored day. It shows nothing the server
/// did not send: a day without values says so, a `null` field is left out.
@MainActor
@Observable
final class MovementStore {
    enum Phase: Equatable {
        /// First read in flight.
        case loading
        /// No section: a delegate, the module off, a server without Dawarich
        /// (404) or without the `movement` block.
        case hidden
        /// The account has no Dawarich connection: one line, connecting is
        /// done on the web.
        case notConnected
        /// Connected, but the server holds no day yet.
        case noData
        /// The status read failed and nothing is held: retry row.
        case failed
        /// A day is selected; ``dayPhase`` says what it shows.
        case ready
    }

    enum DayPhase: Equatable {
        case loading
        /// The day's block. `nil` means the server sent none for this day.
        case loaded(DayMovement?)
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var dayPhase: DayPhase = .loading
    private(set) var selectedDay: String?
    private(set) var status: DawarichStatus?

    @ObservationIgnored private var memo: [String: DayMovement?] = [:]
    /// Set once a day came back with a `movement` block, so a later day
    /// without one reads "no values" rather than "server without movement".
    @ObservationIgnored private var serverSendsMovement = false
    @ObservationIgnored private let fetchStatus: @Sendable () async throws -> DawarichStatus
    @ObservationIgnored private let fetchDay: @Sendable (String) async throws -> DayMovement?
    @ObservationIgnored private let today: () -> String

    init(
        fetchStatus: @escaping @Sendable () async throws -> DawarichStatus,
        fetchDay: @escaping @Sendable (String) async throws -> DayMovement?,
        today: @escaping () -> String = { MovementDay.today() }
    ) {
        self.fetchStatus = fetchStatus
        self.fetchDay = fetchDay
        self.today = today
    }

    convenience init(repository: MovementRepository) {
        self.init(
            fetchStatus: { try await repository.status() },
            fetchDay: { day in try await repository.movement(on: day) }
        )
    }

    // MARK: - Switcher bounds

    /// One day back is allowed until the oldest stored day.
    var canGoBack: Bool {
        guard phase == .ready, let day = selectedDay, let previous = MovementDay.shift(day, by: -1) else { return false }
        guard let oldest = status?.oldestDay else { return true }
        return previous >= oldest
    }

    /// One day forward is allowed up to today, never into the future.
    var canGoForward: Bool {
        guard phase == .ready, let day = selectedDay, let next = MovementDay.shift(day, by: 1) else { return false }
        return next <= today()
    }

    // MARK: - Loading

    /// Reads the connection, then the selected day (the latest stored day on
    /// the first read). A refresh that fails keeps what is on screen.
    func load() async {
        do {
            let current = try await fetchStatus()
            status = current
            guard current.connected else {
                phase = .notConnected
                selectedDay = nil
                return
            }
            guard let latest = current.latestDay else {
                phase = .noData
                selectedDay = nil
                return
            }
            let limit = today()
            let day = selectedDay ?? min(latest, limit)
            selectedDay = day
            await loadDay(day)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return }
            if Self.closesSection(error) {
                phase = .hidden
            } else if phase != .ready {
                phase = .failed
            }
        }
    }

    /// Steps the switcher by one day (`-1` back, `+1` forward) within bounds.
    func step(by offset: Int) async {
        guard offset < 0 ? canGoBack : canGoForward,
              let day = selectedDay,
              let next = MovementDay.shift(day, by: offset < 0 ? -1 : 1) else { return }
        selectedDay = next
        await loadDay(next)
    }

    /// Retry after a failure: the whole read when the status failed, the day
    /// otherwise.
    func retry() async {
        if phase == .ready, let day = selectedDay {
            await loadDay(day)
        } else {
            phase = .loading
            await load()
        }
    }

    private func loadDay(_ day: String) async {
        if let cached = memo[day] {
            dayPhase = .loaded(cached)
        } else {
            dayPhase = .loading
        }
        do {
            let movement = try await fetchDay(day)
            if movement != nil { serverSendsMovement = true }
            guard movement != nil || serverSendsMovement else {
                // "Fehlt der Block, fehlt der Abschnitt."
                phase = .hidden
                return
            }
            memo[day] = .some(movement)
            guard selectedDay == day else { return }
            dayPhase = .loaded(movement)
            phase = .ready
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return }
            if Self.closesSection(error) {
                phase = .hidden
                return
            }
            guard selectedDay == day else { return }
            if memo[day] == nil { dayPhase = .failed }
            phase = .ready
        }
    }

    // MARK: - Errors

    /// A refusal (module off, a delegate's record, the local sharing denial)
    /// or a server without the route closes the section; anything else can
    /// be retried.
    nonisolated static func closesSection(_ error: Error) -> Bool {
        switch error as? HLError {
        case .moduleDisabled:
            true
        case let .server(status, _, _) where status == 403 || status == 404:
            true
        default:
            false
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .canceled? = error as? HLError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }
}
