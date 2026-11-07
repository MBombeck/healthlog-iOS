import Foundation
import Observation

/// **1.5 BP-TOD** — the state behind ``BloodPressureTimeOfDaySection``.
///
/// Owned by the section, so it lives exactly as long as the open blood
/// pressure page and never outlives an account switch. Stale while
/// revalidate within the page: a range the page already read paints its last
/// answer at once and is re-read behind it; a new range keeps the previous
/// answer on screen (dimmed by the view) until its own lands, so switching
/// ranges does not collapse the section.
@MainActor
@Observable
final class BloodPressureTimeOfDayModel {
    enum Phase: Equatable {
        /// First read of the page in flight, nothing to show yet.
        case loading
        case loaded(BloodPressureTimeOfDay)
        /// The record's measurements are not readable here (module off, a
        /// sharing grant without measurements): the shared disabled card.
        case disabled(String?)
        /// The read failed and nothing of this range is held: retry row.
        case failed
        /// The server does not have the route after all (404): no section.
        case absent
    }

    private(set) var phase: Phase = .loading
    /// `true` while an answer is on screen and a newer one is on its way.
    private(set) var isRefreshing = false
    /// The window the answer on screen was read for.
    private(set) var shownDays: Int?

    @ObservationIgnored private var memo: [Int: BloodPressureTimeOfDay] = [:]
    @ObservationIgnored private let fetch: @Sendable (Int) async throws -> BloodPressureTimeOfDay

    init(fetch: @escaping @Sendable (Int) async throws -> BloodPressureTimeOfDay) {
        self.fetch = fetch
    }

    convenience init(repository: BloodPressureTimeOfDayRepository) {
        self.init { days in try await repository.fetch(days: days) }
    }

    /// Reads `days`, the chart's range. Cancellation (the range moved on
    /// again) leaves the state as it is for the next read to settle.
    func load(days: Int) async {
        if let cached = memo[days] {
            phase = .loaded(cached)
            shownDays = days
        }
        if case .loaded = phase {
            isRefreshing = true
        } else {
            phase = .loading
        }
        do {
            let answer = try await fetch(days)
            memo[days] = answer
            phase = .loaded(answer)
            shownDays = days
            isRefreshing = false
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return }
            isRefreshing = false
            let next = Self.phase(after: error, cached: memo[days])
            phase = next
            if case .loaded = next { shownDays = days } else { shownDays = nil }
        }
    }

    /// What a failed read turns into. A refusal is the record being closed
    /// here, a 404 a server without the route, anything else can be retried;
    /// a held answer of the same range stays up rather than turning into an
    /// error row.
    nonisolated static func phase(after error: Error, cached: BloodPressureTimeOfDay?) -> Phase {
        switch error as? HLError {
        case .moduleDisabled:
            return .disabled(nil)
        case let .server(status, _, _) where status == 403:
            return .disabled(nil)
        case let .server(status, _, _) where status == 404:
            return .absent
        default:
            if let cached { return .loaded(cached) }
            return .failed
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .canceled? = error as? HLError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }
}
