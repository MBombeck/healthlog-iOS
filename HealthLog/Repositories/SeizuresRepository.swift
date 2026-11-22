import Foundation

/// Actor repository for the seizure diary (server v1.48.0, #1368, #182 A4):
/// `GET /api/seizures`, `/api/seizures/events/**` (with rescue doses),
/// `/api/seizures/types/**` and `/api/seizures/settings`.
///
/// **Network-direct, no outbox.** The quick log keeps the running timer and
/// its idempotency key in the store until the server confirms, so a failed
/// stop is retried under the same key and lands once. Every route answers 403
/// `seizures.disabled` while the module is off (``isSeizuresDisabled(_:)``).
public actor SeizuresRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// The module is off for this record, or the operator turned it off.
    public nonisolated static func isSeizuresDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error { return module == SeizuresModule.wireKey }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && code == "seizures.disabled"
        }
        return false
    }

    /// The type still names seizures and can only be archived.
    public nonisolated static func isTypeInUse(_ error: Error) -> Bool {
        if case let HLError.server(status, code, _) = error { return status == 409 && code == "seizures.type.inUse" }
        return false
    }

    /// The record already holds twelve active types.
    public nonisolated static func isTypeLimit(_ error: Error) -> Bool {
        if case let HLError.server(status, code, _) = error { return status == 422 && code == "seizures.type.limit" }
        return false
    }

    // MARK: - Read

    /// The diary for the default period (the last 90 days) or `from` ... `to`.
    public func diary(from: Date? = nil, to: Date? = nil) async throws -> SeizureDiaryDTO {
        var query: [(String, String)] = []
        if let from { query.append(("from", SeizureDateFormat.wire(from))) }
        if let to { query.append(("to", SeizureDateFormat.wire(to))) }
        let request: APIRequest<SeizureDiaryDTO> = .get("/api/seizures", query: query)
        return try await api.send(request)
    }

    // MARK: - Events

    public func createEvent(_ body: SeizureEventWrite, idempotencyKey: IdempotencyKey) async throws -> SeizureEventDTO {
        let request: APIRequest<SeizureEventDTO> = try .post(
            "/api/seizures/events", body: body, idempotencyKey: idempotencyKey
        )
        return try await api.send(request)
    }

    public func updateEvent(id: String, _ body: SeizureEventWrite) async throws -> SeizureEventDTO {
        let request: APIRequest<SeizureEventDTO> = try .patch("/api/seizures/events/\(Self.escaped(id))", body: body)
        return try await api.send(request)
    }

    /// A hard delete; the server also undoes the intakes its rescue doses recorded.
    public func deleteEvent(id: String) async throws {
        let request: APIRequest<EmptyPayload> = .delete("/api/seizures/events/\(Self.escaped(id))")
        try await api.sendVoid(request)
    }

    // MARK: - Rescue doses

    public func addRescueDose(
        eventId: String,
        _ body: SeizureRescueDoseCreate,
        idempotencyKey: IdempotencyKey
    ) async throws -> SeizureRescueDoseDTO {
        let request: APIRequest<SeizureRescueDoseDTO> = try .post(
            "/api/seizures/events/\(Self.escaped(eventId))/rescue", body: body, idempotencyKey: idempotencyKey
        )
        return try await api.send(request)
    }

    public func updateRescueDose(eventId: String, doseId: String, _ body: SeizureRescueDosePatch) async throws -> SeizureRescueDoseDTO {
        let request: APIRequest<SeizureRescueDoseDTO> = try .patch(
            "/api/seizures/events/\(Self.escaped(eventId))/rescue/\(Self.escaped(doseId))", body: body
        )
        return try await api.send(request)
    }

    public func deleteRescueDose(eventId: String, doseId: String) async throws {
        let request: APIRequest<EmptyPayload> = .delete(
            "/api/seizures/events/\(Self.escaped(eventId))/rescue/\(Self.escaped(doseId))"
        )
        try await api.sendVoid(request)
    }

    // MARK: - Types

    private struct TypeList: Decodable, Sendable {
        let types: [SeizureTypeDTO]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            types = ((try? c.decodeIfPresent([SeizureLossy<SeizureTypeDTO>].self, forKey: .types)) ?? []).compactMap(\.value)
        }

        private enum CodingKeys: String, CodingKey {
            case types
        }
    }

    /// `GET /api/seizures/types`: every type, the archived ones included.
    public func types() async throws -> [SeizureTypeDTO] {
        let request: APIRequest<TypeList> = .get("/api/seizures/types")
        return try await api.send(request).types
    }

    public func createType(_ body: SeizureTypeWrite) async throws -> SeizureTypeDTO {
        let request: APIRequest<SeizureTypeDTO> = try .post("/api/seizures/types", body: body)
        return try await api.send(request)
    }

    public func updateType(id: String, _ body: SeizureTypeWrite) async throws -> SeizureTypeDTO {
        let request: APIRequest<SeizureTypeDTO> = try .patch("/api/seizures/types/\(Self.escaped(id))", body: body)
        return try await api.send(request)
    }

    /// 409 `seizures.type.inUse` while seizures name the type: archive it instead.
    public func deleteType(id: String) async throws {
        let request: APIRequest<EmptyPayload> = .delete("/api/seizures/types/\(Self.escaped(id))")
        try await api.sendVoid(request)
    }

    // MARK: - Settings

    /// `GET /api/seizures/settings`: the record's cluster rule beside NICE's.
    public func settings() async throws -> SeizureSettingsDTO {
        let request: APIRequest<SeizureSettingsDTO> = .get("/api/seizures/settings")
        return try await api.send(request)
    }

    public func updateSettings(_ rule: SeizureClusterRule) async throws -> SeizureSettingsDTO {
        let request: APIRequest<SeizureSettingsDTO> = try .patch("/api/seizures/settings", body: SeizureSettingsPatch(rule: rule))
        return try await api.send(request)
    }

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}

/// The seizure routes a WRITE grant reaches with a POST (server table in
/// #191): a new seizure and a rescue dose on a seizure.
public enum SeizureRoutePaths {
    public static func isWriteLevelPost(_ path: String) -> Bool {
        if path == "/api/seizures/events" { return true }
        let parts = path.split(separator: "/").map(String.init)
        // api, seizures, events, {id}, rescue
        return parts.count == 5 && parts[0] == "api" && parts[1] == "seizures" && parts[2] == "events" && parts[4] == "rescue"
    }
}

/// The `seizures` module (server v1.48.0): opt-in and off by default. Unlike
/// the default-on modules the app only offers the diary when the server's
/// module map names it and says `true`: an older server, or a map without the
/// key, shows nothing. From 1.48.0 on the key is always present; the reason
/// behind a `false` is `moduleAccess.seizures`.
public enum SeizuresModule {
    public static let wireKey = "seizures"

    public static func isAvailable(modules: [String: Bool]?) -> Bool {
        modules?[wireKey] == true
    }
}
