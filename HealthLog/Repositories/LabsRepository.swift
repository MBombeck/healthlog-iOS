import Foundation

/// Actor repository for the v1.18.1 labs + biomarker-catalog surface
/// (`/api/labs`, `/api/biomarkers`, `/api/labs/restore`). Clones the
/// ``CycleRepository`` posture: optimistic writes through `APIClient`, and a
/// clean `module.disabled` (403) discriminator so a non-enabled account renders
/// the disabled surface instead of a hard error.
///
/// **Reads are SWR cache-first when a coordinator is supplied.** The
/// unfiltered labs list (`.labsResults`) and the biomarker catalog
/// (`.biomarkers`) route through `swr.fetchCachingFirst`, so the Labs screen is
/// READABLE on a cold offline launch instead of rendering the empty "add your
/// first…" state (they were previously network-only). Filtered / paged / detail
/// reads stay network-direct (no per-filter cache-key explosion). Every
/// successful write invalidates the relevant list key so a mutation is never
/// masked by a fresh-enough cached row. Logout purges every row via
/// `SWRCoordinator.invalidateAll()` (no per-key logout list to maintain).
///
/// **Outbox durability (v1.18.6 PHI).** Every write is now outbox-backed: on a
/// retriable network failure (`HLError.shouldPersistToOutbox`) the write is
/// persisted to the encrypted `OutboxQueue` under its idempotency key and the
/// typed `HLError` is re-thrown (the store keeps its optimistic state + surfaces
/// the offline banner / undo window). `OutboxReplayService` drains the labs
/// kinds at reachability / app-foreground, re-issuing the identical request under
/// the persisted key (server dedups within 24h; soft-delete is tombstone-
/// idempotent; restore foreign-ids are no-ops). The `replay*` entry points below
/// are the drain seams. A `module.disabled` 403 is NEVER enqueued (no retry).
///
/// **Range contract.** When a row carries `biomarkerId` the server resolves
/// `analyte`/`unit`/`referenceLow`/`referenceHigh`; this layer never recomputes
/// the range. `rangeStatus` is the singular NEUTRAL verdict — passed through
/// untouched.
public actor LabsRepository {
    let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let swr: SWRCoordinator?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.swr = swr
    }

    /// Server `/api/labs/restore` cap (1..200 ids per pass).
    public static let restoreCap = 200

    /// True when an `HLError` is the server's `403 module.disabled` envelope for
    /// the `labs` module. Callers map this to the disabled surface (no retry, no
    /// outbox). `APIClient` throws `HLError.moduleDisabled(<wireKey>)` for the
    /// nested-`meta` 403 shape; we also tolerate the older flat
    /// `server(403, "module.disabled", …)` form defensively.
    public nonisolated static func isLabsDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error {
            return module == "labs"
        }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && code == "module.disabled"
        }
        return false
    }

    // MARK: - Reads (SWR cache-first for the unfiltered list; QOL-OFF-2)

    /// `GET /api/labs` with the optional analyte / panel / biomarker / date-range
    /// / pagination filters. Returns the `{ results, meta }` payload.
    ///
    /// The UNFILTERED default page (no analyte/panel/biomarker/
    /// date filter, `offset == 0`, `sortDir == "desc"` — the exact read the
    /// `LabsStore` list uses) routes through `swr.fetchCachingFirst(.labsResults)`
    /// so the Labs screen paints from disk on a cold offline launch. Any filtered
    /// / paged read stays network-direct (no per-filter cache-key explosion).
    public func labs(
        biomarkerId: String? = nil,
        analyte: String? = nil,
        panel: String? = nil,
        from: String? = nil,
        to: String? = nil,
        limit: Int = 100,
        offset: Int = 0,
        sortDir: String = "desc"
    ) async throws -> ListLabResultsResponse {
        let api = api
        var query: [(String, String)] = []
        if let biomarkerId { query.append(("biomarkerId", biomarkerId)) }
        if let analyte { query.append(("analyte", analyte)) }
        if let panel { query.append(("panel", panel)) }
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        query.append(("limit", String(limit)))
        query.append(("offset", String(offset)))
        query.append(("sortDir", sortDir))
        let frozenQuery = query
        @Sendable func networkFetch() async throws -> ListLabResultsResponse {
            let req: APIRequest<ListLabResultsResponse> = .get("/api/labs", query: frozenQuery)
            return try await api.send(req)
        }
        let isUnfilteredPage = biomarkerId == nil && analyte == nil && panel == nil
            && from == nil && to == nil && offset == 0 && sortDir == "desc"
        if let swr, isUnfilteredPage {
            return try await swr.fetchCachingFirst(
                .labsResults,
                decoding: ListLabResultsResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/labs/overview` (server v1.42.4+): one entry per marker
    /// over the whole history, the source of the labs list.
    ///
    /// Returns `nil` when the server does not have the route (before v1.42.4
    /// the path falls through to `GET /api/labs/{id}` and answers 404, or a
    /// 400/405/422 from a stricter router); the caller then builds the list from
    /// `GET /api/labs` as before. Every other failure throws. Network-direct,
    /// not SWR-cached: offline, the list falls back to the cached rows.
    public func labsOverview() async throws -> LabOverviewResponse? {
        let req: APIRequest<LabOverviewResponse> = .get("/api/labs/overview")
        do {
            return try await api.send(req)
        } catch let HLError.server(status, _, _) where [400, 404, 405, 422].contains(status) {
            return nil
        }
    }

    /// `GET /api/settings/module-list-layout` — the person's own list
    /// presentation; only `lists.labs` is read. `nil` on a server without the
    /// route (the list then keeps its old behaviour). Network-direct: a
    /// failure leaves the previous layout in place.
    public func labsListLayout() async throws -> LabsListLayout? {
        let req: APIRequest<ModuleListLayoutResponse> = .get("/api/settings/module-list-layout")
        do {
            return try await api.send(req).labs
        } catch let HLError.server(status, _, _) where [400, 404, 405].contains(status) {
            return nil
        }
    }

    /// `GET /api/biomarkers` — the user's biomarker catalog (name-ordered).
    /// SWR cache-first (`.biomarkers`) for offline readability.
    public func biomarkers() async throws -> ListBiomarkersResponse {
        let api = api
        @Sendable func networkFetch() async throws -> ListBiomarkersResponse {
            let req: APIRequest<ListBiomarkersResponse> = .get("/api/biomarkers")
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .biomarkers,
                decoding: ListBiomarkersResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/labs/{id}` — single result incl. the decrypted note.
    public func labDetail(id: String) async throws -> LabResultDetailDTO {
        let req: APIRequest<LabResultDetailDTO> = .get("/api/labs/\(id)")
        return try await api.send(req)
    }

    /// `GET /api/biomarkers/{id}` — single marker incl. the decrypted context.
    public func biomarker(id: String) async throws -> BiomarkerDTO {
        let req: APIRequest<BiomarkerDTO> = .get("/api/biomarkers/\(id)")
        return try await api.send(req)
    }

    // MARK: - Lab-result writes (optimistic; idempotency-keyed)

    /// `POST /api/labs`. Returns the created (server-resolved) row. On a
    /// retriable failure the create is enqueued (durable replay) + re-thrown.
    ///
    /// `idempotencyKey` is optional: a caller that must stay idempotent across
    /// retries of the SAME logical row (the lab-scan batch save — BH M2) passes
    /// one STABLE key derived once per row, so re-tapping Save after a partial
    /// failure re-POSTs an already-saved row under the original key and the
    /// server dedupes it at the key level (not just content). Omitting the
    /// argument mints a fresh key as before.
    @discardableResult
    public func createLab(
        _ body: LabResultCreate,
        idempotencyKey: IdempotencyKey? = nil,
        clientEntityId: String? = nil
    ) async throws -> LabResultDTO {
        let key = idempotencyKey ?? IdempotencyKey()
        return try await writeAhead(
            .createLab, payload: OutboxQueue.Payloads.CreateLab(body: body),
            key: key, clientEntityId: clientEntityId
        ) { [self] in
            let req: APIRequest<LabResultDTO> = try .post("/api/labs", body: body, idempotencyKey: key)
            let created = try await api.send(req)
            await invalidate([.labsResults])
            return created
        }
    }

    /// Replay drain returning the server-assigned lab id so a
    /// queued update/delete referencing the optimistic id can be remapped.
    @discardableResult
    public func replayCreateLabReturningServerId(_ body: LabResultCreate, idempotencyKey: String) async throws -> String {
        let req: APIRequest<LabResultDTO> = try .post(
            "/api/labs", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(req).id
    }

    /// `PUT /api/labs/{id}` partial edit. Returns the updated row.
    @discardableResult
    public func updateLab(id: String, _ patch: LabResultPatch) async throws -> LabResultDTO {
        let key = IdempotencyKey()
        return try await writeAhead(
            .updateLab, payload: OutboxQueue.Payloads.UpdateLab(id: id, patch: patch),
            key: key, clientEntityId: id
        ) { [self] in
            let req: APIRequest<LabResultDTO> = try .put("/api/labs/\(id)", body: patch, idempotencyKey: key)
            let updated = try await api.send(req)
            await invalidate([.labsResults])
            return updated
        }
    }

    /// Replay drain for `updateLab`.
    public func replayUpdateLab(id: String, _ patch: LabResultPatch, idempotencyKey: String) async throws {
        let req: APIRequest<LabResultDTO> = try .put(
            "/api/labs/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/labs/{id}` (soft, idempotent).
    public func deleteLab(id: String) async throws {
        let key = IdempotencyKey()
        try await writeAhead(
            .deleteLab, payload: OutboxQueue.Payloads.DeleteLab(id: id),
            key: key, clientEntityId: id
        ) { [self] in
            let req: APIRequest<DeletedFlagResponse> = .delete("/api/labs/\(id)", idempotencyKey: key)
            _ = try await api.send(req)
            await invalidate([.labsResults])
        }
    }

    /// Replay drain for `deleteLab`.
    public func replayDeleteLab(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeletedFlagResponse> = .delete(
            "/api/labs/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `POST /api/labs/restore` — un-tombstone 1..`restoreCap` ids (delete-Undo).
    /// Returns the count the server restored. Foreign/live ids are silent
    /// no-ops server-side.
    @discardableResult
    public func restoreLabs(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        precondition(ids.count <= Self.restoreCap, "labs restore capped at \(Self.restoreCap)")
        let key = IdempotencyKey()
        return try await writeAhead(.restoreLabs, payload: OutboxQueue.Payloads.RestoreLabs(ids: ids), key: key) { [self] in
            let req: APIRequest<RestoreLabResultsResponse> = try .post(
                "/api/labs/restore", body: RestoreLabResultsRequest(ids: ids), idempotencyKey: key
            )
            let restored = try await api.send(req).restored
            await invalidate([.labsResults])
            return restored
        }
    }

    /// Replay drain for `restoreLabs`.
    public func replayRestoreLabs(ids: [String], idempotencyKey: String) async throws {
        guard !ids.isEmpty else { return }
        let req: APIRequest<RestoreLabResultsResponse> = try .post(
            "/api/labs/restore", body: RestoreLabResultsRequest(ids: ids), idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Biomarker writes (optimistic; idempotency-keyed)

    /// `POST /api/biomarkers`. A duplicate name surfaces as `409` —
    /// ``isDuplicateName(_:)`` discriminates it for an inline editor message.
    @discardableResult
    public func createBiomarker(_ body: BiomarkerCreate) async throws -> BiomarkerDTO {
        let key = IdempotencyKey()
        return try await writeAhead(.createBiomarker, payload: OutboxQueue.Payloads.CreateBiomarker(body: body), key: key) { [self] in
            let req: APIRequest<BiomarkerDTO> = try .post("/api/biomarkers", body: body, idempotencyKey: key)
            let created = try await api.send(req)
            await invalidate([.biomarkers])
            return created
        }
    }

    /// Replay drain for `createBiomarker`.
    public func replayCreateBiomarker(_ body: BiomarkerCreate, idempotencyKey: String) async throws {
        let req: APIRequest<BiomarkerDTO> = try .post(
            "/api/biomarkers", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `PUT /api/biomarkers/{id}` partial edit.
    @discardableResult
    public func updateBiomarker(id: String, _ patch: BiomarkerPatch) async throws -> BiomarkerDTO {
        let key = IdempotencyKey()
        return try await writeAhead(
            .updateBiomarker,
            payload: OutboxQueue.Payloads.UpdateBiomarker(id: id, patch: patch),
            key: key
        ) { [self] in
            let req: APIRequest<BiomarkerDTO> = try .put("/api/biomarkers/\(id)", body: patch, idempotencyKey: key)
            let updated = try await api.send(req)
            // The server resolves each linked row's analyte/unit/range from the
            // catalog, so an edit flows to the lab rows too — drop both keys.
            await invalidate([.biomarkers, .labsResults])
            return updated
        }
    }

    /// Replay drain for `updateBiomarker`.
    public func replayUpdateBiomarker(id: String, _ patch: BiomarkerPatch, idempotencyKey: String) async throws {
        let req: APIRequest<BiomarkerDTO> = try .put(
            "/api/biomarkers/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/biomarkers/{id}` (hard-delete the catalog definition). The
    /// server's `onDelete: SetNull` FK unlinks every reading (they keep their
    /// legacy `analyte`/`unit`), so the lab history survives — the UI copy must
    /// say so.
    public func deleteBiomarker(id: String) async throws {
        let key = IdempotencyKey()
        try await writeAhead(.deleteBiomarker, payload: OutboxQueue.Payloads.DeleteBiomarker(id: id), key: key) { [self] in
            let req: APIRequest<DeletedFlagResponse> = .delete("/api/biomarkers/\(id)", idempotencyKey: key)
            _ = try await api.send(req)
            // `onDelete: SetNull` unlinks every reading (rows keep legacy
            // analyte/unit), so the lab list repaints too — drop both keys.
            await invalidate([.biomarkers, .labsResults])
        }
    }

    /// Replay drain for `deleteBiomarker`.
    public func replayDeleteBiomarker(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeletedFlagResponse> = .delete(
            "/api/biomarkers/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// True when an `HLError` is the biomarker-catalog `409` (per-user
    /// `(userId, name)` uniqueness conflict). Maps to an inline editor message.
    public nonisolated static func isDuplicateName(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 409
        }
        return false
    }

    // MARK: - Cache invalidation

    /// Drop the given cached SWR snapshots after a successful write so a mutation
    /// is never masked by a fresh-enough cached row (the store's post-write
    /// `load()` then refetches). No-op when no coordinator is wired.
    func invalidate(_ keys: [CacheKey]) async {
        await swr?.invalidate(keys)
    }

    // MARK: - Outbox write-ahead helper

    /// Stores the write before it is sent and removes it once it has landed
    /// (``OutboxQueue/writeAhead(_:now:send:)``). A send that fails with no
    /// stored copy behind it surfaces as `HLError.notPersisted`, so the caller
    /// rolls back instead of reporting the write as queued.
    private func writeAhead<Result: Sendable>(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey,
        clientEntityId: String? = nil,
        send: @Sendable () async throws -> Result
    ) async throws -> Result {
        let data = try encoder.encode(payload)
        let op = OutboxQueue.Operation(
            kind: kind, payload: data, idempotencyKey: key.raw, clientEntityId: clientEntityId
        )
        return try await outbox.writeAhead(op, send: send)
    }
}
