import Foundation

/// **Build 6.1 — free, back-datable intake logging.**
///
/// The per-medication `POST /api/medications/{id}/intake` route (schema
/// `MedicationIntakeRequest`, `src/lib/validations/medication/intake.ts`) is the
/// one endpoint that logs a dose *without* a pre-existing `IntakeEvent` row and
/// with the full free-form field set: an arbitrary back-dated `takenAt`, an
/// optional `scheduledFor` (the slot the dose belongs to), a deliberate `skipped`
/// flag, an optional `doseTaken` deviation, an optional injection site, and an
/// optional `forceSlotInstant` late-take pin. The route is idempotent on the
/// caller-issued `idempotencyKey` (persisted in the body AND carried as the
/// request header so the server's `withIdempotency` + the `intake_events`
/// UNIQUE-key both dedup a retry / replay).
///
/// **Issue #64 — NO `source` field.** The intake schema does not accept a
/// `source`; the server derives provenance from the request context. Sending one
/// would 422 (unknown key stripped) at best and mis-signal intent at worst — the
/// wire body (`MedicationIdIntakeBody`) deliberately carries no such field.
///
/// Lives in its own extension so the actor body stays under the
/// `type_body_length` budget (mirrors `+ReminderIntake` / `+Standalone`).
public extension MedicationsRepository {
    /// Log a free / back-dated intake against `POST /api/medications/{id}/intake`.
    ///
    /// On a retriable network failure the exact wire body is enqueued on the
    /// outbox under `.logMedicationIntake` (persisted idempotency key), so a dose
    /// logged offline replays exactly-once on the next reachability tick — the
    /// caller can surface the `.queued` state. A non-retriable server error
    /// (typically a 422 schema/slot reject) re-throws without enqueuing.
    ///
    /// - Parameters:
    ///   - medicationId: Server medication-row identifier (path param).
    ///   - scheduledFor: The slot the dose belongs to. `nil` → server defaults it
    ///     to `takenAt` (or `now()`), so a plain back-log needs only `takenAt`.
    ///   - takenAt: When the dose was actually taken. Ignored on a skip. `nil`
    ///     on a taken write → server defaults to `now()`.
    ///   - skipped: `true` logs a deliberate skip (no `takenAt`, no dose/site).
    ///   - doseTaken: Free-text actual-dose deviation (server trims / caps at 50);
    ///     dropped on a skip. Empty → recorded under the configured dose.
    ///   - injectionSite: Optional site for a taken injection dose; dropped on a
    ///     skip and silently ignored server-side for a non-injection med.
    ///   - forceSlotInstant: Optional late-take pin onto a real slot anchor.
    func logIntake(
        medicationId: String,
        scheduledFor: Date?,
        takenAt: Date?,
        skipped: Bool,
        doseTaken: String? = nil,
        injectionSite: InjectionSite? = nil,
        forceSlotInstant: Date? = nil
    ) async throws -> MedicationIntake {
        let idempotencyKey = IdempotencyKey()
        // A site / dose override rides only on a TAKEN write; never on a skip
        // (the server would drop it anyway — keep the wire clean).
        let site = skipped ? nil : injectionSite?.serverRawValue
        let trimmedDose = doseTaken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDose = skipped ? nil : (trimmedDose?.isEmpty == false ? trimmedDose : nil)
        let body = MedicationIdIntakeBody(
            scheduledFor: scheduledFor,
            takenAt: skipped ? nil : takenAt,
            skipped: skipped,
            idempotencyKey: idempotencyKey.raw,
            injectionSite: site,
            doseTaken: resolvedDose,
            forceSlotInstant: forceSlotInstant
        )
        do {
            return try await postIdIntake(
                medicationId: medicationId,
                body: body,
                idempotencyKey: idempotencyKey
            )
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.LogMedicationIntake(
                medicationId: medicationId,
                body: body
            ))
            do {
                try await outbox.enqueue(.init(
                    kind: .logMedicationIntake,
                    payload: payload,
                    idempotencyKey: idempotencyKey.raw
                ))
            } catch {
                HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            }
            throw err
        }
    }

    /// Outbox replay path — re-POSTs the persisted body under the persisted
    /// idempotency key so the server dedup suppresses a write that may already
    /// have landed before app-kill. Invalidates the intake-aggregate SWR rows
    /// on success (symmetric with `replay` / `replayUpdateIntake`).
    func replayLogIntake(
        medicationId: String,
        body: MedicationIdIntakeBody,
        idempotencyKey: String
    ) async throws -> MedicationIntake {
        let intake = try await postIdIntake(
            medicationId: medicationId,
            body: body,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        // Mirror `invalidateAfterIntakeReplay()` (private in the actor body):
        // drop the compliance heatmap + dashboard + health-score + today rows.
        await swr?.invalidate(MutationKind.medicationIntakeChange.affectedKeys)
        return intake
    }

    /// Shared wire-call for the live + replay paths. The POST returns the raw
    /// Prisma intake row (same shape `postIntake` maps), so decode
    /// `MedicationIntakeWireDTO` and map client-side.
    private func postIdIntake(
        medicationId: String,
        body: MedicationIdIntakeBody,
        idempotencyKey: IdempotencyKey
    ) async throws -> MedicationIntake {
        let req: APIRequest<MedicationIntakeWireDTO> = try .post(
            "/api/medications/\(medicationId)/intake",
            body: body,
            idempotencyKey: idempotencyKey
        )
        let wire = try await api.send(req)
        return wire.toDomain()
    }
}
