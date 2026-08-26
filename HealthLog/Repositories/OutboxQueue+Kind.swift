import Foundation

// The `OutboxQueue.Operation.Kind` enum, lifted out of the `OutboxQueue` actor
// body (v1.18.6) so the long case list — one per durable write contract — does
// not count against the actor's `type_body_length` budget. Declaring it in an
// extension on `Operation` keeps the fully-qualified name
// (`OutboxQueue.Operation.Kind`) and the `Operation.kind: Kind` reference intact
// while moving every case out of the enclosing type body.

public extension OutboxQueue.Operation {
    /// The durable-write contract a queued `Operation` replays. Stored as the
    /// raw `String` on `OutboxOperation` so the on-disk schema is forward-
    /// compatible with new kinds without a SwiftData migration. Each kind carries
    /// a dedicated `Codable` payload (the domain model itself for the original
    /// three, otherwise a `Payloads.*` struct).
    enum Kind: String, Codable, Sendable {
        case createMeasurement
        case takeMedication
        case logMood
        case syncHealthKitSample
        // v0.5.x edit/delete expansion. Each new kind carries a dedicated
        // Codable payload struct in `OutboxQueue.Payloads`. Server routes
        // (PATCH/PUT/DELETE) are already shipped — iOS was the missing
        // half of the contract (see `.planning/v041-marathon/QA5-edit-delete-coverage.md`).
        case updateMeasurement
        case deleteMeasurement
        case updateMood
        case deleteMood
        case createMedication
        case updateMedication
        case deleteMedication
        case updateIntake
        case deleteIntake
        /// Build 6.1 — free / back-dated intake log via the per-medication
        /// `POST /api/medications/{id}/intake` route. Payload
        /// `Payloads.LogMedicationIntake` (medicationId + the exact wire body).
        /// The persisted idempotency key makes a replay-after-original-landed
        /// duplicate-safe (server `withIdempotency` + the `intake_events`
        /// UNIQUE-key both dedup). Replay drains via `dispatchMedications`.
        case logMedicationIntake
        /// v0.7.1 W-TARGETS-EDITOR — per-user target-range override write.
        /// Server route `PUT /api/user/thresholds` (upsert-merge). Payload
        /// is `Payloads.UpdateThresholds`.
        case updateThresholds
        /// v0.8.0 W10 — server-first Insights tile layout (order +
        /// visibility). Server route `PUT /api/insights/layout`. Payload
        /// is `Payloads.UpdateInsightsLayout`.
        case updateInsightsLayout
        /// v0.12 SP3 — GLP-1 side-effect log create.
        /// `POST /api/medications/[id]/side-effects`.
        /// Payload `Payloads.CreateMedicationSideEffect`.
        case createMedicationSideEffect
        /// v0.12 SP3 — GLP-1 side-effect log delete.
        /// `DELETE /api/medications/[id]/side-effects/[logId]`.
        /// Payload `Payloads.DeleteMedicationSideEffect`.
        case deleteMedicationSideEffect
        /// v0.12 SP4 — pen/vial inventory create.
        /// `POST /api/medications/[id]/inventory`.
        /// Payload `Payloads.CreateMedicationInventory`.
        case createMedicationInventory
        /// v0.12 SP4 — pen/vial inventory update.
        /// `PATCH /api/medications/[id]/inventory/[itemId]`.
        /// Payload `Payloads.UpdateMedicationInventory`.
        case updateMedicationInventory
        /// v0.12 SP4 — pen/vial inventory delete.
        /// `DELETE /api/medications/[id]/inventory/[itemId]`.
        /// Payload `Payloads.DeleteMedicationInventory`.
        case deleteMedicationInventory
        /// v0.14.8 cycle marathon — single cycle day-log create.
        /// Outbox drains via `POST /api/cycle/day-logs/bulk` (one entry).
        /// Payload `Payloads.LogCycleDayLog`. UPSERT-keyed on `externalId`,
        /// last-writer-wins on replay (mood precedent).
        case logCycleDayLog
        /// v0.14.8 — cycle day-log update. `PATCH /api/cycle/day-logs/[id]`.
        /// Payload `Payloads.UpdateCycleDayLog`.
        case updateCycleDayLog
        /// v0.14.8 — cycle day-log soft delete.
        /// `DELETE /api/cycle/day-logs/[id]`. Payload `Payloads.DeleteCycleDayLog`.
        case deleteCycleDayLog
        /// v0.14.8 — one-tap period start/end. `POST /api/cycle/period`.
        /// Payload `Payloads.CyclePeriod`.
        case cyclePeriod
        /// v0.14.8 audit Wave A (C4.1) — HK-sourced workout batch ingest.
        /// `POST /api/workouts/batch`. Payload `Payloads.UploadWorkoutBatch`.
        /// The server's `@@unique([userId, source, externalId])` UPSERT plus
        /// the persisted idempotency key make a replayed batch duplicate-safe.
        case uploadWorkoutBatch
        /// v0.14.8 W3 — multi-select bulk delete (v1.15.13).
        /// `POST /api/measurements/bulk-delete` `{ ids: [≤200] }`. Payload
        /// `Payloads.BulkDeleteMeasurements`. Tombstone-idempotent server-
        /// side (already-deleted ids are silent no-ops), so a replay after
        /// the original actually landed is harmless even past the 24h
        /// idempotency window.
        case bulkDeleteMeasurements
        /// W-B187 COACH-3 — adopt / "remember this" → self-context
        /// (`POST /api/coach/about-me/adopt`; server dedupes the replay).
        case coachAboutMeAdopt
        /// W-B187 COACH-3 — dismiss a pending clarifying question
        /// (`DELETE /api/coach/about-me/questions`; exact-match idempotent).
        case coachAboutMeDismissQuestion
        // v1.18.6 PHI — labs + illness durable writes. Each carries a
        // dedicated Codable payload in `OutboxQueue+LabsIllness.swift`; the
        // persisted idempotency key makes a replay-after-original-landed
        // duplicate-safe (server dedups within 24h, and create routes also
        // UPSERT / soft-delete is tombstone-idempotent). Replay drains via
        // `OutboxReplayService.dispatchLabs` / `.dispatchIllness`.
        case createLab
        case updateLab
        case deleteLab
        case restoreLabs
        case createBiomarker
        case updateBiomarker
        case deleteBiomarker
        case createIllnessEpisode
        case updateIllnessEpisode
        case deleteIllnessEpisode
        case restoreIllnessEpisode
        case resolveIllnessEpisode
        case upsertIllnessDayLog
        // v1.25 PHI — structured-records (allergy + family-history) durable
        // writes. Each carries a dedicated Codable payload in
        // `OutboxQueue+Records.swift`; the persisted idempotency key makes a
        // replay-after-original-landed duplicate-safe (server dedups creates
        // within 24h, PATCH is idempotent, soft-delete is tombstone-idempotent).
        // Replay drains via `OutboxReplayService.dispatchRecords`.
        case createAllergy
        case updateAllergy
        case deleteAllergy
        case createFamilyHistory
        case updateFamilyHistory
        case deleteFamilyHistory
        /// v1.25 PHI — opt-in mental-health screener (PHQ-9 / GAD-7) durable POST.
        /// Carries `Payloads.CreateMentalHealthAssessment`; the persisted
        /// idempotency key makes a replay-after-original-landed duplicate-safe
        /// (server `withIdempotency` dedups within 24h). Replay drains via
        /// `OutboxReplayService.dispatchMentalHealth`. The encoded item answers
        /// (incl. item-9) live ONLY in the encrypted blob until replay.
        case createMentalHealthAssessment
        // Custom metrics — user-defined metric definitions + their logged
        // values. Payloads live in `OutboxQueue+CustomMetrics.swift`; replay
        // drains via `OutboxReplayService.dispatchCustomMetrics`. Only the two
        // POST routes carry server `withIdempotency`; PATCH is same-body-
        // idempotent, the metric DELETE is a tombstone stamp, and the entry
        // DELETE 404s once settled — so every kind is replay-safe.
        case createCustomMetric
        case updateCustomMetric
        case deleteCustomMetric
        case createCustomMetricEntry
        case updateCustomMetricEntry
        case deleteCustomMetricEntry
        /// Build 7.6 (GH #48) — manual water quick-add.
        /// `POST /api/nutrients/water` (MANUAL source row). Payload
        /// `Payloads.LogNutrientWater`. The server's `withIdempotency` on the
        /// route + the persisted idempotency key make a replay-after-original-
        /// landed a no-op, so an offline quick-add can never double-increment the
        /// day total. Replay drains via `OutboxReplayService.dispatchNutrients`.
        case logNutrientWater
        /// **Phase 07 — the forward-compatibility sentinel.** A `kindRaw` this
        /// build cannot name decodes to this case so the dispatcher's switch
        /// stays exhaustive and fail-closed.
        ///
        /// It is never enqueued (`OutboxQueue.persist` refuses it) and never
        /// written back, so the row's real `kindRaw` survives untouched on disk
        /// for the build that understands it. Until then the row is quarantined:
        /// retained, never transmitted, never deleted.
        ///
        /// Before Phase 07 this role was played by `syncHealthKitSample`, which
        /// is now an operational kind with a real replay arm — a sentinel
        /// sharing its identity with a transmitting kind would have posted an
        /// unknown row's payload to `/api/measurements/batch`.
        case unrecognized = "__hl_unrecognized_kind__"
    }
}
