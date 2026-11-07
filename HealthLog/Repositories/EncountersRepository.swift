import Foundation

/// **1.5 VISIT (#149 item 2)** — the two reads behind "Nächster Termin" on
/// Vorsorge. A thin read-only `actor` like ``BloodPressureTimeOfDayRepository``:
/// no outbox, no disk cache (the window depends on "today" and on visits booked
/// on the web at any time; the section keeps the open page's answer in memory).
///
/// `/api/encounters` is the profile section of the record and has no module
/// gate on the server; `/api/day/notable` reads the measurements section. A
/// delegate whose grant lacks either gets the refusal for that read alone.
public actor EncountersRepository {
    /// Booked visits listed per page. The section shows one; a few more let a
    /// push or a hero action name a visit that is not the soonest.
    public static let upcomingLimit = 10

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// The booked visits ahead, soonest first (`status=PLANNED`; the server
    /// splits `upcoming` from `past` itself, so only `upcoming` is read).
    public func upcoming() async throws -> UpcomingEncounters {
        let request: APIRequest<UpcomingEncounters> = .get(
            "/api/encounters",
            query: [("status", "PLANNED"), ("limit", String(Self.upcomingLimit))]
        )
        return try await api.send(request)
    }

    /// What stood out in the window of the next booked visit. No `from` and
    /// no `to`: the server anchors at that visit's `preparation.from` and ends
    /// today, so the app reads the window the web shows.
    public func notableSinceLastVisit() async throws -> DayNotableWindow {
        let request: APIRequest<DayNotableWindow> = .get("/api/day/notable")
        return try await api.send(request)
    }
}
