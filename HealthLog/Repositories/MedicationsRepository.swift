import Foundation

public actor MedicationsRepository {
    // v0.5.3 F-4: relaxed from `private` to `internal` so the
    // `+ReminderIntake.swift` extension file can reuse the same
    // dependencies without duplicating the actor's init contract.
    // Module-scope only — neither property leaks outside the app target.
    let api: APIClientProtocol
    let outbox: OutboxQueue
    let encoder: JSONEncoder
    /// **SWR cache coordinator (optional).** When wired, the
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

    /// Last `updatedAt` seen from `/api/medications/layout`.
    /// Stored here (not in the `+Layout` extension, which cannot hold stored
    /// properties) and read/written from that extension. Sent as
    /// `baseUpdatedAt` on the next layout PUT; `nil` = no token yet →
    /// unconditional write.
    var listLayoutToken: String?

    /// Where the 1.49.0 medication capabilities are read (#191). Tests point
    /// it at their own suite through ``useCapabilitySuite(_:)``.
    var capabilityDefaults: UserDefaults? = MedicationCapabilities.appGroupDefaults

    func useCapabilitySuite(_ suiteName: String) {
        capabilityDefaults = UserDefaults(suiteName: suiteName)
    }

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

    /// SWR keys an intake-status replay invalidates. Uses the
    /// device-tz day-anchored `MutationKind` matrix (the same cross-cutting
    /// contract fallback `CacheInvalidator` documents — the repo has no
    /// profile-tz context) so a replayed mark drops the compliance heatmap +
    /// dashboard summary + health score + today-intakes row.
    private func invalidateAfterIntakeReplay() async {
        await swr?.invalidate(MutationKind.medicationIntakeChange.affectedKeys)
    }

    /// SWR keys a medication-definition replay invalidates
    /// (create / update / delete). Same device-tz matrix rationale as above.
    private func invalidateAfterMedicationReplay() async {
        await swr?.invalidate(MutationKind.medicationChange.affectedKeys)
    }

    public func list() async throws -> [Medication] {
        // Server liefert `MedicationWireDTO[]` mit dem v1.4.x-Schema
        // (`schedules` array, `treatmentClass`, `dosesPerUnit`, `lastTakenAt`,
        // `todayEventCount` etc.). UI konsumiert weiterhin `Medication` —
        // das Mapping flacht `schedules` auf `times` ab.
        let req: APIRequest<[MedicationWireDTO]> = .get("/api/medications")
        let wires = try await api.send(req)
        return wires.map { $0.toDomain() }
    }

    public func todayIntakes() async throws -> [MedicationIntake] {
        let req: APIRequest<[MedicationIntake]> = .get("/api/medications/intake", query: [("scope", "today")])
        return try await api.send(req)
    }

    public func compliance(days: Int = 28) async throws -> [ComplianceDay] {
        let req: APIRequest<[ComplianceDay]> = .get(
            "/api/medications/intake",
            query: [("scope", "compliance"), ("days", String(days))]
        )
        return try await api.send(req)
    }

    // `compliance(medicationID:)` lives in `MedicationsRepository+ComplianceReport.swift`
    // so this actor's type body stays within budget.

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
    /// **sortBy switched `takenAt` → `scheduledFor`.**
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

    // MARK: - Server dose-history ledger

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
    /// — callers treat any throw as "ledger unavailable" and keep the local per-slot derivation as fallback.
    public func doseHistory(
        medicationID: String,
        from: Date? = nil,
        to: Date? = nil,
        now: Date = .now
    ) async throws -> MedicationDoseHistoryEnvelope {
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
        let site = status == .taken ? injectionSite.flatMap(\.serverRawValue) : nil
        let body = try IntakeUpdate(
            intakeId: id,
            status: status.writableRawValue,
            takenAt: takenAt,
            injectionSite: site,
            snoozedUntil: status == .snoozed ? takenAt.addingTimeInterval(MedicationSnooze.interval) : nil
        )
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(body)
        let op = OutboxQueue.Operation(kind: .takeMedication, payload: payload, idempotencyKey: idempotencyKey.raw)
        return try await outbox.writeAhead(op) { [self] in
            try await postIntake(body, idempotencyKey: idempotencyKey)
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
        if let already = wire.alreadyTakenError { throw already } // #191
        return wire.toDomain()
    }

    // MARK: - Medication CRUD

    /// Create a new medication definition. Server route:
    /// `POST /api/medications` returns the wire DTO. Network-failure path
    /// enqueues on the outbox under `createMedication`.
    public func create(_ body: MedicationCreate) async throws -> Medication {
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.CreateMedication(body: body))
        let op = OutboxQueue.Operation(kind: .createMedication, payload: payload, idempotencyKey: idempotencyKey.raw)
        return try await outbox.writeAhead(op) { [self] in
            try await postMedication(body, idempotencyKey: idempotencyKey)
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
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.UpdateMedication(id: id, patch: patch))
        let op = OutboxQueue.Operation(kind: .updateMedication, payload: payload, idempotencyKey: idempotencyKey.raw)
        return try await outbox.writeAhead(op) { [self] in
            try await putMedication(id: id, patch: patch, idempotencyKey: idempotencyKey)
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
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.DeleteMedication(id: id))
        let op = OutboxQueue.Operation(kind: .deleteMedication, payload: payload, idempotencyKey: idempotencyKey.raw)
        try await outbox.writeAhead(op) { [self] in
            try await deleteMedication(id: id, idempotencyKey: idempotencyKey)
        }
    }

    public func replayDelete(id: String, idempotencyKey: String) async throws {
        try await deleteMedication(id: id, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterMedicationReplay() // audit-v0162 M-5
    }

    // MARK: - Intake retro-mutate

    /// Patch an existing intake event. Server route:
    /// `PUT /api/medications/[medicationId]/intake/[eventId]`. Used by the
    /// "fix wrong takenAt" + "mis-marked skipped → taken" UIs.
    public func updateIntake(
        medicationId: String,
        eventId: String,
        patch: IntakePatch
    ) async throws -> MedicationIntake {
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.UpdateIntake(
            medicationId: medicationId,
            eventId: eventId,
            patch: patch
        ))
        let op = OutboxQueue.Operation(kind: .updateIntake, payload: payload, idempotencyKey: idempotencyKey.raw)
        return try await outbox.writeAhead(op) { [self] in
            try await putIntake(
                medicationId: medicationId,
                eventId: eventId,
                patch: patch,
                idempotencyKey: idempotencyKey
            )
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
    ///
    /// `expected` (#191) is the version of the row the person saw; the server
    /// answers `409 medications.intake.changedSinceSeen` when the row changed
    /// since, so an undo never removes someone else's take. It travels with
    /// the outbox entry, so a replay keeps the same precondition.
    public func deleteIntake(
        medicationId: String,
        eventId: String,
        expected: IntakeUndoPrecondition? = nil
    ) async throws {
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.DeleteIntake(
            medicationId: medicationId,
            eventId: eventId,
            expectedSyncVersion: expected?.syncVersion,
            expectedIdempotencyKey: expected?.idempotencyKey
        ))
        let op = OutboxQueue.Operation(kind: .deleteIntake, payload: payload, idempotencyKey: idempotencyKey.raw)
        try await outbox.writeAhead(op) { [self] in
            try await deleteIntakeRequest(
                medicationId: medicationId,
                eventId: eventId,
                expected: expected,
                idempotencyKey: idempotencyKey
            )
        }
    }

    public func replayDeleteIntake(
        medicationId: String,
        eventId: String,
        expected: IntakeUndoPrecondition? = nil,
        idempotencyKey: String
    ) async throws {
        try await deleteIntakeRequest(
            medicationId: medicationId,
            eventId: eventId,
            expected: expected,
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
        expected: IntakeUndoPrecondition? = nil,
        idempotencyKey: IdempotencyKey
    ) async throws {
        let req = APIRequest<EmptyResponse>(
            method: .delete,
            path: "/api/medications/\(medicationId)/intake/\(eventId)",
            query: expected?.queryItems(capabilities: capabilityDefaults) ?? [],
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
    }
}
