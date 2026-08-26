import Foundation

/// v0.5.3 F-4 — reminder-driven intake path for the
/// `MEDICATION_REMINDER` notification action handler. Lives in an
/// extension so the actor body stays under the SwiftLint type-body
/// length budget (350 lines, comments + whitespace excluded). Semantic
/// home is still `MedicationsRepository` — the bulk-intake endpoint
/// only routes through here because the action handler has no
/// pre-existing `IntakeEvent` row to PATCH.
public extension MedicationsRepository {
    /// Wire body entry for `POST /api/medications/intake/bulk`. Surfaces
    /// the single-row reminder-driven intake path — the action handler
    /// on a `MEDICATION_REMINDER` push has `medicationId` +
    /// `scheduledFor` in the payload but **no** `intakeId` (the server
    /// only pre-creates an `IntakeEvent` row on the missed-dose / RED
    /// phase, not at the regular reminder fire time). The bulk endpoint
    /// accepts a `(medicationId, scheduledFor, takenAt?, skipped?,
    /// idempotencyKey?)` tuple and idempotently
    /// inserts-or-returns-existing.
    struct BulkIntakeEntry: Codable, Sendable {
        public let medicationId: String
        /// ISO-8601 timestamp the dose was due. Server defaults to
        /// `now()` when nil — but we always send the scheduled-for to
        /// keep history rows aligned with the schedule.
        public let scheduledFor: Date?
        /// Set when the user reports "Genommen" — server marks the row
        /// as taken at this timestamp.
        public let takenAt: Date?
        /// Set when the user reports "Übersprungen".
        public let skipped: Bool
        /// Idempotency hint — the server's
        /// `intake_events.idempotency_key` has a UNIQUE index, so a
        /// duplicate POST after a transient retry returns the existing
        /// row rather than inserting a second time.
        public let idempotencyKey: String?
        /// **v1.8.5 — optional injection-site (server enum string).** Server
        /// persists it only on a taken entry for an injection medication with
        /// tracking on + site in the effective set; otherwise silently dropped
        /// (the dose still records). Out-of-set on bulk → that entry is
        /// reported `skipped` (`injection_site_not_allowed`).
        public let injectionSite: String?
        /// **H6 / v1.16.4 — per-intake actual-dose override** (server
        /// `doseTaken`, free text ≤50 chars). Persisted only on a taken
        /// (non-skipped) entry; `nil` records the take under the configured
        /// dose. Default-tolerant decode keeps older outbox payloads replayable.
        public let doseTaken: String?
        /// **v1.28 (GH #47) — Apple Health dose provenance.** `"APPLE_HEALTH"`
        /// when this entry mirrors a HealthKit dose event. Both-or-neither with
        /// ``externalId``; omitted (nil) on the app-managed reminder path so its
        /// wire body is byte-unchanged. Decode-tolerant / optional.
        public let source: String?
        /// **v1.28 (GH #47) — the HK dose-event UUID (≤128).** Drives
        /// first-write-wins dedup so an Apple dose re-sync is idempotent.
        /// Both-or-neither with ``source``.
        public let externalId: String?

        public init(
            medicationId: String,
            scheduledFor: Date?,
            takenAt: Date?,
            skipped: Bool,
            idempotencyKey: String?,
            injectionSite: String? = nil,
            doseTaken: String? = nil,
            source: String? = nil,
            externalId: String? = nil
        ) {
            self.medicationId = medicationId
            self.scheduledFor = scheduledFor
            self.takenAt = takenAt
            self.skipped = skipped
            self.idempotencyKey = idempotencyKey
            self.injectionSite = injectionSite
            self.doseTaken = doseTaken
            self.source = source
            self.externalId = externalId
        }

        /// **GH #47** — build an Apple-Health dose entry from a HK dose record
        /// targeting a mirrored medication. Returns `nil` for a dose whose log
        /// status is neither taken nor skipped (not imported by contract). A
        /// `taken` entry carries `takenAt`; a `skipped` entry sets `skipped:true`.
        /// No `idempotencyKey` — the server dedups on `(source, externalId)`.
        public static func appleHealth(
            dose: AppleHealthDoseRecord,
            mirroredMedicationId: String
        ) -> BulkIntakeEntry? {
            switch dose.logStatus {
            case .taken:
                BulkIntakeEntry(
                    medicationId: mirroredMedicationId,
                    scheduledFor: dose.scheduledAt,
                    takenAt: dose.takenAt ?? dose.scheduledAt,
                    skipped: false,
                    idempotencyKey: nil,
                    doseTaken: dose.doseText,
                    source: IntakeSource.appleHealth.wireValue,
                    externalId: dose.externalId
                )
            case .skipped:
                BulkIntakeEntry(
                    medicationId: mirroredMedicationId,
                    scheduledFor: dose.scheduledAt,
                    takenAt: nil,
                    skipped: true,
                    idempotencyKey: nil,
                    source: IntakeSource.appleHealth.wireValue,
                    externalId: dose.externalId
                )
            case .other:
                nil
            }
        }
    }

