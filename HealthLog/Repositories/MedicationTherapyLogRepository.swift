import Foundation

/// SP3 + SP4 (v0.12) — server round-trip for the GLP-1 side-effect logbook and
/// pen/vial inventory. Mirrors the medication-intake Outbox pattern verbatim:
/// the online write is attempted first; on a *retriable* `HLError` the write is
/// enqueued on the `OutboxQueue` under its own kind with a persisted
/// idempotency-key, and `OutboxReplayService` re-issues it on reachability +
/// foreground. On 2xx the Outbox entry clears.
///
/// **Standalone:** when no server pairing exists, callers route through the
/// local-only GLP-1 store (`GLP1LocalRepository`) and never reach this actor —
/// so there is simply nothing to replay (no server write fires). This repo is a
/// pure server seam.
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

    // MARK: - Side-effects (SP3)

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
        let req: APIRequest<MedicationSideEffectListDTO> = .get(
            "/api/medications/\(medicationID)/side-effects",
            query: query
        )
        return try await api.send(req).items
    }

    /// POST a new side-effect log. Optimistic-write + Outbox-on-retriable.
    @discardableResult
    public func createSideEffect(
        medicationID: String,
        body: MedicationSideEffectCreate
    ) async throws -> MedicationSideEffectDTO {
        let key = IdempotencyKey()
        do {
            return try await postSideEffect(medicationID: medicationID, body: body, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                kind: .createMedicationSideEffect,
                payload: OutboxQueue.Payloads.CreateMedicationSideEffect(medicationId: medicationID, body: body),
                key: key
            )
            throw err
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
        do {
            try await sendDeleteSideEffect(medicationID: medicationID, logID: logID, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                kind: .deleteMedicationSideEffect,
                payload: OutboxQueue.Payloads.DeleteMedicationSideEffect(medicationId: medicationID, logId: logID),
                key: key
            )
            throw err
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

    // MARK: - Inventory (SP4)

    /// GET the inventory list for one medication (SWR read).
    public func inventory(medicationID: String) async throws -> [MedicationInventoryItemDTO] {
        let req: APIRequest<MedicationInventoryListDTO> = .get(
            "/api/medications/\(medicationID)/inventory"
        )
        return try await api.send(req).items
    }

    /// POST a new pen/vial. Optimistic-write + Outbox-on-retriable.
    @discardableResult
    public func createInventoryItem(
        medicationID: String,
        body: MedicationInventoryCreate
    ) async throws -> MedicationInventoryItemDTO {
        let key = IdempotencyKey()
        do {
            return try await postInventory(medicationID: medicationID, body: body, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                kind: .createMedicationInventory,
                payload: OutboxQueue.Payloads.CreateMedicationInventory(medicationId: medicationID, body: body),
                key: key
            )
            throw err
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
        do {
            return try await patchInventory(medicationID: medicationID, itemID: itemID, patch: patch, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                kind: .updateMedicationInventory,
                payload: OutboxQueue.Payloads.UpdateMedicationInventory(medicationId: medicationID, itemId: itemID, patch: patch),
                key: key
            )
            throw err
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
        do {
            try await sendDeleteInventory(medicationID: medicationID, itemID: itemID, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                kind: .deleteMedicationInventory,
                payload: OutboxQueue.Payloads.DeleteMedicationInventory(medicationId: medicationID, itemId: itemID),
                key: key
            )
            throw err
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

    private func enqueue(kind: OutboxQueue.Operation.Kind, payload: some Encodable, key: IdempotencyKey) async {
        do {
            let data = try encoder.encode(payload)
            try await outbox.enqueue(.init(kind: kind, payload: data, idempotencyKey: key.raw))
        } catch {
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
