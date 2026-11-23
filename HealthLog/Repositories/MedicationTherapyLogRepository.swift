import Foundation

/// Server round-trip for the GLP-1 side-effect logbook and
/// pen/vial inventory. Mirrors the medication-intake Outbox pattern verbatim:
/// the online write is attempted first; on a *retriable* `HLError` the write is
/// enqueued on the `OutboxQueue` under its own kind with a persisted
/// idempotency-key, and `OutboxReplayService` re-issues it on reachability +
/// foreground. On 2xx the Outbox entry clears.
///
/// This repo is a pure server seam.
///
/// Contracts consumed:
///   side-effects: `…/medications/[id]/side-effects[/(logId)]/route.ts`
///   inventory:    `…/medications/[id]/inventory[/(itemId)]/route.ts`
public actor MedicationTherapyLogRepository {
    let api: APIClientProtocol
    let outbox: OutboxQueue
    let encoder: JSONEncoder

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
    }

    // MARK: - Side-effects

    /// GET the side-effect logbook for one medication (SWR read; newest first).
    public func sideEffects(
        medicationID: String,
        sinceDays: Int? = nil,
        limit: Int = 50
    ) async throws -> [MedicationSideEffectDTO] {
        var query: [(String, String)] = [("limit", String(limit))]
        if let sinceDays {
            let from = Calendar.current.date(byAdding: .day, value: -sinceDays, to: .now) ?? .now
            query.append(("from", ISO8601DateFormatter().string(from: from)))
        }
        // #147 (v1.43.7) — a cut answer is asked once more at the route's
        // ceiling (200); the route takes no `offset`.
        let list: MedicationSideEffectListDTO = try await CappedListReader.readUpToCeiling(
            api: api, path: "/api/medications/\(medicationID)/side-effects", query: query,
            limit: limit, ceiling: CappedListReader.sideEffectsCeiling
        )
        return list.items
    }

    /// POST a new side-effect log. Optimistic-write + Outbox-on-retriable.
    @discardableResult
    public func createSideEffect(
        medicationID: String,
        body: MedicationSideEffectCreate
    ) async throws -> MedicationSideEffectDTO {
        let key = IdempotencyKey()
        return try await writeAhead(
            kind: .createMedicationSideEffect,
            payload: OutboxQueue.Payloads.CreateMedicationSideEffect(medicationId: medicationID, body: body),
            key: key
        ) { [self] in
            try await postSideEffect(medicationID: medicationID, body: body, idempotencyKey: key)
        }
    }

    /// Replay path for `createMedicationSideEffect` — reuses the persisted key.
    @discardableResult
    public func replayCreateSideEffect(
        medicationID: String,
        body: MedicationSideEffectCreate,
        idempotencyKey: String
    ) async throws -> MedicationSideEffectDTO {
        try await postSideEffect(medicationID: medicationID, body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// DELETE a side-effect log row. Optimistic-write + Outbox-on-retriable.
    public func deleteSideEffect(medicationID: String, logID: String) async throws {
        let key = IdempotencyKey()
        try await writeAhead(
            kind: .deleteMedicationSideEffect,
            payload: OutboxQueue.Payloads.DeleteMedicationSideEffect(medicationId: medicationID, logId: logID),
            key: key
        ) { [self] in
            try await sendDeleteSideEffect(medicationID: medicationID, logID: logID, idempotencyKey: key)
        }
    }

    public func replayDeleteSideEffect(medicationID: String, logID: String, idempotencyKey: String) async throws {
        try await sendDeleteSideEffect(medicationID: medicationID, logID: logID, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    private func postSideEffect(
        medicationID: String,
        body: MedicationSideEffectCreate,
        idempotencyKey: IdempotencyKey
    ) async throws -> MedicationSideEffectDTO {
        let req: APIRequest<MedicationSideEffectDTO> = try .post(
            "/api/medications/\(medicationID)/side-effects",
            body: body,
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req)
    }

    private func sendDeleteSideEffect(medicationID: String, logID: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<MedicationMutationAck> = .delete(
            "/api/medications/\(medicationID)/side-effects/\(logID)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }

    // MARK: - Inventory

    /// GET the inventory list for one medication (SWR read).
    public func inventory(medicationID: String) async throws -> [MedicationInventoryItemDTO] {
        try await inventoryList(medicationID: medicationID).items
    }

    /// The same GET with the server's `summary` kept. One
    /// request; the list callers that only want items use ``inventory(medicationID:)``.
    public func inventoryList(medicationID: String) async throws -> MedicationInventoryListDTO {
        let req: APIRequest<MedicationInventoryListDTO> = .get(
            "/api/medications/\(medicationID)/inventory"
        )
        return try await api.send(req)
    }

    /// POST a new pen/vial. Optimistic-write + Outbox-on-retriable.
    @discardableResult
    public func createInventoryItem(
        medicationID: String,
        body: MedicationInventoryCreate
    ) async throws -> MedicationInventoryItemDTO {
        let key = IdempotencyKey()
        return try await writeAhead(
            kind: .createMedicationInventory,
            payload: OutboxQueue.Payloads.CreateMedicationInventory(medicationId: medicationID, body: body),
            key: key
        ) { [self] in
            try await postInventory(medicationID: medicationID, body: body, idempotencyKey: key)
        }
    }

    @discardableResult
    public func replayCreateInventoryItem(
        medicationID: String,
        body: MedicationInventoryCreate,
        idempotencyKey: String
    ) async throws -> MedicationInventoryItemDTO {
        try await postInventory(medicationID: medicationID, body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// PATCH a pen/vial (mark first-use / used-up / edit expiry / notes).
    @discardableResult
    public func updateInventoryItem(
        medicationID: String,
        itemID: String,
        patch: MedicationInventoryPatch
    ) async throws -> MedicationInventoryItemDTO {
        let key = IdempotencyKey()
        return try await writeAhead(
            kind: .updateMedicationInventory,
            payload: OutboxQueue.Payloads.UpdateMedicationInventory(medicationId: medicationID, itemId: itemID, patch: patch),
            key: key
        ) { [self] in
            try await patchInventory(medicationID: medicationID, itemID: itemID, patch: patch, idempotencyKey: key)
        }
    }

    @discardableResult
    public func replayUpdateInventoryItem(
        medicationID: String,
        itemID: String,
        patch: MedicationInventoryPatch,
        idempotencyKey: String
    ) async throws -> MedicationInventoryItemDTO {
        try await patchInventory(
            medicationID: medicationID,
            itemID: itemID,
            patch: patch,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
    }

    /// DELETE a pen/vial. Optimistic-write + Outbox-on-retriable.
    public func deleteInventoryItem(medicationID: String, itemID: String) async throws {
        let key = IdempotencyKey()
        try await writeAhead(
            kind: .deleteMedicationInventory,
            payload: OutboxQueue.Payloads.DeleteMedicationInventory(medicationId: medicationID, itemId: itemID),
            key: key
        ) { [self] in
            try await sendDeleteInventory(medicationID: medicationID, itemID: itemID, idempotencyKey: key)
        }
    }

    public func replayDeleteInventoryItem(medicationID: String, itemID: String, idempotencyKey: String) async throws {
        try await sendDeleteInventory(medicationID: medicationID, itemID: itemID, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    private func postInventory(
        medicationID: String,
        body: MedicationInventoryCreate,
        idempotencyKey: IdempotencyKey
    ) async throws -> MedicationInventoryItemDTO {
        let req: APIRequest<MedicationInventoryItemDTO> = try .post(
            "/api/medications/\(medicationID)/inventory",
            body: body,
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req)
    }

    private func patchInventory(
        medicationID: String,
        itemID: String,
        patch: MedicationInventoryPatch,
        idempotencyKey: IdempotencyKey
    ) async throws -> MedicationInventoryItemDTO {
        let req: APIRequest<MedicationInventoryItemDTO> = try .patch(
            "/api/medications/\(medicationID)/inventory/\(itemID)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req)
    }

    private func sendDeleteInventory(medicationID: String, itemID: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<MedicationMutationAck> = .delete(
            "/api/medications/\(medicationID)/inventory/\(itemID)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }

    // MARK: - Outbox helper

    /// Stores the write before it is sent and removes it once it has landed
    /// (``OutboxQueue/writeAhead(_:now:send:)``). A send that fails with no
    /// stored copy behind it surfaces as `HLError.notPersisted`, so the caller
    /// rolls back instead of reporting the write as queued.
    private func writeAhead<Result: Sendable>(
        kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey,
        send: @Sendable () async throws -> Result
    ) async throws -> Result {
        let data = try encoder.encode(payload)
        let op = OutboxQueue.Operation(kind: kind, payload: data, idempotencyKey: key.raw)
        return try await outbox.writeAhead(op, send: send)
    }
}
