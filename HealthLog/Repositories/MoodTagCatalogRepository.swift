import Foundation

/// SWR client for `GET /api/mood/tags` (server v1.8.5 — structured mood-tag
/// taxonomy catalog). Same shape as ``MeasurementCategoriesRepository``: an
/// actor over the shared `APIClient`, an in-memory snapshot with a daily TTL,
/// stale-while-revalidate, and a hardcoded bundled fallback so the tagging
/// grid renders instantly on a cold / offline launch.
///
/// **Cache:** daily TTL (the catalog is global reference data that changes
/// only when a deployment re-seeds). Reload outside the TTL is transparent —
/// the next ``catalog()`` triggers a refresh; on failure it returns the last
/// good snapshot, then the bundled fallback.
///
/// **Never throws:** the catalog drives a capture surface. A network/decode
/// failure degrades to the last snapshot or the bundled mirror — an empty
/// picker would be worse than a slightly-stale one.
public actor MoodTagCatalogRepository {
    private let api: APIClientProtocol
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private var cached: MoodTagCatalog?
    private var cachedAt: Date?
    /// **CU-20 (#69)** — last `updatedAt` seen from `/api/mood/tags/layout`.
    /// The GET emits this key **conditionally** (omitted, not null, when the
    /// user row did not resolve — `route.ts:57-61`), so `nil` legitimately
    /// means "no token" and the next PUT goes out unconditional.
    private var layoutToken: String?

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentLayoutToken() -> String? {
        layoutToken
    }

    public init(
        api: APIClientProtocol,
        cacheTTL: TimeInterval = 86400, // 24 h — global reference data.
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Best available catalog. Server-hit inside TTL → return; outside TTL →
    /// refresh, falling back to the stale snapshot on failure; never online →
    /// ``bundledFallback``.
    public func catalog() async -> MoodTagCatalog {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        do {
            let payload = try await fetchFromServer()
            // A degenerate empty server response keeps the bundled set rather
            // than rendering an empty grid.
            if payload.isEmpty {
                return cached ?? Self.bundledFallback
            }
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            HLLog.api.warning(
                "MoodTagCatalogRepository fetch failed; falling back: \(error.localizedDescription, privacy: .private)"
            )
            return cached ?? Self.bundledFallback
        }
    }

    /// Test-hook: invalidate so the next ``catalog()`` re-fetches.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }

    /// Test-hook: is the current answer from a server snapshot (`true`) or the
    /// bundled fallback (`nil` = never fetched)?
    public var cacheState: Bool? {
        cached != nil
    }

    private func fetchFromServer() async throws -> MoodTagCatalog {
        let req: APIRequest<MoodTagCatalog> = .get("/api/mood/tags")
        return try await api.send(req)
    }

    // MARK: - Management read and mutations

    /// Authoritative management catalog, including hidden catalogue tags,
    /// archived custom tags, custom groups, and usage counts.
    public func managementCatalog() async throws -> MoodTagCatalog {
        let req: APIRequest<MoodTagCatalog> = .get(
            "/api/mood/tags",
            query: [("include", "hidden,archived,usage")]
        )
        return try await api.send(req)
    }

    @discardableResult
    public func createCustom(label: String, icon: String?, categoryKey: String?) async throws -> MoodTagDTO {
        let body = CreateCustomTagRequest(label: label, icon: icon, categoryKey: categoryKey)
        let req: APIRequest<MoodTagDTO> = try .post("/api/mood/tags/custom", body: body)
        let created = try await api.send(req)
        invalidateCache()
        return created
    }

    @discardableResult
    public func updateCustom(
        key: String,
        label: String?,
        icon: String?,
        isActive: Bool?,
        categoryKey: String? = nil
    ) async throws -> MoodTagDTO {
        let body = UpdateCustomTagRequest(
            label: label,
            icon: icon,
            isActive: isActive,
            categoryKey: categoryKey
        )
        let req: APIRequest<MoodTagDTO> = try .patch(
            "/api/mood/tags/custom/\(Self.pathComponent(key))",
            body: body
        )
        let updated = try await api.send(req)
        invalidateCache()
        return updated
    }

    public func deleteCustom(key: String, purge: Bool = false) async throws {
        let req = APIRequest<EmptyResponse>(
            method: .delete,
            path: "/api/mood/tags/custom/\(Self.pathComponent(key))",
            query: purge ? [("purge", "true")] : []
        )
        _ = try await api.send(req)
        invalidateCache()
    }

    public func setCatalogueHidden(key: String, hidden: Bool) async throws {
        let body = SetHiddenRequest(hidden: hidden)
        let req: APIRequest<EmptyResponse> = try .put(
            "/api/mood/tags/\(Self.pathComponent(key))/hidden",
            body: body
        )
        _ = try await api.send(req)
        invalidateCache()
    }

    @discardableResult
    public func createGroup(label: String, icon: String?) async throws -> MoodTagCategoryDTO {
        let body = CreateMoodTagGroupRequest(label: label, icon: icon)
        let req: APIRequest<MoodTagCategoryDTO> = try .post("/api/mood/tags/groups", body: body)
        let created = try await api.send(req)
        invalidateCache()
        return created
    }

    @discardableResult
    public func updateGroup(
        key: String,
        label: String?,
        icon: String?,
        isActive: Bool?
    ) async throws -> MoodTagCategoryDTO {
        let body = UpdateMoodTagGroupRequest(label: label, icon: icon, isActive: isActive)
        let req: APIRequest<MoodTagCategoryDTO> = try .patch(
            "/api/mood/tags/groups/\(Self.pathComponent(key))",
            body: body
        )
        let updated = try await api.send(req)
        invalidateCache()
        return updated
    }

    @discardableResult
    public func deleteGroup(key: String, purge: Bool = false) async throws -> DeleteMoodTagGroupResponse {
        let req = APIRequest<DeleteMoodTagGroupResponse>(
            method: .delete,
            path: "/api/mood/tags/groups/\(Self.pathComponent(key))",
            query: purge ? [("purge", "true")] : []
        )
        let deleted = try await api.send(req)
        invalidateCache()
        return deleted
    }

    public func layout() async throws -> MoodTagLayoutDTO {
        let req: APIRequest<MoodTagLayoutDTO> = .get("/api/mood/tags/layout")
        let dto = try await api.send(req)
        // CU-20 — refresh the token the next PUT will echo as `baseUpdatedAt`.
        layoutToken = dto.updatedAt
        return dto
    }

    @discardableResult
    public func updateGroupOrder(_ groupOrder: [String]) async throws -> MoodTagLayoutDTO {
        let current = try await layout()
        // CU-20 — on a conflict the group order is re-applied to the FRESHLY
        // re-read layout, so the retry keeps the other session's placement
        // edits instead of overwriting them with our stale copy.
        return try await putLayout(
            MoodTagLayoutDTO(groupOrder: groupOrder, placements: current.placements),
            reapply: { fresh in
                MoodTagLayoutDTO(groupOrder: groupOrder, placements: fresh.placements)
            }
        )
    }

    @discardableResult
    public func updatePlacements(_ placements: [String: [String]]) async throws -> MoodTagLayoutDTO {
        let current = try await layout()
        return try await putLayout(
            MoodTagLayoutDTO(groupOrder: current.groupOrder, placements: placements),
            reapply: { fresh in
                MoodTagLayoutDTO(groupOrder: fresh.groupOrder, placements: placements)
            }
        )
    }

    /// **CU-20 (#69):** guarded by `baseUpdatedAt`. A stale token yields
    /// `409 mood_tag_layout_conflict` with nothing written; the bounded retry
    /// re-GETs, re-applies the caller's change via `reapply`, and re-sends.
    /// `reapply` defaults to sending the same body verbatim (the full-replace
    /// case).
    @discardableResult
    public func putLayout(
        _ layout: MoodTagLayoutDTO,
        reapply: @escaping @Sendable (MoodTagLayoutDTO) -> MoodTagLayoutDTO = { $0 }
    ) async throws -> MoodTagLayoutDTO {
        var body = layout
        return try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.moodTagLayout,
            token: layoutToken
        ) { token in
            let req: APIRequest<MoodTagLayoutDTO> = try .put(
                "/api/mood/tags/layout",
                body: OptimisticWriteBody(payload: body, baseUpdatedAt: token)
            )
            let updated = try await api.send(req)
            layoutToken = updated.updatedAt
            invalidateCache()
            return updated
        } reread: {
            let fresh = try await self.layout()
            body = reapply(fresh)
            return fresh.updatedAt
        }
    }

    /// RFC 3986 path-segment encoding. Opaque server keys may contain `:` (a
    /// valid `pchar`, kept raw) but must never be able to introduce a slash,
    /// query, or fragment component — those are percent-encoded. The APIClient
    /// appends this via `percentEncodedPath`, so the encoding here is final and
    /// is not re-encoded.
    private static func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    // MARK: - Bundled offline fallback

    /// Hardcoded mirror of the server seed (`prisma/migrations/
    /// 0101_v185_mood_tag_taxonomy`). Rendered before the first server hit
    /// lands (cold/offline launch) so the picker is never empty. Goes stale if
    /// the server re-seeds, but a later online tick overrides it.
    public static let bundledFallback: MoodTagCatalog = .init(categories: [
        .init(key: "feelings", labelKey: "mood.tagCategory.feelings", icon: "Heart", tags: [
            .init(key: "happy", labelKey: "mood.tag.happy", icon: "Smile"),
            .init(key: "excited", labelKey: "mood.tag.excited", icon: "Zap"),
            .init(key: "grateful", labelKey: "mood.tag.grateful", icon: "HandHeart"),
            .init(key: "relaxed", labelKey: "mood.tag.relaxed", icon: "CloudSun"),
            .init(key: "content", labelKey: "mood.tag.content", icon: "ThumbsUp"),
            .init(key: "tired", labelKey: "mood.tag.tired", icon: "Moon"),
            .init(key: "unsure", labelKey: "mood.tag.unsure", icon: "HelpCircle"),
            .init(key: "bored", labelKey: "mood.tag.bored", icon: "Meh"),
            .init(key: "tense", labelKey: "mood.tag.tense", icon: "AlertTriangle"),
            .init(key: "angry", labelKey: "mood.tag.angry", icon: "Flame"),
            .init(key: "stressed", labelKey: "mood.tag.stressed", icon: "Brain"),
            .init(key: "sad", labelKey: "mood.tag.sad", icon: "Frown")
        ]),
        .init(key: "sleep", labelKey: "mood.tagCategory.sleep", icon: "BedDouble", tags: [
            .init(key: "slept_well", labelKey: "mood.tag.sleptWell", icon: "Moon"),
            .init(key: "slept_ok", labelKey: "mood.tag.sleptOk", icon: "CloudMoon"),
            .init(key: "slept_poorly", labelKey: "mood.tag.sleptPoorly", icon: "MoonStar"),
            .init(key: "early_night", labelKey: "mood.tag.earlyNight", icon: "Clock")
        ]),
        .init(key: "health", labelKey: "mood.tagCategory.health", icon: "HeartPulse", tags: [
            .init(key: "worked_out", labelKey: "mood.tag.workedOut", icon: "Dumbbell"),
            .init(key: "ate_well", labelKey: "mood.tag.ateWell", icon: "Apple"),
            .init(key: "hydrated", labelKey: "mood.tag.hydrated", icon: "GlassWater"),
            .init(key: "walked", labelKey: "mood.tag.walked", icon: "Footprints"),
            .init(key: "alcohol", labelKey: "mood.tag.alcohol", icon: "Wine")
        ]),
        .init(key: "social", labelKey: "mood.tagCategory.social", icon: "Users", tags: [
            .init(key: "family", labelKey: "mood.tag.family", icon: "House"),
            .init(key: "friends", labelKey: "mood.tag.friends", icon: "Users"),
            .init(key: "party", labelKey: "mood.tag.party", icon: "PartyPopper"),
            .init(key: "alone", labelKey: "mood.tag.alone", icon: "User")
        ]),
        .init(key: "work", labelKey: "mood.tagCategory.work", icon: "Briefcase", tags: [
            .init(key: "productive", labelKey: "mood.tag.productive", icon: "CheckCircle"),
            .init(key: "overtime", labelKey: "mood.tag.overtime", icon: "ClockAlert"),
            .init(key: "day_off", labelKey: "mood.tag.dayOff", icon: "Plane"),
            .init(key: "travel", labelKey: "mood.tag.travel", icon: "Plane"),
            .init(key: "sick_day", labelKey: "mood.tag.sickDay", icon: "Thermometer")
        ])
    ])
}

