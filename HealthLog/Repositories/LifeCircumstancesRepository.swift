import Foundation

/// **LIFE (1.5.0, #132, Server #614)** — the life-circumstance routes.
///
/// - `GET /api/anamnesis/life-circumstances`: the six sections, read.
/// - `POST /api/anamnesis/facts`, `PATCH|DELETE /api/anamnesis/facts/{id}`:
///   the answers, written exactly like the three closed anamnesis kinds
///   (``AnamnesisRepository``), with an object value for the new kinds.
/// - `PATCH /api/anamnesis/life-circumstances/ai-sections`: the AI switches,
///   guarded by the about-me token (`UserHealthProfile.updatedAt`, read from
///   `GET /api/coach/about-me`). A stale token is `409 about_me_conflict`.
/// - `POST /api/anamnesis/life-circumstances/confirm`: "still true".
///
/// **No outbox, on purpose**, like the anamnesis facts: an answer is a rare,
/// deliberate statement on a detail screen, and a replayed POST would run into
/// `currentExists` as soon as the person answered again in between. A failed
/// write stays visible on the section with its reason. Every write carries an
/// `Idempotency-Key`, which covers the network retry inside one request.
///
/// The fact writes throw ``AnamnesisFactFailure`` (same routes, same errors);
/// the switch and confirm writes throw the raw ``HLError``.
public actor LifeCircumstancesRepository {
    let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    static let readPath = "/api/anamnesis/life-circumstances"
    static let factsPath = "/api/anamnesis/facts"
    static let aiSectionsPath = "/api/anamnesis/life-circumstances/ai-sections"
    static let confirmPath = "/api/anamnesis/life-circumstances/confirm"
    static let aboutMePath = "/api/coach/about-me"

    // MARK: - Read

    public func load() async throws -> LifeCircumstances {
        let request: APIRequest<LifeCircumstances> = .get(Self.readPath)
        return try await api.send(request)
    }

    /// The about-me token the AI switches are guarded by. `nil` when the
    /// profile row does not exist yet (the first switch then creates it) or
    /// the read fails; the switch is then sent without a token, as the web
    /// sends it.
    public func aiSectionsToken() async -> String? {
        let request: APIRequest<AboutMeToken> = .get(Self.aboutMePath)
        return try? await api.send(request).updatedAt
    }

    // MARK: - Facts

    public func apply(_ write: LifeFactWrite) async throws {
        do {
            switch write {
            case let .create(kind, value, validFrom):
                let request: APIRequest<EmptyResponse> = try .post(
                    Self.factsPath,
                    body: FactCreate(kind: kind.rawValue, value: value, validFrom: validFrom)
                )
                _ = try await api.send(request)
            case let .correct(revisionID, _, value, validFrom):
                let request: APIRequest<EmptyResponse> = try .patch(
                    "\(Self.factsPath)/\(revisionID)",
                    body: FactCorrection(value: value, validFrom: validFrom)
                )
                _ = try await api.send(request)
            case let .remove(revisionID):
                let request: APIRequest<EmptyResponse> = .delete("\(Self.factsPath)/\(revisionID)")
                _ = try await api.send(request)
            }
        } catch {
            throw AnamnesisFactFailure.from(error)
        }
    }

    // MARK: - AI switches and confirmation

    /// Switches the named sections and answers the new token.
    @discardableResult
    public func setAISections(_ sections: [String: Bool], baseUpdatedAt: String?) async throws -> String? {
        let request: APIRequest<AISectionsResult> = try .patch(
            Self.aiSectionsPath,
            body: AISectionsPatch(sections: sections, baseUpdatedAt: baseUpdatedAt)
        )
        return try await api.send(request).updatedAt
    }

    public func confirm(_ section: LifeSectionKey) async throws {
        let request: APIRequest<EmptyResponse> = try .post(Self.confirmPath, body: ConfirmBody(section: section.rawValue))
        _ = try await api.send(request)
    }

    // MARK: - Wire bodies

    private struct FactCreate: Encodable {
        let kind: String
        let value: LifeFactWireValue
        let validFrom: String?

        private enum CodingKeys: String, CodingKey {
            case kind, value, validFrom
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(validFrom, forKey: .validFrom)
        }
    }

    private struct FactCorrection: Encodable {
        let value: LifeFactWireValue
        let validFrom: String?

        private enum CodingKeys: String, CodingKey {
            case value, validFrom
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(validFrom, forKey: .validFrom)
        }
    }

    /// `baseUpdatedAt` is left out when unknown: a literal `null` is a 422.
    private struct AISectionsPatch: Encodable {
        let sections: [String: Bool]
        let baseUpdatedAt: String?

        private enum CodingKeys: String, CodingKey {
            case sections, baseUpdatedAt
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sections, forKey: .sections)
            try c.encodeIfPresent(baseUpdatedAt, forKey: .baseUpdatedAt)
        }
    }

    private struct AISectionsResult: Decodable {
        let updatedAt: String?
    }

    private struct ConfirmBody: Encodable {
        let section: String
    }

    private struct AboutMeToken: Decodable {
        let updatedAt: String?
    }
}
