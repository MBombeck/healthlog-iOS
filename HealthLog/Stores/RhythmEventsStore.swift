import Foundation
import Observation

/// `@Observable` wrapper over `RhythmEventsRepository`. Drives the
/// `InsightsRhythmEventsCard` on the Insights overview — the device-flagged
/// categorical-event timeline + the permanent regulatory disclaimer.
///
/// **Self-suppression contract.** ``events`` is empty whenever (a) the server
/// returned `hasEvents: false`, (b) the route 404/422'd (repo returned `nil`),
/// or (c) a read error left the store cold. The card reads ``events`` and
/// renders `EmptyView` on empty — no header, no shell, no alarming empty card.
@MainActor
@Observable
public final class RhythmEventsStore {
    public private(set) var response: RhythmEventsDTO?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    private let repo: RhythmEventsRepository

    public init(repo: RhythmEventsRepository) {
        self.repo = repo
    }

    /// The device-event rows, newest first (server order). Empty on every
    /// no-data / no-route / error arm — the card self-suppresses.
    public var events: [RhythmEventsDTO.Event] {
        guard let response, response.hasEvents else { return [] }
        return response.events
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            response = try await repo.fetch()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        response = nil
        error = nil
    }
}
