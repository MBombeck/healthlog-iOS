import Foundation

/// Actor repository for the nutrient READ + water-quick-add surface (server
/// v1.28 `GET /api/nutrients`, v1.29 `GET /api/nutrients/daily` +
/// `POST /api/nutrients/water`, GH iOS #48). The daily-totals UPLOAD path is a
/// separate actor (``NutrientDailySyncCoordinator``); this is the missing
/// read/display half.
///
/// **Reads are network-direct (no SWR cache).** Same posture as
/// ``IllnessRepository`` / ``LabsRepository``: the day-total window + the
/// per-nutrient series are small and freshness-sensitive, and the store holds
/// the in-memory snapshot. Both reads propagate a `403 module.disabled`
/// (typed by ``APIClient`` into ``HLError/moduleDisabled(_:)``) so the store can
/// flip to the enable-in-settings hint.
///
/// **Water quick-add is outbox-backed.** On a retriable network failure the
/// write persists to the encrypted ``OutboxQueue`` under its idempotency key and
/// the typed error re-throws, so the store keeps its optimistic total + surfaces
/// the offline banner. ``OutboxReplayService/dispatchNutrients(_:)`` drains it at
/// reachability, re-issuing the identical `POST` under the persisted key — the
/// server's `withIdempotency` makes a replay-after-original-landed a no-op, so a
/// quick-add tap can never double-increment the day total.
///
/// **Module gate (default OFF).** `/api/nutrients*` is behind the opt-in
/// `nutrients` module; a disabled account 403s `module.disabled`. The read path
/// surfaces that; the water write does NOT enqueue a `module.disabled` reject
/// (it is not `shouldPersistToOutbox`), so a quick-add while the module is off
/// fails fast instead of parking a doomed op.
public actor NutrientReadRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
    }

    /// True when an `HLError` is the `nutrients` module-disabled gate — the
    /// store maps this to the re-enable / disabled surface (no retry, no outbox).
    /// Tolerates both the typed `.moduleDisabled("nutrients")` (the shape
    /// ``APIClient`` produces for `errorCode == "module.disabled"` + `meta.module
    /// == "nutrients"`) and a bare `403`, whose only documented cause on these
    /// routes is the gate.
    public nonisolated static func isNutrientsDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error {
            return module == "nutrients"
        }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && (code == nil || code == "module.disabled")
        }
        return false
    }

    // MARK: - Reads

    /// `GET /api/nutrients?days=N` — the per-nutrient window summary (latest day
    /// total + days-with-data), catalog order. Default window 14 days (server
    /// default).
    public func overview(days: Int = 14) async throws -> NutrientOverviewDTO {
        let req: APIRequest<NutrientOverviewDTO> = .get(
            "/api/nutrients",
            query: [("days", String(days))]
        )
        return try await api.send(req)
    }

    /// `GET /api/nutrients/daily?nutrient=<code>&days=N` — one nutrient's dense
    /// day-bucketed series + its server-resolved EFSA reference. Default 30 days
    /// (server default; server cap is 90).
    public func dailySeries(nutrient: NutrientCode, days: Int = 30) async throws -> NutrientDailySeriesDTO {
        let req: APIRequest<NutrientDailySeriesDTO> = .get(
            "/api/nutrients/daily",
            query: [("nutrient", nutrient.rawValue), ("days", String(days))]
        )
        return try await api.send(req)
    }

    // MARK: - Water quick-add (outbox-backed)

    /// `POST /api/nutrients/water` — manual water quick-add against the MANUAL
    /// source row. `add` increments today's total, `set` overwrites it. Outbox-
    /// backed under the returned/persisted idempotency key.
    ///
    /// Returns the server's post-write MANUAL row on success. On a retriable
    /// failure the write is queued and the typed `HLError` re-throws (the store
    /// keeps its optimistic total). A `module.disabled` / other non-retriable
    /// reject re-throws WITHOUT queueing.
    @discardableResult
    public func quickAddWater(
        amountMl: Double,
        mode: NutrientWaterWriteMode,
        day: String? = nil
    ) async throws -> NutrientWaterWriteResponseDTO {
        let body = NutrientWaterWriteRequestDTO(amountMl: amountMl, mode: mode, day: day)
        let key = IdempotencyKey()
        do {
            return try await send(body, idempotencyKey: key)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(.logNutrientWater, payload: OutboxQueue.Payloads.LogNutrientWater(body: body), key: key)
            throw err
        }
    }

    /// Replay path for a queued water quick-add — re-issues the identical `POST`
    /// under the PERSISTED idempotency key (server `withIdempotency` dedups a
    /// replay that already landed). Driven by
    /// ``OutboxReplayService/dispatchNutrients(_:)``.
    @discardableResult
    public func replayWaterQuickAdd(
        _ body: NutrientWaterWriteRequestDTO,
        idempotencyKey: String
    ) async throws -> NutrientWaterWriteResponseDTO {
        try await send(body, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    // MARK: - Wire

    private func send(
        _ body: NutrientWaterWriteRequestDTO,
        idempotencyKey: IdempotencyKey
    ) async throws -> NutrientWaterWriteResponseDTO {
        let req: APIRequest<NutrientWaterWriteResponseDTO> = try .post(
            "/api/nutrients/water",
            body: body,
            encoder: encoder,
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req)
    }

    private func enqueue(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey
    ) async {
        do {
            let data = try encoder.encode(payload)
            try await outbox.enqueue(.init(kind: kind, payload: data, idempotencyKey: key.raw))
        } catch {
            HLLog.outbox.error(
                "Nutrient-water outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))"
            )
        }
    }
}
