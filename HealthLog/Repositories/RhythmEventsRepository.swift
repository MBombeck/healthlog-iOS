import Foundation

/// Wraps `GET /api/insights/rhythm-events` (server v1.10.0, route at
/// `src/app/api/insights/rhythm-events/route.ts`).
///
/// The route returns the user's timeline of device-flagged categorical EVENT
/// rows (irregular-rhythm / high-HR / low-HR / walking-steadiness /
/// breathing-disturbance) the wearable already produced + synced. It is a
/// pure DB read gated behind the server's `insightStatus` assistant-surface
/// flag; an account with no events returns `{ events: [], hasEvents: false }`
/// so the card self-suppresses (see `InsightsRhythmEventsCard`).
///
/// **Cache strategy:** daily SWR. The event timeline shifts at most a handful
/// of times a year, so the read routes through the Berlin-day-anchored
/// `.rhythmEvents` SWR ladder (cache-first on disk, single-flighted
/// revalidation) — the overview card paints cache-first on launch + the key
/// flips to a structural miss the moment the Berlin day rolls over.
///
/// **`nil` arms:** a `404` (route not deployed) or `422` maps to `nil` so the
/// caller hides the card rather than surfacing an error. (`200` with
/// `hasEvents: false` decodes normally and the card self-suppresses on the
/// empty timeline.)
public actor RhythmEventsRepository {
    private let api: APIClientProtocol
    /// Optional persistent daily SWR cache. When wired, ``fetch()`` paints from
    /// the on-disk `.rhythmEvents(day:)` snapshot first and revalidates in the
    /// background. `nil` (default) keeps the direct-fetch unit-test ergonomics.
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches the device-event timeline. Returns `nil` on a `404`/`422`
    /// (route absent / rejected) so the card hides; a `200` body (incl. the
    /// empty `hasEvents: false` shape) decodes + returns normally.
    public func fetch() async throws -> RhythmEventsDTO? {
        let api = api
        @Sendable func networkFetch() async throws -> RhythmEventsDTO {
            let req: APIRequest<RhythmEventsDTO> = .get("/api/insights/rhythm-events")
            return try await api.send(req)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(
                    .rhythmEvents(day: BerlinDayKey.string()),
                    decoding: RhythmEventsDTO.self,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Route not deployed yet / rejected → no card, never an error.
            return nil
        }
    }
}
