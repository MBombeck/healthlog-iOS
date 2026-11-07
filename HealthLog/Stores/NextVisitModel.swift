import Foundation
import Observation

/// **1.5 VISIT** — the state behind ``NextVisitSection``.
///
/// Owned by the section, so it lives exactly as long as the open Vorsorge page
/// and never outlives an account switch. A re-read keeps the answer on screen
/// until the new one lands (stale while revalidate within the page).
@MainActor
@Observable
final class NextVisitModel {
    enum Phase: Equatable {
        /// First read in flight, nothing to show yet (the section stays away
        /// rather than opening a card for what is most often no visit).
        case loading
        /// Nothing booked, a server without the route, offline: no section.
        case hidden
        case loaded(NextVisit)
        /// The grant does not cover visits (`403`, `module.disabled`).
        case disabled(String?)
        /// The read failed and nothing is held: heading, sentence, retry.
        case failed
    }

    /// The booked visit the section shows, and what stood out before it.
    struct NextVisit: Equatable {
        let visit: EncounterDTO
        /// Up to ``maxNotableRows`` rows, oldest first; empty means the line
        /// is left out.
        let notable: [NotableRow]
    }

    /// One "Auffälliges seither" row: its day key and its wording.
    struct NotableRow: Equatable, Identifiable {
        let id: String
        let date: String
        let text: String
    }

    nonisolated static let maxNotableRows = 5

    private(set) var phase: Phase = .loading

    @ObservationIgnored private let fetchUpcoming: @Sendable () async throws -> UpcomingEncounters
    @ObservationIgnored private let fetchNotable: @Sendable () async throws -> DayNotableWindow
    @ObservationIgnored private let wording: NotableWording

    init(
        fetchUpcoming: @escaping @Sendable () async throws -> UpcomingEncounters,
        fetchNotable: @escaping @Sendable () async throws -> DayNotableWindow,
        wording: NotableWording = .app
    ) {
        self.fetchUpcoming = fetchUpcoming
        self.fetchNotable = fetchNotable
        self.wording = wording
    }

    convenience init(repository: EncountersRepository) {
        self.init(
            fetchUpcoming: { try await repository.upcoming() },
            fetchNotable: { try await repository.notableSinceLastVisit() }
        )
    }

    /// Reads the booked visits, picks the one to show (``visit(toShow:focus:)``)
    /// and, when it carries a window, what stood out in it.
    func load(focus: String?) async {
        let upcoming: UpcomingEncounters
        do {
            upcoming = try await fetchUpcoming()
        } catch {
            if let next = Self.phase(after: error, holding: phase) { phase = next }
            return
        }
        guard let visit = Self.visit(toShow: upcoming.upcoming, focus: focus) else {
            phase = .hidden
            return
        }
        let notable = await notableRows(for: visit, isSoonest: visit.id == upcoming.upcoming.first?.id)
        phase = .loaded(NextVisit(visit: visit, notable: notable))
    }

    /// The visit named by a push or a hero action when it is still booked,
    /// else the soonest. Only `PLANNED` rows count.
    nonisolated static func visit(toShow upcoming: [EncounterDTO], focus: String?) -> EncounterDTO? {
        let planned = upcoming.filter { ($0.status ?? "PLANNED") == "PLANNED" }
        if let focus, let named = planned.first(where: { $0.id == focus }) { return named }
        return planned.first
    }

    /// The rows read without `from` belong to the soonest booked visit only,
    /// and only when the server's window is that visit's own: an older server
    /// anchors elsewhere (the last visit), and that window is not the one the
    /// heading names. Any failure leaves the line out; the visit still shows.
    private func notableRows(for visit: EncounterDTO, isSoonest: Bool) async -> [NotableRow] {
        guard isSoonest, let preparation = visit.preparation else { return [] }
        guard let window = try? await fetchNotable() else { return [] }
        return Self.rows(window, preparation: preparation, wording: wording)
    }

    nonisolated static func rows(
        _ window: DayNotableWindow,
        preparation: EncounterPreparation,
        wording: NotableWording
    ) -> [NotableRow] {
        guard window.from == preparation.from else { return [] }
        var rows: [NotableRow] = window.changes.map { change in
            NotableRow(
                id: "change-\(change.kind)-\(change.id)-\(change.date)",
                date: change.date,
                text: wording.change(change)
            )
        }
        for observation in window.observations {
            guard let text = wording.observation(observation) else { continue }
            rows.append(NotableRow(
                id: "notable-\(observation.date)-\(observation.kind)-\(observation.type ?? "")",
                date: observation.date,
                text: text
            ))
        }
        // Oldest first, as the web lists the window; the sort is stable, so
        // rows of one day keep the server's order.
        let sorted = rows.enumerated().sorted { lhs, rhs in
            lhs.element.date == rhs.element.date ? lhs.offset < rhs.offset : lhs.element.date < rhs.element.date
        }.map(\.element)
        return Array(sorted.prefix(maxNotableRows))
    }

    /// What a failed visit read turns into; `nil` keeps the current phase (a
    /// cancelled read changes nothing). A held answer stays up.
    nonisolated static func phase(after error: Error, holding current: Phase) -> Phase? {
        if error is CancellationError { return nil }
        if let url = error as? URLError, url.code == .cancelled { return nil }
        switch error as? HLError {
        case .canceled:
            return nil
        case let .moduleDisabled(reason):
            return .disabled(reason)
        case let .server(status, _, _) where status == 403:
            return .disabled(nil)
        case let .server(status, _, _) where status == 404:
            return .hidden
        case .offline, .unauthorized, .serverNotConfigured:
            if case .loaded = current { return current }
            return .hidden
        default:
            if case .loaded = current { return current }
            return .failed
        }
    }
}

/// How the section words a notable row. A value, so tests word rows without
/// the app bundle's metric catalogue.
struct NotableWording: Sendable {
    let change: @Sendable (DayNotableWindow.Change) -> String
    /// `nil` drops the row (a first reading, an unknown kind or metric).
    let observation: @Sendable (DayNotableWindow.Observation) -> String?
}
