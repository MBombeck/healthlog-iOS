import Foundation

/// Replay-Pipeline für die Outbox. Wird vom AppContainer auf Online-Wechsel und beim
/// Auth-Bootstrap getriggert. Iteriert über alle Operations, ruft den passenden
/// Repository-Endpoint, entfernt bei Erfolg, inkrementiert Versuche bei retriable
/// Fehlern, gibt nach `maxAttempts` auf und sweep't überzählige Rows aus dem
/// On-Disk-Store (sonst würden sie nach A5 unbegrenzt wachsen).
public actor OutboxReplayService {
    let outbox: OutboxQueue
    /// `internal` (not `private`) so the `+HealthKit.swift` dispatch extension
    /// can drain `.syncHealthKitSample` through the same repository the online
    /// batch path uses (mirrors the `therapyLogRepo` / `workoutsRepo` seams).
    let measurementsRepo: MeasurementsRepository
    private let moodRepo: MoodRepository
    private let medicationsRepo: MedicationsRepository
    /// v0.7.1 W-TARGETS-EDITOR — optional so existing call sites (and the
    /// outbox-replay unit tests) keep compiling without wiring it. When `nil`,
    /// a `.updateThresholds` op is treated as non-retriable and dropped (same
    /// behaviour as an unknown kind) so it can never block the queue.
    private let userThresholdsRepo: UserThresholdsRepository?
    /// v0.8.0 W10 — optional so existing call sites + replay tests keep
    /// compiling. When `nil`, an `.updateInsightsLayout` op is treated as
    /// non-retriable and dropped (same as an unknown kind) so it can never
    /// block the queue.
    private let insightsLayoutRepo: InsightsLayoutRepository?
    /// **v0.10.0 W10 M1 — bidirectional HK mood mirror on the replay path.**
    ///
    /// A successfully-replayed offline mood create/update must be mirrored into
    /// HKStateOfMind and a replayed delete must remove the mirror — closing the
    /// gap where an offline-logged mood synced to the server but never reached
    /// Apple Health. Modelled as closures rather than a direct
    /// `AnyHealthKitWriter` dependency because this file also compiles into the
    /// `HealthLogWidgets` extension target, which does not link the app-only
    /// `Stores/` layer where `AnyHealthKitWriter` lives. The app's composition
    /// root wires these to the writer (self-gated on the user's Apple-Health
    /// sync toggle — no auth → swallowed no-op); the widget + replay tests leave
    /// them `nil`.
    public typealias MoodMirror = @Sendable (MoodEntry) async -> Void
    public typealias MoodMirrorDelete = @Sendable (String) async -> Void
    private let mirrorMood: MoodMirror?
    private let mirrorMoodDelete: MoodMirrorDelete?
    /// v0.12 SP3+SP4 — replay seam for the GLP-1 side-effect logbook + pen
    /// inventory CRUD. Optional so the widget extension + legacy tests that
    /// don't wire it leave it `nil`; an unwired replay of one of those kinds is
    /// dropped as non-retriable so it can't wedge the queue.
    let therapyLogRepo: MedicationTherapyLogRepository?
    /// v0.14.8 cycle marathon — drains the cycle outbox kinds. Optional so
    /// existing callers (tests) compile unchanged; the cycle arm dead-letters
    /// when unwired (matching the `.syncHealthKitSample` posture).
    let cycleRepo: CycleRepository?
    /// v0.14.8 audit Wave A (C4.1) — drains `.uploadWorkoutBatch`. Optional so
    /// existing callers (tests, widget extension) compile unchanged; the arm
    /// dead-letters when unwired so it can never wedge the queue.
    let workoutsRepo: WorkoutsRepository?
    /// W-B187 COACH-3 — drains the coach clarifying-question writes
    /// (adopt / dismiss). Optional so existing callers (tests, widget
    /// extension) compile unchanged; the arm dead-letters when unwired so it
    /// can never wedge the queue.
    let coachAboutMeRepo: CoachAboutMeRepository?
    /// v1.18.6 PHI — drains the labs write kinds (create/update/delete/restore
    /// lab + biomarker). Optional so the widget extension + legacy replay tests
    /// compile unchanged; the arm dead-letters when unwired so it can never wedge
    /// the queue.
    let labsRepo: LabsRepository?
    /// v1.18.6 PHI — drains the illness write kinds (create/update/delete/restore
    /// /resolve episode + day-log upsert). Optional (same posture as `labsRepo`).
    /// `internal` (not `private`) so the `+LabsIllness` dispatch extension can
    /// read it (the dispatch arms live there for `type_body_length` discipline).
    let illnessRepo: IllnessRepository?
    /// v1.25 PHI — drains the structured-records write kinds (create/update/delete
    /// allergy + family-history). Optional (same posture as `labsRepo`); the
    /// `+Records` dispatch extension reads these, so they are `internal`.
    let allergiesRepo: AllergiesRepository?
    let familyHistoryRepo: FamilyHistoryRepository?
    /// v1.25 PHI — drains the mental-health screener submit kind
    /// (`createMentalHealthAssessment`). Optional (same posture as `labsRepo`);
    /// the `+MentalHealth` dispatch extension reads it, so it is `internal`.
    let mentalHealthRepo: MentalHealthRepository?
    /// Drains the six custom-metric write kinds (definition + logged-value
    /// create/update/delete). Optional (same posture as `labsRepo`); the
    /// `+CustomMetrics` dispatch extension reads it, so it is `internal`.
    let customMetricsRepo: CustomMetricsRepository?
    /// Build 7.6 (GH #48) — drains the `logNutrientWater` quick-add kind.
    /// Optional (same posture as `labsRepo`); the `+Nutrients` dispatch
    /// extension reads it, so it is `internal`.
    let nutrientReadRepo: NutrientReadRepository?
    let decoder: JSONDecoder
    let maxAttempts: Int
    /// **v0.13 WS — cross-user outbox binding.** Resolves the *currently*
    /// signed-in `KeychainKey.userID` at replay time. A row whose stamped
    /// owner differs from this value belongs to a different account (shared
    /// device, User A's queued write surviving into User B's session) and is
    /// dead-lettered instead of replayed under B's bearer token. Defaults to
    /// a live Keychain read; tests inject a deterministic provider.
    private let currentUserProvider: @Sendable () -> String?

    // MARK: - audit-v0162 H1 / H-4 dependencies

    /// Minimum wall-clock age a row must reach BEFORE it is eligible to be
    /// dead-lettered (in addition to `attempts >= maxAttempts`). Default 7 days:
    /// a PHI write is only abandoned once it has been genuinely stuck for a week,
    /// never merely because a transient burst chewed through the attempt budget
    /// in minutes. Injectable so tests can drive the gate deterministically.
    let deadLetterMinAge: TimeInterval

    /// Back-off floor — an op whose `lastAttemptAt` is more recent than this is
    /// skipped this pass, so rapid replay triggers (foreground + reachability
    /// edges firing seconds apart) can't burn several attempts within minutes.
    private let attemptBackoff: TimeInterval

    /// Injectable clock (age + back-off math). Defaults to wall time; tests pin it.
    private let clock: @Sendable () -> Date

    /// **audit-v0162 H1 (Opt 3) — degraded-server signal.** Returns `true` when
    /// the server answered our `/api/health` probe but reported `degraded`
    /// (confirmed-reachable-but-unhealthy). A 5xx/429 replay failure under this
    /// condition is the server's fault, not the write's, so the attempt is NOT
    /// counted toward dead-lettering. Wired to a shared ``ServerHealthSignal`` in
    /// the composition root (post-construction via ``attachHealthSignal(_:)``);
    /// `nil` (tests / widget) reads as "not degraded".
    private var serverHealthDegraded: (@Sendable () async -> Bool)?

    /// **audit-v0162 H1 (Opt 2) — honest DLQ signal.** Invoked with the count of
    /// rows NEWLY dead-lettered in a pass so the sync footer can surface
    /// "N Einträge konnten nicht übermittelt werden" instead of a false
    /// drained-success beat. Wired to `SyncStateStore.noteDeadLettered` via
    /// ``attachDeadLetterSink(_:)`` (the store is built after this service).
    var onDeadLettered: (@Sendable (Int) async -> Void)?

    /// Phase 09 / plan 09-05 — rows dead-lettered by a pass that ran before any
    /// sink was attached. `internal`, like `measurementsRepo` above, so the
    /// `+DeadLetterSink.swift` sibling that owns the whole surface can reach it.
    var deadLetteredBeforeSink = 0

    /// **audit-v0162 H-4 — in-pass optimistic→server id remap.** Populated when a
    /// queued `create` replays and the server assigns a real id; a dependent
    /// `update`/`delete` on the same optimistic id (same pass) is retargeted
    /// through it. Cleared at the start of every pass; cross-pass persistence is
    /// carried by the on-disk `clientEntityId` column (see `applyEntityRemap`).
    var idRemap: [String: String] = [:]

    /// Server id returned by the most recent `create` dispatch (or `nil`). The
    /// records/labs create arms (in the `+Records` / `+LabsIllness` extensions)
    /// write it; `runOnce` reads it to drive the H-4 remap. Reset before each
    /// `dispatch`. `internal` so the cross-file dispatch extensions can set it.
    var lastCreatedServerId: String?

    private var isRunning = false

    public init(
        outbox: OutboxQueue,
        measurementsRepo: MeasurementsRepository,
        moodRepo: MoodRepository,
        medicationsRepo: MedicationsRepository,
        userThresholdsRepo: UserThresholdsRepository? = nil,
        insightsLayoutRepo: InsightsLayoutRepository? = nil,
        mirrorMood: MoodMirror? = nil,
        mirrorMoodDelete: MoodMirrorDelete? = nil,
        therapyLogRepo: MedicationTherapyLogRepository? = nil,
        cycleRepo: CycleRepository? = nil,
        workoutsRepo: WorkoutsRepository? = nil,
        coachAboutMeRepo: CoachAboutMeRepository? = nil,
        labsRepo: LabsRepository? = nil,
        illnessRepo: IllnessRepository? = nil,
        allergiesRepo: AllergiesRepository? = nil,
        familyHistoryRepo: FamilyHistoryRepository? = nil,
        mentalHealthRepo: MentalHealthRepository? = nil,
        customMetricsRepo: CustomMetricsRepository? = nil,
        nutrientReadRepo: NutrientReadRepository? = nil,
        currentUserProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultOwnerProvider,
        maxAttempts: Int = 8,
        deadLetterMinAge: TimeInterval = 7 * 24 * 60 * 60,
        attemptBackoff: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init,
        serverHealthDegraded: (@Sendable () async -> Bool)? = nil,
        onDeadLettered: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.outbox = outbox
        self.measurementsRepo = measurementsRepo
        self.moodRepo = moodRepo
        self.medicationsRepo = medicationsRepo
        self.userThresholdsRepo = userThresholdsRepo
        self.insightsLayoutRepo = insightsLayoutRepo
        self.mirrorMood = mirrorMood
        self.mirrorMoodDelete = mirrorMoodDelete
        self.therapyLogRepo = therapyLogRepo
        self.cycleRepo = cycleRepo
        self.workoutsRepo = workoutsRepo
        self.coachAboutMeRepo = coachAboutMeRepo
        self.labsRepo = labsRepo
        self.illnessRepo = illnessRepo
        self.allergiesRepo = allergiesRepo
        self.familyHistoryRepo = familyHistoryRepo
        self.mentalHealthRepo = mentalHealthRepo
        self.customMetricsRepo = customMetricsRepo
        self.nutrientReadRepo = nutrientReadRepo
        self.currentUserProvider = currentUserProvider
        self.maxAttempts = maxAttempts
        self.deadLetterMinAge = deadLetterMinAge
        self.attemptBackoff = attemptBackoff
        self.clock = clock
        self.serverHealthDegraded = serverHealthDegraded
        self.onDeadLettered = onDeadLettered
        // Single source of truth: `JSONDecoder.hlDefault`. Vorher hatte der
        // Replay-Service eine eigene Strategie (`.iso8601` ohne fractional +
        // `.convertFromSnakeCase`) — ein latenter Footgun (Outbox-Payload wird
        // von iOS selbst encoded, also no-op heute, aber ein Encoder-Change
        // haette ein silent break verursacht). A4-Audit §6.
        decoder = .hlDefault
    }

    /// Composition-root wiring — attach the shared degraded-server signal after
    /// construction (the service is built before the ``ServerHealthSignal`` probe
    /// is set up). Idempotent.
    public func attachHealthSignal(_ degraded: @escaping @Sendable () async -> Bool) {
        serverHealthDegraded = degraded
    }

    /// One pass over the outbox. Re-entrant-safe via `isRunning`-Guard.
    public func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let snapshot = await outbox.snapshot
        guard !snapshot.isEmpty else { return }

        HLLog.outbox.info("Outbox-Replay startet (\(snapshot.count, privacy: .public) Operations)")

        // v0.13 WS — resolve the currently signed-in user ONCE per pass so a
        // foreign-owned row is never replayed under the wrong bearer token.
        let currentUser = currentUserProvider()
        // audit-v0162 H1 (Opt 3) — is the server confirmed-reachable but degraded?
        let degraded = await serverHealthDegraded?() ?? false
        let now = clock()
        idRemap.removeAll()
        // audit-v0162 M2 — entity ids whose earlier op failed retriably THIS
        // pass. A later update/delete on the same entity is SKIPPED (not
        // attempted → never 404-dropped) so a dependent write can never fire
        // before its create lands. Keyed on `clientEntityId`, which a create and
        // its dependents all share while the create is still offline.
        var blockedEntities: Set<String> = []

        for op in snapshot {
            // Phase 07 — quarantine gate, ahead of every other decision. Two
            // on-disk shapes cannot be attributed by this build: a row with no
            // recorded owner while a named account is signed in, and a row whose
            // `kindRaw` this build cannot name. Both are health writes whose
            // owner or meaning is unknown, so both are retained untouched:
            // never transmitted under the ambient account, never deleted, never
            // re-stamped. The row stays in the snapshot so it remains
            // inspectable, and it is skipped every pass until a build (or an
            // account) can attribute it. See `OutboxQueue+HealthKit.swift`.
            if let reason = op.quarantineReason(currentUserID: currentUser) {
                // Kind and reason are finite operator-grade vocabulary; no
                // owner id, no payload, no idempotency key.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.warning(
                    "Op \(op.kind.rawValue, privacy: .public) quarantined (\(reason.rawValue, privacy: .public)) — retained, not transmitted"
                )
                continue
            }

            // v0.13 WS — cross-user binding gate. A row carries the user-id that
            // owned it at enqueue. On a shared device, User A's queued write can
            // survive A's sign-out (the `.userInitiated`/`.tokenExpired` paths
            // KEEP the outbox + cipher key), so when User B signs in the replay
            // loop would otherwise POST A's health data under B's token. Skip +
            // dead-letter any row whose owner doesn't match the current user.
            // Build 273 (sync audit A11) — RETAIN, never delete. The row is
            // another user's health write; it replays when that user signs in
            // again and is invisible to everyone else meanwhile. Deleting it
            // here (the pre-273 behaviour, logged as "dead-lettered") destroyed
            // User A's queued writes the moment User B signed in.
            if let owner = op.ownerUserID, owner != currentUser {
                HLLog.outbox.warning(
                    "Op \(op.kind.rawValue, privacy: .public) owner-mismatch — retained for its owner, not transmitted"
                )
                continue
            }

            // Over budget → leave for the age-gated dead-letter sweep below
            // (never delete here; the write stays recoverable).
            if op.attempts >= maxAttempts { continue }

            // audit-v0162 H1 (Opt 3) — back-off: don't burn multiple attempts
            // within minutes across rapid replay triggers.
            if let last = op.lastAttemptAt, now.timeIntervalSince(last) < attemptBackoff { continue }

            // audit-v0162 M2 — dependent-op guard: an earlier op for this entity
            // failed retriably this pass, so skip its dependents entirely.
            if let key = op.clientEntityId, blockedEntities.contains(key) { continue }

            do {
                lastCreatedServerId = nil
                try await dispatch(op)
                await onReplaySuccess(op)
            } catch let err as HLError where err.shouldPersistToOutbox {
                // audit-v0162 M2 — block dependents of this entity for the pass.
                if let key = op.clientEntityId { blockedEntities.insert(key) }
                await onRetriableFailure(op, err: err, degraded: degraded)
            } catch {
                await onNonRetriable(op, error: error)
            }
        }

        await sweepDeadLetters(now: now)
    }

    /// **audit-v0162 H-4 — resolve the entity id to actually send.** Prefers an
    /// in-pass remap (the create landed earlier this same pass), then a persisted
    /// column remap (the create landed in an earlier pass and rewrote this row's
    /// `clientEntityId` to the server id), else the payload id verbatim.
    /// `internal` so the `+Records` / `+LabsIllness` dispatch arms can call it.
    func resolveEntityId(_ payloadId: String, op: OutboxQueue.Operation) -> String {
        if let mapped = idRemap[payloadId] { return mapped }
        if let cid = op.clientEntityId, cid != payloadId, !cid.hasPrefix("optimistic-") {
            return cid
        }
        return payloadId
    }

    private func dispatch(_ op: OutboxQueue.Operation) async throws {
        switch op.kind {
        case .createMeasurement,
             .logMood,
             .takeMedication:
            try await dispatchCreatePath(op)
        case .updateMeasurement,
             .deleteMeasurement,
             .bulkDeleteMeasurements,
             .updateMood,
             .deleteMood:
            try await dispatchMeasurementsAndMood(op)
        case .createMedication,
             .updateMedication,
             .deleteMedication,
             .updateIntake,
             .deleteIntake,
             .logMedicationIntake:
            try await dispatchMedications(op)
        case .updateThresholds,
             .updateInsightsLayout:
            try await dispatchUserPreferences(op)
        case .createMedicationSideEffect,
             .deleteMedicationSideEffect,
             .createMedicationInventory,
             .updateMedicationInventory,
             .deleteMedicationInventory:
            try await dispatchTherapyLog(op)
        case .logCycleDayLog,
             .updateCycleDayLog,
             .deleteCycleDayLog,
             .cyclePeriod:
            try await dispatchCycle(op)
        case .uploadWorkoutBatch:
            try await dispatchWorkoutBatch(op)
        case .coachAboutMeAdopt,
             .coachAboutMeDismissQuestion:
            try await dispatchCoachAboutMe(op)
        case .createLab,
             .updateLab,
             .deleteLab,
             .restoreLabs,
             .createBiomarker,
             .updateBiomarker,
             .deleteBiomarker:
            try await dispatchLabs(op)
        case .createIllnessEpisode,
             .updateIllnessEpisode,
             .deleteIllnessEpisode,
             .restoreIllnessEpisode,
             .resolveIllnessEpisode,
             .upsertIllnessDayLog:
            try await dispatchIllness(op)
        case .createAllergy,
             .updateAllergy,
             .deleteAllergy,
             .createFamilyHistory,
             .updateFamilyHistory,
             .deleteFamilyHistory:
            try await dispatchRecords(op)
        case .createMentalHealthAssessment:
            try await dispatchMentalHealth(op)
        case .createCustomMetric,
             .updateCustomMetric,
             .deleteCustomMetric,
             .createCustomMetricEntry,
             .updateCustomMetricEntry,
             .deleteCustomMetricEntry:
            try await dispatchCustomMetrics(op)
        case .logNutrientWater:
            try await dispatchNutrients(op)
        case .syncHealthKitSample:
            // Phase 07 — operational. Re-POSTs the persisted measurement batch
            // under the row's own owner lease and its own idempotency key; a
            // response that does not prove exact per-index acceptance stays
            // retryable. See `OutboxReplayService+HealthKit.swift`.
            try await dispatchHealthKitBatch(op)
        case .unrecognized:
            // Unreachable: the quarantine gate in `runOnce` skips this row
            // before dispatch. Kept exhaustive and fail-closed so a future
            // refactor cannot route an unnameable row onto a wire path.
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) ist quarantaeniert und wird nicht repliziert")
        }
    }

    /// Pre-v0.5.x create paths (measurement / mood / take-medication).
    /// These three were the original set; their payload shapes are the
    /// domain models themselves (not wrapped `Payloads.*`).
    private func dispatchCreatePath(_ op: OutboxQueue.Operation) async throws {
        switch op.kind {
        case .createMeasurement:
            let measurement = try decoder.decode(Measurement.self, from: op.payload)
            _ = try await measurementsRepo.replay(measurement, idempotencyKey: op.idempotencyKey)
        case .logMood:
            let entry = try decoder.decode(MoodEntry.self, from: op.payload)
            let saved = try await moodRepo.replay(entry, idempotencyKey: op.idempotencyKey)
            // v0.10.0 W10 M1 — mirror the now-synced offline mood into Apple
            // Health (server id assigned). Self-gated on the user's sync toggle
            // (no auth → swallowed no-op); anti-duped via externalUUID = server
            // id, matching the online `MoodStore.log` write path.
            await mirrorMood?(saved)
        case .takeMedication:
            // The kind covers two distinct payload shapes:
            //   - Legacy `IntakeUpdate` (per-intake POST via /api/medications/intake)
            //   - v0.5.3 F-4 `ReminderIntake` (bulk POST via
            //     /api/medications/intake/bulk, used by the notification
            //     action handler when no intakeId is known)
            // Try the legacy shape first to preserve replay behaviour for
            // operations already on the outbox; on failure fall back to
            // the reminder-driven shape. Both shapes are flat JSON, so a
            // mis-decode raises a `keyNotFound` (intakeId vs entry) that
            // discriminates cleanly.
            if let body = try? decoder.decode(MedicationsRepository.IntakeUpdate.self, from: op.payload) {
                _ = try await medicationsRepo.replay(body, idempotencyKey: op.idempotencyKey)
            } else {
                let envelope = try decoder.decode(OutboxQueue.Payloads.ReminderIntake.self, from: op.payload)
                try await medicationsRepo.replayReminderIntake(
                    entry: envelope.entry,
                    idempotencyKey: op.idempotencyKey
                )
            }
        default:
            // Compiler-exhaustive switch elsewhere already filters; the assert
            // catches a future Kind being routed here by mistake.
            throw HLError.unknown("dispatchCreatePath received unexpected kind \(op.kind.rawValue)")
        }
    }

    /// v0.5.x edit/delete paths for measurement + mood.
    private func dispatchMeasurementsAndMood(_ op: OutboxQueue.Operation) async throws {
        switch op.kind {
        case .updateMeasurement:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateMeasurement.self, from: op.payload)
            _ = try await measurementsRepo.replayUpdate(
                id: p.id,
                patch: p.patch,
                kind: p.kind,
                idempotencyKey: op.idempotencyKey,
                diastolicId: p.diastolicId,
                diastolicValue: p.diastolicValue,
                glucoseContext: p.glucoseContext
            )
        case .deleteMeasurement:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteMeasurement.self, from: op.payload)
            try await measurementsRepo.replayDelete(id: p.id, idempotencyKey: op.idempotencyKey)
        case .bulkDeleteMeasurements:
            // v0.14.8 W3 — re-POSTs one ≤200-id chunk under the persisted key.
            // Tombstone-idempotent server-side, so a replay after the original
            // actually landed is a silent no-op.
            let p = try decoder.decode(OutboxQueue.Payloads.BulkDeleteMeasurements.self, from: op.payload)
            _ = try await measurementsRepo.replayBulkDelete(ids: p.ids, idempotencyKey: op.idempotencyKey)
        case .updateMood:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateMood.self, from: op.payload)
            let saved = try await moodRepo.replayUpdate(id: p.id, patch: p.patch, idempotencyKey: op.idempotencyKey)
            // v0.10.0 W10 M1 — mirror the edit into Apple Health too (re-save of
            // the same externalUUID = update). Self-gated on the sync toggle.
            await mirrorMood?(saved)
        case .deleteMood:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteMood.self, from: op.payload)
            try await moodRepo.replayDelete(id: p.id, idempotencyKey: op.idempotencyKey)
            // v0.10.0 W10 M1 — delete the mirrored HK sample so a mood deleted
            // offline doesn't linger in Apple Health once the delete syncs.
            await mirrorMoodDelete?(p.id)
        default:
            throw HLError.unknown("dispatchMeasurementsAndMood received unexpected kind \(op.kind.rawValue)")
        }
    }

    /// v0.5.x CRUD paths for medications + intakes.
    private func dispatchMedications(_ op: OutboxQueue.Operation) async throws {
        switch op.kind {
        case .createMedication:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateMedication.self, from: op.payload)
            _ = try await medicationsRepo.replayCreate(p.body, idempotencyKey: op.idempotencyKey)
        case .updateMedication:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateMedication.self, from: op.payload)
            _ = try await medicationsRepo.replayUpdate(id: p.id, patch: p.patch, idempotencyKey: op.idempotencyKey)
        case .deleteMedication:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteMedication.self, from: op.payload)
            try await medicationsRepo.replayDelete(id: p.id, idempotencyKey: op.idempotencyKey)
        case .updateIntake:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateIntake.self, from: op.payload)
            _ = try await medicationsRepo.replayUpdateIntake(
                medicationId: p.medicationId,
                eventId: p.eventId,
                patch: p.patch,
                idempotencyKey: op.idempotencyKey
            )
        case .deleteIntake:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteIntake.self, from: op.payload)
            try await medicationsRepo.replayDeleteIntake(
                medicationId: p.medicationId,
                eventId: p.eventId,
                idempotencyKey: op.idempotencyKey
            )
        case .logMedicationIntake:
            // Build 6.1 — re-POST the free/back-dated intake body under the
            // persisted idempotency key; server dedup folds a replay that
            // already landed.
            let p = try decoder.decode(OutboxQueue.Payloads.LogMedicationIntake.self, from: op.payload)
            _ = try await medicationsRepo.replayLogIntake(
                medicationId: p.medicationId,
                body: p.body,
                idempotencyKey: op.idempotencyKey
            )
        default:
            throw HLError.unknown("dispatchMedications received unexpected kind \(op.kind.rawValue)")
        }
    }

    /// The two server-first user-preference writes share one dispatch arm so the
    /// top-level `dispatch` switch stays inside its complexity budget after
    /// Phase 07 added the fail-closed `.unrecognized` arm. Behaviour-identical:
    /// each kind still reaches exactly the handler it always did.
    private func dispatchUserPreferences(_ op: OutboxQueue.Operation) async throws {
        switch op.kind {
        case .updateThresholds:
            try await dispatchThresholds(op)
        case .updateInsightsLayout:
            try await dispatchInsightsLayout(op)
        default:
            throw HLError.unknown("dispatchUserPreferences received unexpected kind \(op.kind.rawValue)")
        }
    }

    /// v0.7.1 W-TARGETS-EDITOR — replay path for `updateThresholds`. Re-issues
    /// `PUT /api/user/thresholds` with the persisted idempotency key so the
    /// server dedupes a write that may already have landed before app-kill.
    /// When the repo is unwired (tests / legacy call sites) the op is dropped
    /// as non-retriable so it can't wedge the queue.
    private func dispatchThresholds(_ op: OutboxQueue.Operation) async throws {
        guard let userThresholdsRepo else {
            throw HLError.unknown("updateThresholds replay skipped — repo not wired")
        }
        let p = try decoder.decode(OutboxQueue.Payloads.UpdateThresholds.self, from: op.payload)
        _ = try await userThresholdsRepo.replayUpdate(p.patch, idempotencyKey: op.idempotencyKey)
    }

    /// v0.8.0 W10 — replay path for `updateInsightsLayout`. Re-issues
    /// `PUT /api/insights/layout` with the persisted idempotency key so the
    /// server dedupes a write that may already have landed before app-kill.
    /// When the repo is unwired (tests / legacy call sites) the op is dropped
    /// as non-retriable so it can't wedge the queue.
    private func dispatchInsightsLayout(_ op: OutboxQueue.Operation) async throws {
        guard let insightsLayoutRepo else {
            throw HLError.unknown("updateInsightsLayout replay skipped — repo not wired")
        }
        let p = try decoder.decode(OutboxQueue.Payloads.UpdateInsightsLayout.self, from: op.payload)
        _ = try await insightsLayoutRepo.replayUpdate(p.layout, idempotencyKey: op.idempotencyKey)
    }
}
