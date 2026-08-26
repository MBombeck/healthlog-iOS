import Foundation

public actor MedicationsRepository {
    // v0.5.3 F-4: relaxed from `private` to `internal` so the
    // `+ReminderIntake.swift` extension file can reuse the same
    // dependencies without duplicating the actor's init contract.
    // Module-scope only — neither property leaks outside the app target.
    let api: APIClientProtocol
    let outbox: OutboxQueue
    let encoder: JSONEncoder
    /// v0.11 W2 — standalone seam. `nil` (default) → existing server path
    /// verbatim (paired invariant). Non-nil + live standalone → intake writes
    /// land in the local mirror; no `/api/*` fires. **Scope (W2):** local intake
    /// write+readback only — full on-device compliance aggregation
    /// (`MedicationRecurrenceEngine` over local intakes) is the noted W2b
    /// follow-up, so the paired compliance path stays byte-unchanged.
    let standalone: StandaloneGate?
    /// **audit-v0162 M-5 — SWR cache coordinator (optional).** When wired, the
    /// OUTBOX-REPLAY paths (`replay*`) drop the SWR rows an offline med/intake
    /// write affects once it finally lands on the server — symmetric with
    /// `MeasurementsRepository.replay` → `invalidateAfterWrite`. Before this the
    /// medication replay path re-POSTed but invalidated NOTHING (the store-side
    /// invalidation runs only on the LIVE path; `OutboxReplayService` calls this
    /// repo directly), so a dose marked / med created offline that replayed hours
    /// later left `.medicationsList` / `.medicationsCompliance` / `.dashboardSummary`
    /// / `.healthScore` stale until their TTL. `nil` (unit tests + the current
    /// composition root, which does not yet pass it) keeps the legacy behaviour.
    let swr: SWRCoordinator?

    /// **CU-20 (#69)** — last `updatedAt` seen from `/api/medications/layout`.
    /// Stored here (not in the `+Layout` extension, which cannot hold stored
    /// properties) and read/written from that extension. Sent as
    /// `baseUpdatedAt` on the next layout PUT; `nil` = no token yet →
    /// unconditional write.
    var listLayoutToken: String?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        standalone: StandaloneGate? = nil,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.standalone = standalone
        self.swr = swr
    }

    /// audit-v0162 M-5 — SWR keys an intake-status replay invalidates. Uses the
    /// device-tz day-anchored `MutationKind` matrix (the same cross-cutting
    /// contract fallback `CacheInvalidator` documents — the repo has no
    /// profile-tz context) so a replayed mark drops the compliance heatmap +
    /// dashboard summary + health score + today-intakes row.
    private func invalidateAfterIntakeReplay() async {
        await swr?.invalidate(MutationKind.medicationIntakeChange.affectedKeys)
    }

    /// audit-v0162 M-5 — SWR keys a medication-definition replay invalidates
    /// (create / update / delete). Same device-tz matrix rationale as above.
    private func invalidateAfterMedicationReplay() async {
        await swr?.invalidate(MutationKind.medicationChange.affectedKeys)
    }

    /// True iff the standalone branch must be taken.
    var isStandaloneActive: Bool {
        standalone?.isActive == true
    }

    /// v0.11 W2 — standalone intake write. Persists a `taken`/`skipped`/`snoozed`
    /// dose to the local mirror keyed by `(medicationId, takenAt)` and returns
    /// the optimistic `MedicationIntake` the list re-renders against. No network.
    /// Reached only from the store's standalone branch (where `medicationId` is
    /// in hand); the server `record(intake:)` path is unchanged.
    public func recordStandaloneIntake(
        medicationId: String,
        scheduledAt: Date,
        status: IntakeStatus,
        takenAt: Date = .now,
        injectionSite: InjectionSite? = nil
    ) async throws -> MedicationIntake {
        guard let standalone else {
            throw HLError.unknown("recordStandaloneIntake ohne Standalone-Gate")
        }
        // v0.13 WP — mirror the paired `record(intake:)` gate: a site rides only
        // on a `taken` dose, persisted as the server-wire raw value so an offline
        // injection logs its site like the paired path (+ adopt-on-pair round-trip).
        let site = status == .taken ? injectionSite?.serverRawValue : nil
        let snap = try await standalone.local.standaloneAddIntake(
            medicationId: medicationId,
            takenAt: status == .taken ? takenAt : scheduledAt,
            status: status.writableRawValue,
            injectionSite: site,
            note: nil
        )
        return MedicationIntake(
            id: snap.externalId,
            medicationId: medicationId,
            scheduledAt: scheduledAt,
            takenAt: status == .taken ? takenAt : nil,
            status: status,
            snoozedUntil: nil
        )
    }

    /// v0.11 W26 — undo a standalone-confirmed dose. The mark *added* a row to
    /// the mirror (keyed by `externalId`), so the inverse is a delete. No
    /// network. Reached only from the store's `undoIntakeMark` standalone
    /// branch where the added `externalId` is in hand.
    public func deleteStandaloneIntake(externalId: String) async throws {
        guard let standalone else {
            throw HLError.unknown("deleteStandaloneIntake ohne Standalone-Gate")
        }
        try await standalone.local.standaloneDeleteIntake(externalId: externalId)
    }

    /// v0.11 W2 — standalone today-intake read from the mirror. Returns the
    /// locally-logged doses scheduled for `now`'s calendar day. Consumed by
    /// `todayIntakes()`'s standalone branch (G2 read-back); compliance is
    /// rolled up on-device via `standaloneCompliance(days:)` (G3).
    public func standaloneTodayIntakes(now: Date = .now, calendar: Calendar = .current) async throws -> [MedicationIntake] {
        guard let standalone else { return [] }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let snaps = try await standalone.local.standaloneIntakes(medicationId: nil)
        return snaps.compactMap { snap -> MedicationIntake? in
            guard snap.takenAt >= start, snap.takenAt < end else { return nil }
            let status = IntakeStatus(rawValue: snap.status) ?? .taken
            return MedicationIntake(
                id: snap.externalId,
                medicationId: snap.medicationId,
                scheduledAt: snap.takenAt,
                takenAt: status == .taken ? snap.takenAt : nil,
                status: status,
                snoozedUntil: nil
            )
        }
    }

    public func list() async throws -> [Medication] {
        // v0.13 W5 — standalone reads the local medication-definition mirror so
        // a fully-offline user can create / schedule / take medications. Branching
        // here (not in the store) keeps `MedicationsStore.load()`'s SWR + direct
        // paths byte-unchanged and stops any `/api/medications` leak.
        if isStandaloneActive { return try await standaloneList() }
        // Server liefert `MedicationWireDTO[]` mit dem v1.4.x-Schema
        // (`schedules` array, `treatmentClass`, `dosesPerUnit`, `lastTakenAt`,
        // `todayEventCount` etc.). UI konsumiert weiterhin `Medication` —
        // das Mapping flacht `schedules` auf `times` ab.
        let req: APIRequest<[MedicationWireDTO]> = .get("/api/medications")
        let wires = try await api.send(req)
        return wires.map { $0.toDomain() }
    }

    public func todayIntakes() async throws -> [MedicationIntake] {
        // v0.11 W2-reconcile (G2) — standalone reads the locally-logged doses
        // back from the mirror instead of `/api/medications/intake`, so a
        // standalone-confirmed dose re-appears in the today list + on the card.
        if isStandaloneActive { return try await standaloneTodayIntakes() }
        let req: APIRequest<[MedicationIntake]> = .get("/api/medications/intake", query: [("scope", "today")])
        return try await api.send(req)
    }

    public func compliance(days: Int = 28) async throws -> [ComplianceDay] {
        // v0.13 W5 (M2) — standalone derives per-day compliance on-device: the
        // scheduled-dose denominator comes from `MedicationRecurrenceEngine` over
        // the local definitions, the numerator from the intake mirror. No `/api/*`.
        if isStandaloneActive { return try await standaloneCompliance(days: days) }
        let req: APIRequest<[ComplianceDay]> = .get(
            "/api/medications/intake",
            query: [("scope", "compliance"), ("days", String(days))]
        )
        return try await api.send(req)
    }

    // v0.13 W5 (M1) — `compliance(medicationID:)` lives in
    // `MedicationsRepository+Standalone.swift` so the per-medication compliance
    // route can be gated on standalone without pushing this actor's type-body
    // over budget. Paired path is byte-unchanged (server-canonical payload).

    /// GLP-1 medication detail extras — dose-change history, recent
    /// intakes (last 12), inventory. Server source: `route.ts:38-106`.
    public func glp1Details(medicationID: String) async throws -> Glp1DetailsDTO {
        let req: APIRequest<Glp1DetailsDTO> = .get("/api/medications/\(medicationID)/glp1")
        return try await api.send(req)
    }

    /// Paginated intake history for a single medication. Server source:
    /// `src/app/api/medications/[id]/intake/route.ts:160-195`. Default
    /// shape matches the web's `DrugLevelChart` consumer (newest first).
    ///
    /// **v0.6.2.1 F4 — sortBy switched `takenAt` → `scheduledFor`.**
    /// `takenAt desc` pushed every event with `takenAt == nil` (missed
    /// or still-pending slots) to the tail of the response. The
    /// detail-screen `MedicationDetailStore` derives `verlaufGlyphs`
    /// (14-day) and `complianceSummary` (30-day) from the loaded set,
    /// so missing events meant the analytics surfaces undercounted
    /// past-due slots that fell inside their windows (Lisinopril
    /// screenshot 2026-05-24 15:50 — "0 von 2 pünktlich" against an
    /// actually-multi-week history). `scheduledFor desc` is the
    /// server default and orders missed + taken slots by the same key
    /// — analytics windows then see every recent slot, taken or not.
    /// The display-layer `IntakeHistorySection` already re-sorts by
    /// `scheduledFor desc` for rendering, so the visible row order is
    /// unchanged.
    public func intakeHistory(
        medicationID: String,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> PaginatedIntakeEnvelope {
        let req: APIRequest<PaginatedIntakeEnvelope> = .get(
            "/api/medications/\(medicationID)/intake",
            query: [
                ("limit", String(limit)),
                ("offset", String(offset)),
                ("sortBy", "scheduledFor"),
                ("sortDir", "desc")
            ]
        )
        return try await api.send(req)
    }

    // MARK: - W3-MEDCONTRACT (v0.14.8) — server dose-history ledger

    /// Maximum span the server's dose-history route serves (`MAX_WINDOW_DAYS
    /// = 366` in `dose-history/route.ts`); requesting more is silently
    /// clamped server-side, so we ask for exactly the cap.
    public static let doseHistoryMaxWindowDays = 366

    /// The unified per-slot dose-history ledger — the SAME read-model the
    /// server's compliance % and the web "Verlauf" tab consume, era-aware
    /// since v1.16.3 (a past day is judged against the schedule live THEN).
    ///
    /// Route: `GET /api/medications/{id}/dose-history?from&to`. `from`
    /// defaults to the server's 366-day cap so the Verlauf covers the full
    /// servable window; the server additionally floors at the medication's
    /// `createdAt`. Throws against ≤ v1.15.17 servers (route absent → 404)
    /// and in standalone mode — callers treat any throw as "ledger
    /// unavailable" and keep the local per-slot derivation as fallback.
    public func doseHistory(
        medicationID: String,
        from: Date? = nil,
        to: Date? = nil,
        now: Date = .now
    ) async throws -> MedicationDoseHistoryEnvelope {
        // Standalone has no server ledger — the local mirror + recurrence
        // engine stay authoritative (callers fall back on this throw).
        if isStandaloneActive { throw HLError.offline }
        let resolvedTo = to ?? now
        let resolvedFrom = from ?? resolvedTo.addingTimeInterval(
            -Double(Self.doseHistoryMaxWindowDays) * 24 * 60 * 60
        )
        let req: APIRequest<MedicationDoseHistoryEnvelope> = .get(
            "/api/medications/\(medicationID)/dose-history",
            query: [
                ("from", ISO8601DateFormatter.plain.string(from: resolvedFrom)),
                ("to", ISO8601DateFormatter.plain.string(from: resolvedTo))
            ]
        )
        return try await api.send(req)
    }

    // The wire-body payload structs (`IntakeUpdate`, `MedicationCreate`,
    // `MedicationPatch`, `IntakePatch`) live in
    // `MedicationsRepository+WireBodies.swift` (extracted v0.10 W-Meds-A2 to
    // keep this actor under the type-body-length budget). Their nested-type
    // names are unchanged, so the outbox `Payloads.*` references keep resolving.

    /// Optimistic update. Idempotency-Key wird **einmal** pro logischer Operation
    /// erzeugt und überlebt sowohl APIClient-internes Retry als auch den
    /// Outbox-Fallback bei retriable Fehlern — Server erkennt Wiederholungen
    /// am `(userId, key, method, path)`-Tupel und unterdrückt Doppelschreibungen.
    public func record(
        intake id: String,
        status: IntakeStatus,
        takenAt: Date = .now,
        injectionSite: InjectionSite? = nil
    ) async throws -> MedicationIntake {
        // v1.8.5 — the site is meaningful only on a TAKEN write; never attach
        // it to a skip (server would drop it anyway, but we keep the wire clean).
        let site = status == .taken ? injectionSite?.serverRawValue : nil
        let body = try IntakeUpdate(intakeId: id, status: status.writableRawValue, takenAt: takenAt, injectionSite: site)
        let idempotencyKey = IdempotencyKey()
        do {
            return try await postIntake(body, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(body)
            do {
                try await outbox.enqueue(.init(
                    kind: .takeMedication,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    /// Replay-Pfad für Outbox. Nutzt den persistierten Key, damit Server-Dedup greift.
    public func replay(_ body: IntakeUpdate, idempotencyKey: String) async throws -> MedicationIntake {
        let intake = try await postIntake(body, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterIntakeReplay() // audit-v0162 M-5
        return intake
    }

    private func postIntake(_ body: IntakeUpdate, idempotencyKey: IdempotencyKey) async throws -> MedicationIntake {
        // POST returns the raw Prisma row (scheduledFor not scheduledAt, no
        // synthesised status). Map client-side. A4-Audit row 4.
        let req: APIRequest<MedicationIntakeWireDTO> = try .post(
            "/api/medications/intake",
            body: body,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        return wire.toDomain()
    }

    // MARK: - Medication CRUD (v0.5.x edit/delete expansion)

    /// Create a new medication definition. Server route:
    /// `POST /api/medications` returns the wire DTO. Network-failure path
    /// enqueues on the outbox under `createMedication`.
    public func create(_ body: MedicationCreate) async throws -> Medication {
        // v0.13 W5 — standalone persists the definition to the local mirror; no
        // network, no outbox. Returns the canonical local row (id == externalId).
        if isStandaloneActive { return try await standaloneCreate(body) }
        let idempotencyKey = IdempotencyKey()
        do {
            return try await postMedication(body, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.CreateMedication(body: body))
            do {
                try await outbox.enqueue(.init(
                    kind: .createMedication,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    /// Replay path for `createMedication`. Uses the persisted idempotency-key
    /// so the server's `(userId, key, method, path)` dedup window prevents
    /// double-create on retry.
    public func replayCreate(_ body: MedicationCreate, idempotencyKey: String) async throws -> Medication {
        let med = try await postMedication(body, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterMedicationReplay() // audit-v0162 M-5
        return med
    }

    /// Patch an existing medication. Server route:
    /// `PUT /api/medications/[id]`. Returns the updated wire DTO.
    public func update(id: String, patch: MedicationPatch) async throws -> Medication {
        // v0.13 W5 — standalone applies the patch to the local mirror (read-
        // modify-write over the persisted definition). No network.
        if isStandaloneActive { return try await standaloneUpdate(id: id, patch: patch) }
        let idempotencyKey = IdempotencyKey()
        do {
            return try await putMedication(id: id, patch: patch, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateMedication(id: id, patch: patch))
            do {
                try await outbox.enqueue(.init(
                    kind: .updateMedication,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    public func replayUpdate(id: String, patch: MedicationPatch, idempotencyKey: String) async throws -> Medication {
        let med = try await putMedication(id: id, patch: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterMedicationReplay() // audit-v0162 M-5
        return med
    }

    /// Delete (archive) a medication. Server route:
    /// `DELETE /api/medications/[id]` returns 204.
    public func delete(id: String) async throws {
        // v0.13 W5 — standalone soft-deletes (archives) the local definition.
        if isStandaloneActive { try await standaloneArchive(id: id)
            return
        }
        let idempotencyKey = IdempotencyKey()
        do {
            try await deleteMedication(id: id, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.DeleteMedication(id: id))
            do {
                try await outbox.enqueue(.init(
                    kind: .deleteMedication,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    public func replayDelete(id: String, idempotencyKey: String) async throws {
        try await deleteMedication(id: id, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterMedicationReplay() // audit-v0162 M-5
    }

    // MARK: - Intake retro-mutate (v0.5.x)

    /// Patch an existing intake event. Server route:
    /// `PUT /api/medications/[medicationId]/intake/[eventId]`. Used by the
    /// "fix wrong takenAt" + "mis-marked skipped → taken" UIs.
    public func updateIntake(
        medicationId: String,
        eventId: String,
        patch: IntakePatch
    ) async throws -> MedicationIntake {
        let idempotencyKey = IdempotencyKey()
        do {
            return try await putIntake(
                medicationId: medicationId,
                eventId: eventId,
                patch: patch,
                idempotencyKey: idempotencyKey
            )
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateIntake(
                medicationId: medicationId,
                eventId: eventId,
                patch: patch
            ))
            do {
                try await outbox.enqueue(.init(
                    kind: .updateIntake,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    public func replayUpdateIntake(
        medicationId: String,
        eventId: String,
        patch: IntakePatch,
        idempotencyKey: String
    ) async throws -> MedicationIntake {
        let intake = try await putIntake(
            medicationId: medicationId,
            eventId: eventId,
            patch: patch,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        await invalidateAfterIntakeReplay() // audit-v0162 M-5
        return intake
    }

    /// Delete a phantom intake event. Server route:
    /// `DELETE /api/medications/[medicationId]/intake/[eventId]` returns 204.
    public func deleteIntake(medicationId: String, eventId: String) async throws {
        let idempotencyKey = IdempotencyKey()
        do {
            try await deleteIntakeRequest(
                medicationId: medicationId,
                eventId: eventId,
                idempotencyKey: idempotencyKey
            )
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.DeleteIntake(
                medicationId: medicationId,
                eventId: eventId
            ))
            do {
                try await outbox.enqueue(.init(
                    kind: .deleteIntake,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    public func replayDeleteIntake(
        medicationId: String,
        eventId: String,
        idempotencyKey: String
    ) async throws {
        try await deleteIntakeRequest(
            medicationId: medicationId,
            eventId: eventId,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        await invalidateAfterIntakeReplay() // audit-v0162 M-5
    }

    // MARK: - Private network primitives

    private func postMedication(_ body: MedicationCreate, idempotencyKey: IdempotencyKey) async throws -> Medication {
        let req: APIRequest<MedicationWireDTO> = try .post(
            "/api/medications",
            body: body,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        return wire.toDomain()
    }

    private func putMedication(
        id: String,
        patch: MedicationPatch,
        idempotencyKey: IdempotencyKey
    ) async throws -> Medication {
        let req: APIRequest<MedicationWireDTO> = try .put(
            "/api/medications/\(id)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        return wire.toDomain()
    }

    private func deleteMedication(id: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/medications/\(id)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }

    private func putIntake(
        medicationId: String,
        eventId: String,
        patch: IntakePatch,
        idempotencyKey: IdempotencyKey
    ) async throws -> MedicationIntake {
        let req: APIRequest<MedicationIntakeWireDTO> = try .put(
            "/api/medications/\(medicationId)/intake/\(eventId)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        return wire.toDomain()
    }

    private func deleteIntakeRequest(
        medicationId: String,
        eventId: String,
        idempotencyKey: IdempotencyKey
    ) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/medications/\(medicationId)/intake/\(eventId)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }
}