    /// Reminder-driven intake. Called from the `MEDICATION_REMINDER`
    /// notification action handler — the user tapped "Genommen" or
    /// "Übersprungen" on the banner / lock-screen, and we record the
    /// dose against the server without needing a pre-existing
    /// `IntakeEvent` row. Idempotency-key persists through APIClient
    /// retry **and** the outbox replay, so a backgrounded action with
    /// no network still lands exactly-once on the next reachability
    /// tick.
    ///
    /// - Parameters:
    ///   - medicationId: Server medication-row identifier.
    ///   - scheduledFor: When the dose was originally due. Server uses
    ///     this as the row's `scheduledFor` column — keeps the row
    ///     aligned with the recurring schedule so compliance
    ///     aggregation still works.
    ///   - status: `.taken` or `.skipped` only. Other statuses are
    ///     rejected here (the bulk endpoint cannot express `pending` or
    ///     `snoozed`; snooze is a client-only re-schedule).
    ///   - takenAt: Wall-clock when the user pressed "Genommen".
    ///     Defaults to `.now`. Ignored when `status == .skipped`.
    /// - Throws: `HLError` from the underlying APIClient. Retriable
    ///   errors are enqueued on the outbox before re-throwing — caller
    ///   can surface the `.queued` state to the UI.
    @discardableResult
    func recordFromReminder(
        medicationId: String,
        scheduledFor: Date,
        status: IntakeStatus,
        takenAt: Date = .now,
        injectionSite: InjectionSite? = nil,
        doseTaken: String? = nil,
        operationID: UUID = UUID()
    ) async throws -> String? {
        guard status == .taken || status == .skipped else {
            throw HLError.server(
                status: 422,
                code: "medications.intake.status_not_writable",
                message: "Only taken or skipped reminder dispositions can be recorded."
            )
        }
        let idempotencyKey = IdempotencyKey()
        // v1.8.5 — only a TAKEN entry carries a site.
        let site = status == .taken ? injectionSite?.serverRawValue : nil
        // H6 — the actual-dose override is meaningful only on a taken entry
        // (the server drops it on a skip); trim empties to nil so an empty
        // field records under the configured dose, not a blank string.
        let resolvedDose = status == .taken ? doseTaken?.trimmedNonEmpty : nil
        let entry = BulkIntakeEntry(
            medicationId: medicationId,
            scheduledFor: scheduledFor,
            takenAt: status == .taken ? takenAt : nil,
            skipped: status == .skipped,
            idempotencyKey: idempotencyKey.raw,
            injectionSite: site,
            doseTaken: resolvedDose
        )
        // G-1 write-ahead — this is the worst-case lost-write window: a
        // background notification action with NO UI recovery. Persist the
        // outbox entry (same idempotency key, encoded as the bulk-entry shape
        // under the `takeMedication` kind so the replay decoder routes it to
        // the same endpoint) BEFORE the send. A crash mid-send then leaves
        // exactly one replayable entry; on a 2xx the entry is removed. On a
        // retriable failure it stays durably queued and we re-throw so the
        // caller surfaces the queued state. If the write-ahead persist itself
        // failed and the send then fails retriably, `writeAhead` throws
        // `HLError.notPersisted` (G-2) — honest "couldn't save", no silent loss.
        let payload = try encoder.encode(
            OutboxQueue.Payloads.ReminderIntake(entry: entry)
        )
        let op = OutboxQueue.Operation(
            id: operationID,
            kind: .takeMedication,
            payload: payload,
            idempotencyKey: idempotencyKey.raw
        )
        return try await outbox.writeAhead(op) { [self] in
            try await postBulkIntakeInternal(entries: [entry], idempotencyKey: idempotencyKey)
        }
    }

    /// Cancels the exact durable reminder mark owned by an undo token before
    /// reachability replay can publish a disposition the user already undid.
    func cancelQueuedReminderIntake(operationID: UUID) async throws {
        try await outbox.remove(id: operationID)
    }

    /// Replay path for the reminder-driven intake — used by
    /// `OutboxReplayService` when the original `recordFromReminder`
    /// call hit a retriable error and the entry sat in the outbox
    /// until the next reachability tick. Idempotency-key persisted
    /// from the original attempt so server-side dedup catches retries
    /// that did in fact land before the local error surfaced.
    func replayReminderIntake(
        entry: BulkIntakeEntry,
        idempotencyKey: String
    ) async throws {
        _ = try await postBulkIntakeInternal(
            entries: [entry],
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
    }

    /// Internal wire-call. Shared by the live and replay paths so the
    /// happy-path response handling is single-source. `actor`-isolated
    /// because the parent type is an actor — Swift 6 carries the
    /// isolation through extension methods automatically.
    private func postBulkIntakeInternal(
        entries: [BulkIntakeEntry],
        idempotencyKey: IdempotencyKey
    ) async throws -> String? {
        let body = BulkIntakeBody(entries: entries)
        let req: APIRequest<BulkIntakeResponse> = try .post(
            "/api/medications/intake/bulk",
            body: body,
            idempotencyKey: idempotencyKey
        )
        let response = try await api.send(req)
        if let first = response.entries.first, first.status == "skipped" {
            // Server-side reject (e.g. medication_not_found) — surface
            // as a non-retriable validation error so the caller does
            // NOT re-enqueue. The action handler treats this as a soft
            // failure: notification is still dismissed, no toast.
            throw HLError.server(
                status: 422,
                code: nil,
                message: first.reason ?? "intake_rejected"
            )
        }
        return response.entries.first?.id
    }
}

private extension String {
    /// `nil` when the trimmed string is empty, otherwise the trimmed string —
    /// so an empty actual-dose field records under the configured dose rather
    /// than persisting a blank `doseTaken`.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Wire envelope for `POST /api/medications/intake/bulk`. The route
/// accepts up to 500 entries per call; we only ever send one from the
/// notification action path. File-private — the action handler talks
/// to `recordFromReminder` not to the raw body.
private struct BulkIntakeBody: Codable {
    let entries: [MedicationsRepository.BulkIntakeEntry]
}

/// Server response shape for the bulk endpoint — we treat the outer
/// counts as informational and only act on `entries[0].status`.
private struct BulkIntakeResponse: Codable {
    struct Entry: Codable {
        let index: Int
        let status: String
        let id: String?
        let reason: String?
    }

    let processed: Int
    let inserted: Int
    let duplicates: Int
    let entries: [Entry]
}