// MARK: - Management request and response DTOs

public struct CreateCustomTagRequest: Encodable, Sendable {
    public let label: String
    public let icon: String?
    public let categoryKey: String?

    public init(label: String, icon: String?, categoryKey: String?) {
        self.label = label
        self.icon = icon
        self.categoryKey = categoryKey
    }
}

public struct UpdateCustomTagRequest: Encodable, Sendable {
    public let label: String?
    public let icon: String?
    public let isActive: Bool?
    public let categoryKey: String?

    public init(label: String?, icon: String?, isActive: Bool?, categoryKey: String? = nil) {
        self.label = label
        self.icon = icon
        self.isActive = isActive
        self.categoryKey = categoryKey
    }
}

public struct CreateMoodTagGroupRequest: Encodable, Sendable {
    public let label: String
    public let icon: String?
}

public struct UpdateMoodTagGroupRequest: Encodable, Sendable {
    public let label: String?
    public let icon: String?
    public let isActive: Bool?
}

public struct DeleteMoodTagGroupResponse: Codable, Sendable, Equatable {
    public let key: String
    public let purged: Bool
    public let rehomedCount: Int
}

public struct MoodTagLayoutDTO: Codable, Sendable, Equatable {
    public let groupOrder: [String]
    public let placements: [String: [String]]
    /// **CU-20 (#69) — optimistic-concurrency token.** Echoed as
    /// `baseUpdatedAt` on the next PUT; a stale one yields
    /// `409 mood_tag_layout_conflict` and nothing is written. Guards the shared
    /// `User.updatedAt` (`api/mood/tags/layout/route.ts:112`).
    ///
    /// **Conditionally present on the GET** — the server spreads the key in
    /// only when the user row resolved (`route.ts:57-61`:
    /// `...(updatedAt !== undefined ? { updatedAt } : {})`), so a fresh user
    /// sees the key omitted entirely rather than null. `nil` here therefore
    /// means "no token" and the next write goes out unconditional.
    ///
    /// **Decode-only — deliberately NOT re-encoded** (see ``encode(to:)``).
    public let updatedAt: String?

    /// Explicit because BOTH coders are hand-written (CU-20 added the
    /// read-only `updatedAt`), so nothing is synthesized any more.
    enum CodingKeys: String, CodingKey {
        case groupOrder
        case placements
        case updatedAt
    }

    public init(groupOrder: [String], placements: [String: [String]], updatedAt: String? = nil) {
        self.groupOrder = groupOrder
        self.placements = placements
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupOrder = try container.decodeIfPresent([String].self, forKey: .groupOrder) ?? []
        placements = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .placements
        ) ?? [:]
        // CU-20 — conditionally present; absent for a never-resolved user row.
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Explicit (previously synthesized) so the CU-20 `updatedAt` token stays
    /// **read-only** — it rides the write as `baseUpdatedAt` via
    /// ``OptimisticWriteBody``, never under its own key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groupOrder, forKey: .groupOrder)
        try container.encode(placements, forKey: .placements)
    }
}

public struct SetHiddenRequest: Encodable, Sendable {
    public let hidden: Bool

    public init(hidden: Bool) {
        self.hidden = hidden
    }
}
