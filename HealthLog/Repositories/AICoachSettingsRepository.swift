import Foundation

/// **Build 6 / Item 6.6** — thin server seam for the two Coach/AI privacy flags.
/// Wraps the real routes (verified against the server repo) so the wire shapes
/// are contract-testable against a stubbed `URLSession` rather than hand-rolled
/// inline in the store.
///
/// - `documentsAutoAiRead` — `GET / PATCH /api/auth/me/documents-auto-ai-read`.
/// - `insightsPrivacyMode` — `GET / PUT  /api/insights/settings`
///   (read + write field name on the wire is `privacyMode`).
public actor AICoachSettingsRepository {
    private let api: APIClientProtocol

    /// **CU-20 (#69)** — last `updatedAt` seen from `/api/auth/me/coach-prefs`.
    /// `nil` when the user has never saved (the GET omits the key entirely —
    /// see ``token(in:)``), which makes the first save an unconditional write.
    private var coachPrefsToken: String?

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentCoachPrefsToken() -> String? {
        coachPrefsToken
    }

    // MARK: - documentsAutoAiRead

    public func fetchDocumentsAutoAiRead() async throws -> Bool {
        let req: APIRequest<DocumentsAutoAiReadDTO> = .get("/api/auth/me/documents-auto-ai-read")
        return try await api.send(req).documentsAutoAiRead
    }

    /// PATCH the flag. Returns the server-confirmed next state (the route always
    /// echoes the resolved value, so the caller can hard-set the optimistic UI).
    @discardableResult
    public func setDocumentsAutoAiRead(_ enabled: Bool) async throws -> Bool {
        let req: APIRequest<DocumentsAutoAiReadDTO> = try .patch(
            "/api/auth/me/documents-auto-ai-read",
            body: DocumentsAutoAiReadWrite(documentsAutoAiRead: enabled)
        )
        return try await api.send(req).documentsAutoAiRead
    }

    // MARK: - insightsPrivacyMode

    public func fetchInsightsPrivacyMode() async throws -> InsightsPrivacyMode {
        let req: APIRequest<InsightsPrivacySettingsDTO> = .get("/api/insights/settings")
        return try await api.send(req).privacyMode
    }

    /// PUT the mode. The route responds `{ updated: true }` (decoded as
    /// ``EmptyResponse``); on success the caller keeps its optimistic value.
    public func setInsightsPrivacyMode(_ mode: InsightsPrivacyMode) async throws {
        let req: APIRequest<EmptyResponse> = try .put(
            "/api/insights/settings",
            body: InsightsPrivacyModeWrite(privacyMode: mode)
        )
        _ = try await api.send(req)
    }

    // MARK: - disableCoach (Build 9 / 9.2)

    /// `GET /api/auth/me/disable-coach` → the server-wide "coach unavailable"
    /// flag (`?? false`). 1:1 the ``fetchDocumentsAutoAiRead`` posture.
    public func fetchDisableCoach() async throws -> Bool {
        let req: APIRequest<DisableCoachDTO> = .get("/api/auth/me/disable-coach")
        return try await api.send(req).disableCoach
    }

    /// `PATCH /api/auth/me/disable-coach` with `{ disableCoach }`; the route
    /// echoes the resolved state, which the caller hard-sets. Only ever called
    /// from an explicit user toggle — NEVER from hydration (plan §guard 1: the
    /// iOS-default-OFF must never be PATCHed as `disableCoach=true`).
    @discardableResult
    public func setDisableCoach(_ disabled: Bool) async throws -> Bool {
        let req: APIRequest<DisableCoachDTO> = try .patch(
            "/api/auth/me/disable-coach",
            body: DisableCoachWrite(disableCoach: disabled)
        )
        return try await api.send(req).disableCoach
    }

    // MARK: - coach-prefs (Build 9 / 9.2 — JSON-level read-modify-write)

    /// `GET /api/auth/me/coach-prefs` decoded as a **generic JSON dictionary**
    /// (`HLJSONValue`), NOT a typed DTO. The PUT is a FULL-REPLACE, so a typed
    /// DTO would silently drop unknown / future sibling fields AND collapse the
    /// key-absence of `dataClusters` / `reminderSuggestions` (an absent key is a
    /// semantic sentinel — a legacy blob — not `[]`/`null`). The dict round-trip
    /// preserves both, structurally.
    public func fetchCoachPrefsRaw() async throws -> [String: HLJSONValue] {
        let req: APIRequest<[String: HLJSONValue]> = .get("/api/auth/me/coach-prefs")
        let raw = try await api.send(req)
        coachPrefsToken = Self.token(in: raw)
        return raw
    }

    /// **CU-20 (#69) — special case 7a.** A user who has never saved coach
    /// prefs gets the pure defaults with the `updatedAt` key **omitted
    /// entirely**, not null (`api/auth/me/coach-prefs/route.ts:43-51`, gated on
    /// `coachPrefsJson == null` — the `User` row itself always exists). So an
    /// absent key here legitimately means "no token", and the first save must
    /// leave `baseUpdatedAt` out of the body altogether.
    private static func token(in raw: [String: HLJSONValue]) -> String? {
        if case let .string(value)? = raw["updatedAt"] { return value }
        return nil
    }

    /// `PUT /api/auth/me/coach-prefs` — re-serialises the whole object unchanged
    /// (full-replace), guarded by the CU-20 `baseUpdatedAt` token.
    ///
    /// **The token matters most here**, because this is a genuine
    /// read-modify-write over a blob the server full-replaces: without it, two
    /// sessions editing different coach settings silently overwrite each other.
    /// On a 409 the re-read re-fetches the prefs, the caller's mutation is
    /// re-applied to the *fresh* object via `reapply`, and the write goes out
    /// again — bounded, then honest failure.
    public func putCoachPrefs(_ raw: [String: HLJSONValue]) async throws {
        try await putCoachPrefs(raw) { $0 }
    }

    /// Guarded full-replace PUT. `reapply` re-derives the body from a freshly
    /// re-read prefs object after a conflict, so the retry carries the user's
    /// change applied on top of the other session's write rather than
    /// resurrecting the stale blob.
    private func putCoachPrefs(
        _ raw: [String: HLJSONValue],
        reapply: @escaping @Sendable ([String: HLJSONValue]) -> [String: HLJSONValue]
    ) async throws {
        var body = raw
        try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.coachPrefs,
            token: coachPrefsToken
        ) { token in
            // The stored `updatedAt` must never travel back inside the
            // full-replace payload — it is a server-owned column, and the
            // concurrency token belongs in `baseUpdatedAt`.
            var payload = body
            payload["updatedAt"] = nil
            let req: APIRequest<[String: HLJSONValue]> = try .put(
                "/api/auth/me/coach-prefs",
                body: OptimisticWriteBody(payload: payload, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            coachPrefsToken = Self.token(in: echoed)
        } reread: {
            let fresh = try await fetchCoachPrefsRaw()
            body = reapply(fresh)
            return coachPrefsToken
        }
    }

    /// **9.2 reminder-suggestions toggle — read-modify-write.** GET the whole
    /// coach-prefs object, change ONLY `reminderSuggestions.enabled`, PUT it back
    /// whole. When the `reminderSuggestions` key is ABSENT (the legacy-blob
    /// sentinel) it is materialised with the server default shape
    /// (`{enabled, stopped:false, dismissedCadences:[], lastSuggestedAt:null}`)
    /// before setting `enabled` — that is the one field the toggle owns. Every
    /// sibling field (tone / verbosity / excludeMetrics / dataClusters / …) AND
    /// the key-absence of the OTHER sentinels is preserved verbatim. Returns the
    /// object that was PUT so the caller can hard-set its mirror.
    @discardableResult
    public func setReminderSuggestionsEnabled(_ enabled: Bool) async throws -> [String: HLJSONValue] {
        let raw = try await fetchCoachPrefsRaw()
        let applied = Self.applyingReminderSuggestionsEnabled(enabled, to: raw)
        // CU-20 — on a 409 the mutation is re-applied to the FRESHLY re-read
        // object, so the retry preserves the other session's sibling edits
        // instead of resurrecting our stale copy of the whole blob.
        try await putCoachPrefs(applied) { fresh in
            Self.applyingReminderSuggestionsEnabled(enabled, to: fresh)
        }
        return applied
    }

    /// Pure mutation: set ONLY `reminderSuggestions.enabled`, preserving every
    /// sibling field and the key-absence of the other sentinels. Extracted so
    /// the CU-20 conflict retry can re-apply it to a re-read object.
    private static func applyingReminderSuggestionsEnabled(
        _ enabled: Bool,
        to raw: [String: HLJSONValue]
    ) -> [String: HLJSONValue] {
        var raw = raw
        var reminder: [String: HLJSONValue] = if case let .object(existing)? = raw["reminderSuggestions"] {
            existing
        } else {
            // Absent key (legacy blob) → materialise the server-default shape.
            [
                "enabled": .bool(true),
                "stopped": .bool(false),
                "dismissedCadences": .array([]),
                "lastSuggestedAt": .null
            ]
        }
        reminder["enabled"] = .bool(enabled)
        raw["reminderSuggestions"] = .object(reminder)
        return raw
    }
}
