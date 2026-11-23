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
        /// **v1.28 — Apple Health dose provenance.** `"APPLE_HEALTH"`
        /// when this entry mirrors a HealthKit dose event. Both-or-neither with
        /// ``externalId``; omitted (nil) on the app-managed reminder path so its
        /// wire body is byte-unchanged. Decode-tolerant / optional.
        public let source: String?
        /// **v1.28 — the HK dose-event UUID (≤128).** Drives
        /// first-write-wins dedup so an Apple dose re-sync is idempotent.
        /// Both-or-neither with ``source``.
        public let externalId: String?
        /// **D3 #6 — the pin onto the account slot** (`forceSlotInstant`) of
        /// a take booked away from the account zone
        /// (``MedicationReminderSlot/booking(deliveredAt:deviceTimeZone:accountTimeZone:)``).
        /// Optional on decode, so an older outbox entry replays unchanged.
        public let forceSlotInstant: Date?

        public init(
            medicationId: String,
            scheduledFor: Date?,
            takenAt: Date?,
            skipped: Bool,
            idempotencyKey: String?,
            injectionSite: String? = nil,
            doseTaken: String? = nil,
            source: String? = nil,
            externalId: String? = nil,
            forceSlotInstant: Date? = nil
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
            self.forceSlotInstant = forceSlotInstant
        }

        /// Build an Apple-Health dose entry from a HK dose record
        /// targeting a mirrored medication. Returns `nil` for a dose whose log
        /// status is neither taken nor skipped (not imported by contract). A
        /// `taken` entry carries `takenAt`; a `skipped` entry sets `skipped:true`.
        /// No `idempotencyKey` — the server dedups on `(source, externalId)`.
        ///
        /// **`scheduledFor`, server v1.42.4 (HealthLog#1221).** It is the dose
        /// event's own scheduled date when Health has one, and the event's own
        /// time for an unscheduled (extra, as-needed) dose. The server reads it
        /// to tell an edit from an extra dose: a record whose `scheduledFor`
        /// names a slot within a minute is that slot's dose recorded again,
        /// one without is another dose and never takes the slot from the dose
        /// already on it (`slotHeldByAnotherDose` / `isAnotherDose` in
        /// `src/lib/medications/scheduling/slot-upsert.ts` at `v1.42.4`).
        /// ``AppleHealthDoseRecord/occurrenceDate(scheduledDate:sampleStart:)``
        /// is where the two cases are told apart.
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
        forceSlotInstant: Date? = nil,
        operationID: UUID = UUID(),
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) async throws -> String? {
        try await recordFromReminderReturningReceipt(
            medicationId: medicationId,
            scheduledFor: scheduledFor,
            status: status,
            takenAt: takenAt,
            injectionSite: injectionSite,
            doseTaken: doseTaken,
            forceSlotInstant: forceSlotInstant,
            operationID: operationID,
            idempotencyKey: idempotencyKey
        )?.rowID
    }

    /// ``recordFromReminder(medicationId:scheduledFor:status:takenAt:injectionSite:doseTaken:operationID:idempotencyKey:)``
    /// with the row's `syncVersion`, for the app's own undo (#191).
    @discardableResult
    func recordFromReminderReturningReceipt(
        medicationId: String,
        scheduledFor: Date,
        status: IntakeStatus,
        takenAt: Date = .now,
        injectionSite: InjectionSite? = nil,
        doseTaken: String? = nil,
        forceSlotInstant: Date? = nil,
        operationID: UUID = UUID(),
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) async throws -> ReminderIntakeReceipt? {
        guard status == .taken || status == .skipped else {
            throw HLError.server(
                status: 422,
                code: "medications.intake.status_not_writable",
                message: "Only taken or skipped reminder dispositions can be recorded."
            )
        }
        // The caller may hold the key: an undo sends it back as
        // `expectedIdempotencyKey` (#191).
        // v1.8.5 — only a TAKEN entry carries a site.
        let site = status == .taken ? injectionSite.flatMap(\.serverRawValue) : nil
        // The actual-dose override is meaningful only on a taken entry
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
            doseTaken: resolvedDose,
            // The pin rides only on a take (the server ignores it elsewhere).
            forceSlotInstant: status == .taken ? forceSlotInstant : nil
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
        // `HLError.notPersisted` — honest "couldn't save", no silent loss.
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
        do {
            _ = try await postBulkIntakeInternal(
                entries: [entry],
                idempotencyKey: IdempotencyKey(raw: idempotencyKey)
            )
        } catch is MedicationAlreadyTaken {
            // The slot was taken elsewhere while the write waited. Nothing is
            // left to deliver, and nothing was lost: the row is done, not a
            // non-retriable refusal that reports a discarded write.
        }
    }

    /// Internal wire-call. Shared by the live and replay paths so the
    /// happy-path response handling is single-source. `actor`-isolated
    /// because the parent type is an actor — Swift 6 carries the
    /// isolation through extension methods automatically.
    private func postBulkIntakeInternal(
        entries: [BulkIntakeEntry],
        idempotencyKey: IdempotencyKey
    ) async throws -> ReminderIntakeReceipt? {
        let body = BulkIntakeBody(entries: entries)
        let req: APIRequest<BulkIntakeResponse> = try .post(
            "/api/medications/intake/bulk",
            body: body,
            idempotencyKey: idempotencyKey
        )
        let response = try await api.send(req)
        if let first = response.entries.first, let already = MedicationAlreadyTaken(entry: first) {
            throw already
        }
        if let first = response.entries.first, first.status == "skipped",
           first.reason == MedicationAlreadyTaken.pinOccupiedReason
        {
            // D3 #6: the pinned slot already holds another dose. Nothing was
            // written; it reads as "already taken", never as a failure.
            throw MedicationAlreadyTaken(takenAt: nil, source: nil)
        }
        if let first = response.entries.first, first.status == "skipped" {
            // Server-side reject (e.g. medication_not_found) — surface
            // as a non-retriable validation error so the caller does
            // NOT re-enqueue. The action handler treats this as a soft
            // failure: notification is still dismissed, no toast.
            // v1.42 — `intake_not_tracked` is the per-entry form of
            // `medication.intake.notTracked`; carry the code so the surface
            // and the outbox name it.
            let notTracked = first.reason == HLError.medicationIntakeNotTrackedReason
            throw HLError.server(
                status: 422,
                code: notTracked ? HLError.medicationIntakeNotTrackedCode : nil,
                message: first.reason ?? "intake_rejected"
            )
        }
        guard let first = response.entries.first else { return nil }
        return ReminderIntakeReceipt(rowID: first.rowID, syncVersion: first.rowSyncVersion)
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
/// counts as informational and only act on the first entry.
///
/// **#191 (final).** The envelope stays as in 1.48:
/// `data: { processed, inserted, updated, duplicates, skipped, entries: [...] }`.
/// Each entry is `{ index, status, id }`; only `status` gains
/// `alreadyTaken`, and such an entry carries the recorded row in `intake`
/// with its `takenAt` and `takenVia` next to it. `duplicate` keeps its old
/// meaning, an idempotent replay of the same key. There is no `results`.
/// `syncVersion` is read from `intake` (and a flat one, should the server
/// add it), so an undo can name the version it saw.
private struct BulkIntakeResponse: Decodable {
    struct Row: Decodable {
        let id: String?
        let syncVersion: Int?

        private enum CodingKeys: String, CodingKey {
            case id, syncVersion
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            syncVersion = try? c.decodeIfPresent(Int.self, forKey: .syncVersion)
        }
    }

    struct Entry: Decodable {
        let index: Int?
        let status: String
        let id: String?
        let reason: String?
        let intake: Row?
        let takenAt: String?
        let takenVia: String?
        let syncVersion: Int?

        /// The row the entry wrote, or the first take it found.
        var rowID: String? {
            id ?? intake?.id
        }

        /// The row's version as the server last wrote it, when sent.
        var rowSyncVersion: Int? {
            intake?.syncVersion ?? syncVersion
        }
    }

    let entries: [Entry]
}

/// What a bulk take or skip from the app wrote: the row and, when the server
/// sent it, the row's `syncVersion` (#191). An undo sends both preconditions.
public struct ReminderIntakeReceipt: Sendable, Equatable {
    public let rowID: String?
    public let syncVersion: Int?

    public init(rowID: String?, syncVersion: Int?) {
        self.rowID = rowID
        self.syncVersion = syncVersion
    }
}

/// **#189 (6) — the slot was already taken.**
///
/// Server 1.49.0 never overwrites a taken slot (#191): the single routes
/// answer 200 with `alreadyTaken: true` and the first take, and the bulk
/// route will answer the same per entry. Nothing was written, nothing is
/// queued; every take path shows "Already taken at 07:12 (pill box)" instead
/// of a success. The bulk entry says it with `status: "alreadyTaken"`.
public struct MedicationAlreadyTaken: Error, Sendable, Equatable {
    public let takenAt: Date?
    public let source: String?

    public init(takenAt: Date?, source: String?) {
        self.takenAt = takenAt
        self.source = source
    }

    static let markers: Set<String> = ["alreadytaken", "already_taken", "already-taken"]

    /// The bulk entry's skip reason for a pin onto a slot another dose holds
    /// (`force_slot_occupied`, `intake-bulk/entry-attribution.ts`).
    static let pinOccupiedReason = "force_slot_occupied"

    /// The `HLError` code the app's surfaces carry it under.
    public static let errorCode = "medications.intake.alreadyTaken"

    fileprivate init?(entry: BulkIntakeResponse.Entry) {
        let said = [entry.status, entry.reason ?? ""].map { $0.lowercased() }
        guard said.contains(where: Self.markers.contains) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let takenAt = entry.takenAt.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        self.init(takenAt: takenAt, source: entry.takenVia)
    }

    /// The notice the in-app surfaces show (a 409 under ``errorCode``).
    public var notice: HLError {
        .server(status: 409, code: Self.errorCode, message: message)
    }

    /// "Already taken at 07:12 (Telegram)", the source left out when unknown.
    public var message: String {
        guard let takenAt else {
            return String(localized: "med.already_taken", defaultValue: "Already taken")
        }
        let time = takenAt.formatted(date: .omitted, time: .shortened)
        guard let label = Self.sourceLabel(source) else {
            return String(format: String(localized: "med.already_taken.time", defaultValue: "Already taken at %@"), time)
        }
        return String(
            format: String(localized: "med.already_taken.time_source", defaultValue: "Already taken at %1$@ (%2$@)"),
            time,
            label
        )
    }

    /// `takenVia` as the person reads it (#191, final). INTEGRATION is the
    /// pill box or another connected device; an unknown value is "another
    /// device".
    static func sourceLabel(_ raw: String?) -> String? {
        switch MedicationTakenVia(wire: raw) {
        case .web: String(localized: "med.already_taken.source.web", defaultValue: "web")
        case .app: String(localized: "med.already_taken.source.iphone", defaultValue: "iPhone")
        case .integration: String(localized: "med.already_taken.source.integration", defaultValue: "pill box or connected device")
        case .telegram: String(localized: "med.already_taken.source.telegram", defaultValue: "Telegram")
        case .appleHealth: String(localized: "med.already_taken.source.apple_health", defaultValue: "Apple Health")
        case .importer: String(localized: "med.already_taken.source.import", defaultValue: "import")
        case .auto: String(localized: "med.already_taken.source.auto", defaultValue: "automatic")
        case .other: String(localized: "med.already_taken.source.other", defaultValue: "another device")
        case nil: nil
        }
    }
}

/// **#191 — "taken at 07:12 (pill box)" on today's rows.** Built from the
/// row's `takenAt` and `takenVia`. Only a take another device or service
/// recorded gets a note; the app's own take (`APP`) and a row without a
/// source stay as they were.
public enum MedicationTakenNote {
    public static func text(for intake: MedicationIntake) -> String? {
        guard intake.status == .taken, let takenAt = intake.takenAt,
              let via = MedicationTakenVia(wire: intake.takenVia), via != .app,
              let label = MedicationAlreadyTaken.sourceLabel(intake.takenVia) else { return nil }
        return String(
            format: String(localized: "med.today.taken_via", defaultValue: "taken at %1$@ (%2$@)"),
            takenAt.formatted(date: .omitted, time: .shortened),
            label
        )
    }
}
