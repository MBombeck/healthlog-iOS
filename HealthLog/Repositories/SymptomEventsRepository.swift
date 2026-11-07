import Foundation

/// **SYMPTOM (1.5.0, #144, server #1237)** — the symptom occurrences filed
/// against an illness episode, and the symptoms they name.
///
/// - `GET /api/symptoms/events?episodeId=`: the occurrences linked to one
///   episode, newest first. **Never by time span**: an occurrence belongs to
///   an episode only through its link (server v1.43.4). A page holds at most
///   500; the read pages on with `to` set to the oldest time seen, as the
///   contract says, and drops the one row both pages share.
/// - `GET /api/symptoms/definitions?includeHidden=true`: the labels, hidden
///   ones too, because an occurrence of a hidden symptom stays listed.
/// - `POST`, `PATCH` and `DELETE` on `/api/symptoms/events[/{id}]`.
///
/// **No outbox, on purpose**, like the life-circumstance answers: an edit here
/// is a deliberate act on an open page, and a failure stays visible on that
/// page with its reason. Every write carries an `Idempotency-Key`.
///
/// Symptoms ride the illness module: a refusal is `403 illness.disabled`
/// (``IllnessRepository/isIllnessDisabled(_:)`` reads it).
public actor SymptomEventsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// From this server on, `episodeId` filters by the link. An older server
    /// ignores the query and would answer with every occurrence of the record,
    /// so the episode page shows no symptoms there (Regel 10).
    static let minimumServerVersion = "1.43.4"
    static let eventsPath = "/api/symptoms/events"
    static let definitionsPath = "/api/symptoms/definitions"
    static let pageLimit = 500
    /// Ten pages are 5000 occurrences on one episode; the read stops there.
    static let maxPages = 10

    // MARK: - Reads

    public func events(episodeId: String) async throws -> [SymptomEvent] {
        var collected: [SymptomEvent] = []
        var seen = Set<String>()
        var before: String?
        for _ in 0 ..< Self.maxPages {
            var query: [(String, String)] = [("episodeId", episodeId), ("limit", String(Self.pageLimit))]
            if let before { query.append(("to", before)) }
            let request: APIRequest<SymptomEventPage> = .get(Self.eventsPath, query: query)
            let page = try await api.send(request)
            for event in page.events where seen.insert(event.id).inserted {
                collected.append(event)
            }
            guard page.hasMore, let oldest = page.events.last?.occurredAt, oldest != before else { break }
            before = oldest
        }
        // The route already narrows to the link; this keeps a wider answer
        // from ever showing another episode's occurrence here.
        return collected.filter { $0.episodeId == episodeId }
    }

    public func definitions() async throws -> [SymptomDefinition] {
        let request: APIRequest<SymptomDefinitionList> = .get(Self.definitionsPath, query: [("includeHidden", "true")])
        return try await api.send(request).definitions
    }

    // MARK: - Writes

    @discardableResult
    public func create(_ body: SymptomEventCreate) async throws -> SymptomEvent {
        let request: APIRequest<SymptomEvent> = try .post(Self.eventsPath, body: body)
        return try await api.send(request)
    }

    @discardableResult
    public func update(id: String, _ patch: SymptomEventPatch) async throws -> SymptomEvent {
        let request: APIRequest<SymptomEvent> = try .patch("\(Self.eventsPath)/\(id)", body: patch)
        return try await api.send(request)
    }

    public func delete(id: String) async throws {
        let request: APIRequest<EmptyResponse> = .delete("\(Self.eventsPath)/\(id)")
        _ = try await api.send(request)
    }

    // MARK: - Errors

    /// `422 symptoms.episode.notOpen`: the chosen episode did not run at the
    /// occurrence's time (or no longer exists).
    public nonisolated static func isEpisodeNotOpen(_ error: Error) -> Bool {
        if case let HLError.server(status, code, _) = error {
            return status == 422 && code == "symptoms.episode.notOpen"
        }
        return false
    }

    /// `404`: the occurrence (or the symptom it names) is gone.
    public nonisolated static func isGone(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 404
        }
        return false
    }
}
