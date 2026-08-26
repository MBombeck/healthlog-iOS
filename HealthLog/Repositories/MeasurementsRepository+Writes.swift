// Write paths (create / update / delete / replay) split out of MeasurementsRepository.swift (pure move, W-FILELEN).
import Foundation

public extension MeasurementsRepository {
    /// Optimistic create. BP wird zu zwei Wire-Records aufgeteilt — beide teilen
    /// `externalId` (Domain-Measurement-ID), damit Server sie als Paar erkennen kann.
    func create(_ measurement: Measurement) async throws -> Measurement {
        if isStandalone, let standalone {
            // Standalone: persist to the local mirror so the lists read it back
            // immediately. No network, no outbox. Returns the canonical row with
            // the mirror's externalId swapped onto the domain id.
            let systolic: Double?
            let diastolic: Double?
            switch measurement.value {
            case let .bloodPressure(sys, dia):
                systolic = sys
                diastolic = dia
            case .scalar:
                systolic = nil
                diastolic = nil
            }
            let snap = try await standalone.local.standaloneAddMeasurement(
                kind: measurement.kind.rawValue,
                value: measurement.value.primaryComponent,
                unit: measurement.kind.unit,
                systolic: systolic,
                diastolic: diastolic,
                recordedAt: measurement.recordedAt,
                note: measurement.note
            )
            return snap.toDomainMeasurement()
        }
        let idempotencyKey = IdempotencyKey()
        do {
            let saved = try await postMeasurement(measurement, idempotencyKey: idempotencyKey)
            await invalidateAfterWrite(kind: measurement.kind)
            return saved
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(measurement)
            do {
                try await outbox.enqueue(.init(
                    kind: .createMeasurement,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                // G-2 enqueue-failure honesty — the network failure AND the
                // durable enqueue both failed (worst when the outbox degraded
                // to the in-memory inert floor). Nothing is queued: surfacing
                // the original retriable error would make the store keep the
                // optimistic "saved/queued" state for a write that is now
                // permanently lost. Throw `.notPersisted` so the caller rolls
                // back / shows an honest "couldn't save". Secondary failure is
                // logged sanitized for triage.
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
                throw HLError.notPersisted(String(describing: err))
            }
            throw err
        }
    }

    func replay(_ measurement: Measurement, idempotencyKey: String) async throws -> Measurement {
        // Outbox-replay flushes a previously offline-created measurement.
        // Same cache-invalidation semantics as `create` — the server now has
        // a record the cached recent/series pages don't reflect.
        let saved = try await postMeasurement(measurement, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterWrite(kind: measurement.kind)
        return saved
    }

    /// Delete a single measurement on the server. Server route:
    /// `DELETE /api/measurements/[id]` returns 204 on success.
    ///
    /// On retriable network failure, enqueues `deleteMeasurement` on the
    /// outbox and re-throws so the calling UI can present an offline-banner.
    /// Replay reuses the same `idempotencyKey` so server-side dedup catches
    /// the inevitable replay-after-original-actually-succeeded race.
    ///
    /// **HK-propagation note (T-0 contract):** the iOS-server side is T-0's
    /// scope only. If the measurement carries an `HKMetadataKeyExternalUUID`,
    /// the calling UI is responsible for the HK-side `delete` *before*
    /// invoking this method (so HK-mirror stays in lockstep with server).
    func delete(id: String) async throws {
        if isStandalone, let standalone {
            // The list's row id is the mirror's externalId (see
            // `LocalMeasurementSnapshot.toDomainMeasurement`).
            try await standalone.local.standaloneDeleteMeasurement(externalId: id)
            return
        }
        let idempotencyKey = IdempotencyKey()
        do {
            try await deleteRequest(id: id, idempotencyKey: idempotencyKey)
            await invalidateAfterWriteAllKinds()
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.DeleteMeasurement(id: id))
            do {
                try await outbox.enqueue(.init(
                    kind: .deleteMeasurement,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                // G-2 — durable enqueue failed; the delete is neither on the
                // server nor queued. Signal honestly so the caller surfaces a
                // "couldn't save" rather than a false "queued" for a delete
                // that will silently reappear on next load.
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
                throw HLError.notPersisted(String(describing: err))
            }
            throw err
        }
    }

    /// Outbox-replay path for `deleteMeasurement`. Same semantics as `delete`
    /// but reuses the persisted idempotency-key.
    func replayDelete(id: String, idempotencyKey: String) async throws {
        try await deleteRequest(id: id, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterWriteAllKinds()
    }

    /// Patch an existing measurement (recordedAt + value + note).
    /// Server route: `PUT /api/measurements/[id]` returns the updated row.
    /// PUT (not PATCH): the item route exports GET/PUT/DELETE only — a PATCH
    /// returns 405 Method Not Allowed and the edit is silently lost. The
    /// server's PUT handler is itself partial (only writes the present
    /// `value`/`measuredAt`/`notes` fields), so the partial `MeasurementPatch`
    /// body is unchanged — only the verb differs. Mirrors `MoodRepository`.
    ///
    /// **BP-pair semantics (T-1):** Wenn `kind == .bloodPressure` und der
    /// Patch beide Werte (`value` = systolic, `diastolic` = diastolic) trägt
    /// und der Caller den diastolischen Peer kennt (`diastolicId != nil`),
    /// fanoutet diese Methode in ZWEI PUT-Calls (sys-row + dia-row) mit
    /// derselben `Idempotency-Key`. Server-Idempotency-Cache catched
    /// Retries. Returnt das aggregierte Domain-Measurement mit beiden
    /// Peers gemerged.
    ///
    /// On retriable network failure, enqueues `updateMeasurement` on the
    /// outbox (the payload carries the original `MetricKind` + optional
    /// diastolic-peer-id/value so the replay path can drop the right cache
    /// buckets without re-querying the server) and re-throws.
    func update(
        id: String,
        patch: MeasurementPatch,
        kind: MetricKind,
        diastolicId: String? = nil
    ) async throws -> Measurement {
        if isStandalone, let standalone {
            try await standalone.local.standaloneUpdateMeasurement(
                externalId: id,
                value: patch.value ?? 0,
                unit: kind.unit,
                systolic: kind == .bloodPressure ? patch.value : nil,
                diastolic: kind == .bloodPressure ? patch.diastolic : nil,
                recordedAt: patch.measuredAt ?? .now,
                note: patch.notes
            )
            let updated = try await standalone.local.standaloneMeasurements(kind: kind.rawValue, limit: nil)
                .first { $0.externalId == id }
            return updated?.toDomainMeasurement() ?? Measurement(
                id: id,
                kind: kind,
                recordedAt: patch.measuredAt ?? .now,
                value: kind == .bloodPressure
                    ? .bloodPressure(systolic: patch.value ?? 0, diastolic: patch.diastolic ?? 0)
                    : .scalar(patch.value ?? 0),
                note: patch.notes,
                source: .manual,
                externalUUID: id
            )
        }
        let idempotencyKey = IdempotencyKey()
        do {
            return try await patchRequest(
                id: id,
                patch: patch,
                kind: kind,
                diastolicId: diastolicId,
                idempotencyKey: idempotencyKey
            )
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateMeasurement(
                id: id,
                patch: patch,
                kind: kind,
                diastolicId: diastolicId,
                diastolicValue: patch.diastolic,
                glucoseContext: patch.glucoseContext
            ))
            do {
                try await outbox.enqueue(.init(
                    kind: .updateMeasurement,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                // G-2 — durable enqueue failed; the edit is neither on the
                // server nor queued. Signal `.notPersisted` so the caller rolls
                // the optimistic patch back instead of claiming "queued".
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
                throw HLError.notPersisted(String(describing: err))
            }
            throw err
        }
    }

    /// Outbox-replay path for `updateMeasurement`. Honors the BP-pair
    /// semantics persisted on the payload (sys + dia fanout when both
    /// peer-ids are present) and the glucose-context intent (T-2 — applied
    /// to the optimistic Domain row until SB-25 lands server-side
    /// glucose-context support).
    func replayUpdate(
        id: String,
        patch: MeasurementPatch,
        kind: MetricKind,
        idempotencyKey: String,
        diastolicId: String? = nil,
        diastolicValue: Double? = nil,
        glucoseContext: GlucoseContext? = nil
    ) async throws -> Measurement {
        // Re-hydrate the diastolic + glucose-context intents that were
        // suppressed by the wire-shape encoder. Replay needs them so the
        // returned optimistic Domain row reflects the user's edits.
        let hydratedPatch = MeasurementPatch(
            value: patch.value,
            measuredAt: patch.measuredAt,
            notes: patch.notes,
            diastolic: diastolicValue,
            glucoseContext: glucoseContext
        )
        return try await patchRequest(
            id: id,
            patch: hydratedPatch,
            kind: kind,
            diastolicId: diastolicId,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
    }

    private func deleteRequest(id: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/measurements/\(id)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }

    private func patchRequest(
        id: String,
        patch: MeasurementPatch,
        kind: MetricKind,
        diastolicId: String? = nil,
        idempotencyKey: IdempotencyKey
    ) async throws -> Measurement {
        // T-1 BP-pair fanout: when kind is bloodPressure und der Patch
        // einen `diastolic`-Wert trägt und der diastolische Peer bekannt
        // ist, issue ZWEI sequentielle PUTs. Same Idempotency-Key auf
        // beide Legs — Server-Idempotency-Cache deduped Retries innerhalb
        // des 24h-Windows. Reihenfolge: sys-row zuerst (id), dia-row danach
        // (diastolicId). Würde der zweite Leg fehlschlagen, kommt die Row
        // im retriable-Pfad in den Outbox-Queue zurück — kein partial-state-
        // Risiko aus Sicht des Klienten weil die Replay-Path beide Legs
        // erneut issuet (gleicher IdempotencyKey → server dedupt den
        // bereits-erfolgreichen ersten Leg).
        if kind == .bloodPressure, let dia = patch.diastolic, let diastolicId {
            let sysPatch = MeasurementPatch(
                value: patch.value,
                measuredAt: patch.measuredAt,
                notes: patch.notes
                // diastolic intentionally dropped — separate leg
            )
            let diaPatch = MeasurementPatch(
                value: dia,
                measuredAt: patch.measuredAt,
                notes: nil // BP-mirror DTOs only carry the note on systolic
            )
            let sysReq: APIRequest<MeasurementWireDTO> = try .put(
                "/api/measurements/\(id)",
                body: sysPatch,
                idempotencyKey: idempotencyKey
            )
            let sysWire = try await api.send(sysReq)
            let diaReq: APIRequest<MeasurementWireDTO> = try .put(
                "/api/measurements/\(diastolicId)",
                body: diaPatch,
                idempotencyKey: idempotencyKey
            )
            let diaWire = try await api.send(diaReq)
            await invalidateAfterWrite(kind: .bloodPressure)
            return Measurement(
                id: sysWire.id,
                kind: .bloodPressure,
                recordedAt: sysWire.measuredAt,
                value: .bloodPressure(systolic: sysWire.value, diastolic: diaWire.value),
                note: sysWire.notes ?? diaWire.notes,
                source: sysWire.source?.toDomain() ?? .manual,
                externalUUID: sysWire.externalId,
                bloodPressureDiastolicId: diaWire.id
            )
        }
        let req: APIRequest<MeasurementWireDTO> = try .put(
            "/api/measurements/\(id)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        // AUDIO fix — we sent this measurement type ourselves, so the server
        // echoing back a type with no chartable `MetricKind` is a contract break,
        // not a silently-droppable list row. Throw with context rather than
        // returning a fabricated value.
        guard let saved = wire.toDomain() else {
            throw HLError.decoding(
                "Write echo returned an unmappable measurement type \(wire.type.rawValue) with no MetricKind"
            )
        }
        // Replay paths share the same cache-invalidation semantics — both the
        // explicit `kind` from the payload (cheap, no decode of the wire) and
        // the wire's own kind (defensive) get invalidated. For non-BP this is
        // the same key; BP fans out via the all-kinds path because the wire
        // returns the single half (sys/dia) the PUT targeted.
        await invalidateAfterWrite(kind: saved.kind)
        if saved.kind != kind {
            await invalidateAfterWrite(kind: kind)
        }
        return saved
    }

    /// Bulk delete by externalUUID (HK reconciliation path).
    /// Server route: `DELETE /api/measurements/by-external-ids` accepts a
    /// JSON body `{ "externalIds": [...] }`. Idempotent — replays on the
    /// same set are no-ops server-side.
    func deleteByExternalIDs(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let req: APIRequest<EmptyResponse> = try .delete(
            "/api/measurements/by-external-ids",
            body: ExternalIDBatch(externalIds: ids)
        )
        _ = try await api.send(req)
        await invalidateAfterWriteAllKinds()
    }

    /// Drop cache rows affected by a write of a single known kind. Mirrors
    /// `CacheInvalidator.MutationKind.measurementChange(kind:).affectedKeys`
    /// — kept in-actor so writes don't depend on a separate invalidator
    /// instance. Logout-on-401 already wipes the cache wholesale, so this
    /// path only matters for mid-session writes.
    private func invalidateAfterWrite(kind: MetricKind) async {
        guard let swr else { return }
        var keys: [CacheKey] = [
            .measurementsRecent(limit: 50),
            .measurementsRecent(limit: 400),
            .measurementSeries(kind: kind, days: 1),
            .measurementSeries(kind: kind, days: 7),
            .measurementSeries(kind: kind, days: 30),
            .measurementSeries(kind: kind, days: 90),
            .measurementSeries(kind: kind, days: 180),
            .measurementSeries(kind: kind, days: 365),
            // audit-v0162 M-4 — the per-kind has-data availability slice (5min
            // TTL) was absent from every invalidation set, so the FIRST-EVER
            // reading of a kind didn't surface its tab-strip pill for up to 5 min
            // — the exact symptom the key was created to fix. Drop it on write.
            .measurementAvailability,
            // v0.14.8 INV-home-compliance-slot — `.dashboardSummary` is
            // profile-tz day-anchored. AUD-3 D-3: anchor on the SERVER-PROFILE
            // day (the same zone `DashboardStore` reads with) so this
            // invalidation hits the exact row the dashboard serves — not the
            // device-tz day, which misses for TZ-mismatched users / near midnight.
            .dashboardSummary(day: MedicationDayKey.string(timeZone: profileTimeZone)),
            .healthScore
        ]
        // audit-v0162 M-3 — the kind-scoped recent page (`.measurementsRecentKind`,
        // 45s TTL) backs each metric's chart-detail drill-down but was never
        // invalidated, so a freshly-logged BP/glucose reading was missing from
        // that page for up to 45 s. Drop the written kind's page(s).
        keys.append(contentsOf: Self.kindScopedRecentKeys(for: kind))
        await swr.invalidate(keys)
    }

    /// audit-v0162 M-3 — the `.measurementsRecentKind` keys a write of `kind`
    /// must drop: the chart-detail limits (`recent(kind:)` uses 7 / 400 / 2000)
    /// in both the plain and `groupBy=day` cache-type shapes. The management-only
    /// `:src:` variants stay TTL-bounded (out of the chart-detail hot path).
    private static func kindScopedRecentKeys(for kind: MetricKind) -> [CacheKey] {
        guard let typeKey = kind.availabilitySummaryKey else { return [] }
        let limits = [7, 400, 2000]
        var keys: [CacheKey] = []
        for limit in limits {
            keys.append(.measurementsRecentKind(type: typeKey, limit: limit))
            keys.append(.measurementsRecentKind(type: "\(typeKey):day", limit: limit))
        }
        return keys
    }

    /// Fan-out invalidation for paths that don't carry kind context (the
    /// id-only delete + HK bulk-delete-by-external-id reconciler + the
    /// v0.14.8 W3 multi-select bulk delete in `+BulkDelete.swift`, hence
    /// `internal` not `private`). Drops every measurement-series bucket
    /// across every kind plus the recent page + dashboard summary.
    internal func invalidateAfterWriteAllKinds() async {
        guard let swr else { return }
        var keys: [CacheKey] = [
            .measurementsRecent(limit: 50),
            .measurementsRecent(limit: 400),
            // AUD-3 D-3 — profile-TZ day-anchored (see invalidateAfterWrite).
            .dashboardSummary(day: MedicationDayKey.string(timeZone: profileTimeZone)),
            // audit-v0162 M-4 — availability slice (see invalidateAfterWrite).
            .measurementAvailability,
            .healthScore
        ]
        for kind in MetricKind.allCases {
            keys.append(contentsOf: [
                .measurementSeries(kind: kind, days: 1),
                .measurementSeries(kind: kind, days: 7),
                .measurementSeries(kind: kind, days: 30),
                .measurementSeries(kind: kind, days: 90),
                .measurementSeries(kind: kind, days: 180),
                .measurementSeries(kind: kind, days: 365)
            ])
            // audit-v0162 M-3 — drop every kind's chart-detail page too (an
            // id-only / bulk / HK-reconcile delete carries no kind context).
            keys.append(contentsOf: Self.kindScopedRecentKeys(for: kind))
        }
        await swr.invalidate(keys)
    }

    private func postMeasurement(_ measurement: Measurement, idempotencyKey: IdempotencyKey) async throws -> Measurement {
        let dtos = measurement.toCreateDTOs()
        guard !dtos.isEmpty else {
            // Build 1 / item 1.4a — this text reaches the operator verbatim in the
            // capture sheet's error banner, so it is localized rather than a raw
            // German technical string with a wire enum spliced into it. The
            // reachable causes were removed from `supportedKinds` in the same
            // change; this guard remains as the backstop for a future kind whose
            // picker entry lands before its `toCreateDTOs()` arm does.
            throw HLError.unknown(
                String(
                    format: String(localized: "measurement.error.notSerializable"),
                    measurement.kind.displayName
                )
            )
        }
        // Bei BP zwei sequentielle POSTs mit demselben Idempotency-Key + externalId.
        // Server-Idempotency-Cache verhindert doppelte Records bei Retries.
        var lastWire: MeasurementWireDTO?
        for dto in dtos {
            let req: APIRequest<MeasurementWireDTO> = try .post(
                "/api/measurements",
                body: dto,
                idempotencyKey: idempotencyKey
            )
            lastWire = try await api.send(req)
        }
        // Aggregiere zurück zu Domain — für BP merge sys+dia auf demselben Timestamp.
        return measurement.refreshed(idFromServer: lastWire?.id ?? measurement.id)
    }
}

private extension Measurement {
    /// Tauscht die client-lokale ID gegen die server-zugewiesene aus, behält sonst alles.
    func refreshed(idFromServer: String) -> Measurement {
        Measurement(
            id: idFromServer,
            kind: kind,
            recordedAt: recordedAt,
            value: value,
            note: note,
            source: source,
            externalUUID: externalUUID,
            bloodPressureDiastolicId: bloodPressureDiastolicId,
            glucoseContext: glucoseContext
        )
    }
}
