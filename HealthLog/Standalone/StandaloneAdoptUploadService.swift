import Foundation

// v0.11 W4 — Adopt-on-pair upload.
//
// When a STANDALONE user pairs (points the app at a server + logs in →
// `SyncMode` flips `.standalone → .paired`), the locally-accumulated manual
// rows must move to the server so nothing is lost — "use offline now, join
// later, your history comes with you." This is a ONE-WAY historical backfill
// over the EXISTING idempotent batch endpoints, externalId-keyed (no new
// endpoint), so a re-run / partial-failure retry is a no-op.
//
// **Where it fits:** `AuthStore` detects the standalone→paired transition
// (only when the prior mode was standalone — a normal paired login does NOT
// trigger it) and runs this service, surfacing a calm `adoptUploadState` the
// UI can show a quiet "moving your data over…" indicator from.
//
// **Idempotency contract (per server routes, verified):**
// - Measurements → `POST /api/measurements/batch` with `source: MANUAL`. Dedup
//   key is `(userId, type, source, externalId)`; the local `externalId` is the
//   stable identity, so a re-run surfaces `duplicate` per entry.
// - Mood → `POST /api/mood-entries/bulk` (externalId-keyed UPSERT).
// - Medication intakes → first ensure a server med per distinct local med
//   (client-side dedup by `(name, dose)` against the server's existing meds, so
//   a re-run reuses rather than duplicates — see `resolveMedicationPlan`),
//   capture the server id, remap local intakes' `medicationId` → server id, then
//   `POST /api/medications/intake/bulk` with the local `externalId` as the
//   per-entry `idempotencyKey` (server UNIQUE column → re-run dedups).
//
// **The local mirror is KEPT after upload** — it's the offline cache, and an
// idempotent re-run depends on it. Deletion is a later concern.

/// Supplies the medication DEFINITION (`MedicationCreate` wire body) for a
/// local medication id so the adopt-on-pair upload can create the server-side
/// medication before remapping its intakes. The standalone medication-definition
/// store is a later W2 follow-up; until it lands the composition-root resolves
/// definitions from whatever in-memory snapshot it holds (or returns `nil`,
/// in which case that medication's intakes are skipped — never fabricated).
public protocol AdoptMedicationDefinitionProviding: Sendable {
    /// The create-body for a local medication id, or `nil` when no definition is
    /// available (the intakes referencing it are then skipped with a logged
    /// warning rather than uploaded against a fabricated medication).
    func medicationDefinition(forLocalId localId: String) async -> MedicationsRepository.MedicationCreate?
}

/// Calm, observable progress the UI reflects. Sendable so it can cross the
/// actor boundary up to the `@MainActor` `AuthStore` that publishes it.
public struct AdoptUploadProgress: Sendable, Equatable {
    /// Rows confirmed by the server (inserted + duplicate + updated — all three
    /// mean "the server has it"). Drives a quiet progress affordance.
    public let completed: Int
    /// Total local rows the upload set out to move (measurements + moods +
    /// intakes that resolved to a server medication).
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// `0...1`, clamped. `1` when there was nothing to upload (vacuously done).
    public var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Recoverable failure surfaced when a chunk POST fails irrecoverably. The
/// idempotent retry re-runs the whole bundle safely (every prior row dedups),
/// so the caller can simply re-invoke `run(bundle:)` on the next reachability.
public enum AdoptUploadError: Error, Sendable, Equatable {
    /// A batch POST failed; `phase` names the surface for the (sanitized) log.
    /// `completed`/`total` carry the progress reached so the UI can show how far
    /// the move got before stalling.
    case chunkFailed(phase: String, completed: Int, total: Int)
}

public actor StandaloneAdoptUploadService {
    /// Rows per request. The server caps batches at 500 and rate-limits to
    /// 60 batches/min/user; 200 keeps us well under the size cap (the coord
    /// note flags this) while keeping the request count low for a typical
    /// weeks-of-history backfill.
    public static let chunkSize = 200

    private let api: APIClientProtocol
    private let medicationProvider: AdoptMedicationDefinitionProviding
    private let measurementEncoder: JSONEncoder

    /// - Parameters:
    ///   - api: the live `APIClient` (already pointed at the paired server with a
    ///     valid bearer by the time this runs).
    ///   - medicationProvider: resolves local medication ids → create-bodies.
    public init(
        api: APIClientProtocol,
        medicationProvider: AdoptMedicationDefinitionProviding
    ) {
        self.api = api
        self.medicationProvider = medicationProvider
        // Mirror `JSONEncoder.hlBatch` — the measurements batch route expects
        // ISO-8601 timestamps WITH offset.
        measurementEncoder = .hlBatch
    }

    /// Reports incremental progress as each surface completes. The actor calls
    /// it on its own executor; the closure is `@Sendable` so it can hop to
    /// `@MainActor`. Optional — the terminal `run` return already carries the
    /// final tally.
    public typealias ProgressHandler = @Sendable (AdoptUploadProgress) async -> Void

    /// Uploads every local row in `bundle`. Returns the final progress tally.
    /// Idempotent: a re-run (after a partial failure or a duplicate trigger) is
    /// a server-side no-op because every row carries its stable externalId.
    ///
    /// Throws `AdoptUploadError.chunkFailed` on an irrecoverable chunk POST so
    /// the caller can re-schedule; everything uploaded before the failing chunk
    /// is already durable server-side.
    @discardableResult
    public func run(
        bundle: LocalBackfillBundle,
        onProgress: ProgressHandler? = nil
    ) async throws -> AdoptUploadProgress {
        // Resolve medication definitions up front so the total reflects only the
        // intakes that will actually upload (those whose medication we can
        // create). Intakes for an unresolvable medication are skipped — logged,
        // never fabricated. v0.13 W5: also seed the create-set from the bundle's
        // own medication definitions so a med with NO intakes still moves over.
        let medicationPlan = await resolveMedicationPlan(
            intakes: bundle.intakes,
            definitions: bundle.medications
        )

        let total = bundle.measurements.count
            + bundle.moods.count
            + medicationPlan.uploadableIntakes.count
        var completed = 0

        if total == 0 {
            HLLog.outbox.info("Adopt-on-pair: nothing local to upload.")
            let done = AdoptUploadProgress(completed: 0, total: 0)
            await onProgress?(done)
            return done
        }

        let mCount = bundle.measurements.count
        let moCount = bundle.moods.count
        let iCount = medicationPlan.uploadableIntakes.count
        let medCount = medicationPlan.localToServerId.count
        // Pure row counts — operator-grade, no PII.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info(
            "Adopt-on-pair: uploading \(mCount, privacy: .public) measurements, \(moCount, privacy: .public) moods, \(iCount, privacy: .public) intakes / \(medCount, privacy: .public) meds."
        )

        // 1) Measurements → /api/measurements/batch (source: MANUAL).
        completed += try await uploadMeasurements(
            bundle.measurements,
            completed: completed,
            total: total,
            onProgress: onProgress
        )

        // 2) Mood → /api/mood-entries/bulk (externalId UPSERT).
        completed += try await uploadMoods(
            bundle.moods,
            completed: completed,
            total: total,
            onProgress: onProgress
        )

        // 3) Intakes → /api/medications/intake/bulk (remapped to server med ids).
        completed += try await uploadIntakes(
            medicationPlan.uploadableIntakes,
            localToServerId: medicationPlan.localToServerId,
            completed: completed,
            total: total,
            onProgress: onProgress
        )

        let done = AdoptUploadProgress(completed: completed, total: total)
        await onProgress?(done)
        // Pure row counts — operator-grade, no PII.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("Adopt-on-pair: upload complete (\(completed, privacy: .public)/\(total, privacy: .public)).")
        return done
    }

    // MARK: - Measurements

    private func uploadMeasurements(
        _ rows: [LocalMeasurementSnapshot],
        completed: Int,
        total: Int,
        onProgress: ProgressHandler?
    ) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        // Project to batch entries; rows whose kind the server can't ingest map
        // to `[]` (logged) and BP fans out to two legs (sys + dia) sharing the
        // externalId. The request only carries mappable entries.
        var entries: [HealthKitBatchEntryDTO] = []
        var droppedRows = 0
        for row in rows {
            let projected = StandaloneMeasurementBatchProjection.entries(from: row)
            if projected.isEmpty { droppedRows += 1 }
            entries.append(contentsOf: projected)
        }
        if droppedRows > 0 {
            // Pure row count — operator-grade, no PII.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.warning("Adopt-on-pair: \(droppedRows, privacy: .public) measurement(s) skipped (kind not server-ingestable).")
        }
        var localDone = 0
        for chunk in entries.chunks(of: Self.chunkSize) {
            // CU-21 (1) — Adopt-on-pair ist ein vom Nutzer ausgelöster Import
            // bei geöffneter App; der ambiente Kontext liefert hier `foreground`.
            let payload = HealthKitBatchPayload(entries: chunk, syncTrigger: SyncTriggerContext.shared.current)
            do {
                let req: APIRequest<HealthKitBatchResponseDTO> = try .post(
                    "/api/measurements/batch",
                    body: payload,
                    encoder: measurementEncoder,
                    idempotencyKey: IdempotencyKey()
                )
                _ = try await api.send(req)
            } catch {
                HLLog.outbox.error("Adopt-on-pair measurements chunk failed: \(LogSanitizer.redact(String(describing: error)))")
                throw AdoptUploadError.chunkFailed(phase: "measurements", completed: completed + localDone, total: total)
            }
            localDone += chunk.count
            await onProgress?(AdoptUploadProgress(completed: completed + localDone, total: total))
        }
        // Count the dropped rows toward "completed" so the progress bar reaches
        // its total — they are intentionally-skipped, not pending.
        return rows.count
    }

    // MARK: - Mood

    private func uploadMoods(
        _ rows: [LocalMoodSnapshot],
        completed: Int,
        total: Int,
        onProgress: ProgressHandler?
    ) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let entries = rows.map { snap in
            BulkMoodEntryDTO(
                mood: ServerMoodLevel(score: snap.score).rawValue,
                tags: snap.tags.isEmpty ? nil : snap.tags,
                tagKeys: snap.tagKeys.isEmpty ? nil : snap.tagKeys,
                note: snap.note,
                moodLoggedAt: snap.recordedAt,
                source: "MANUAL",
                externalId: snap.externalId
            )
        }
        var localDone = 0
        for chunk in entries.chunks(of: Self.chunkSize) {
            let payload = BulkMoodPayload(entries: chunk)
            do {
                let req: APIRequest<BulkUpsertResponseDTO> = try .post(
                    "/api/mood-entries/bulk",
                    body: payload,
                    encoder: measurementEncoder,
                    idempotencyKey: IdempotencyKey()
                )
                _ = try await api.send(req)
            } catch {
                HLLog.outbox.error("Adopt-on-pair mood chunk failed: \(LogSanitizer.redact(String(describing: error)))")
                throw AdoptUploadError.chunkFailed(phase: "mood", completed: completed + localDone, total: total)
            }
            localDone += chunk.count
            await onProgress?(AdoptUploadProgress(completed: completed + localDone, total: total))
        }
        return rows.count
    }

    // MARK: - Intakes

    /// The resolved upload set for medication intakes: the create-mapped local→
    /// server ids plus exactly the intakes whose medication resolved.
    private struct MedicationPlan {
        let localToServerId: [String: String]
        let uploadableIntakes: [LocalIntakeSnapshot]
    }

    /// Creates a server medication for each distinct local medication id present
    /// in `intakes`, building the local→server id map. A local id that has no
    /// resolvable definition (provider returns `nil`) is left out of the map and
    /// its intakes are excluded from the uploadable set.
    ///
    /// **Idempotent client-side (v0.13 WR).** The create endpoint has no
    /// `externalId` dedup, so a naive re-run after a partial failure would spawn
    /// duplicate server medications. To make the adopt-on-pair upload safely
    /// re-runnable, we FETCH the server's existing medications once up front and
    /// match each local definition against them by its user-meaningful identity
    /// `(name, dose)` (trimmed, case-insensitive). A match → reuse the existing
    /// server id, skip the POST. Only genuinely-new medications are created. So a
    /// retry after a `chunkFailed` re-maps to the meds the prior run already
    /// created instead of orphaning them, and the intake bulk (which dedups on
    /// `idempotencyKey`) finishes the move.
    private func resolveMedicationPlan(
        intakes: [LocalIntakeSnapshot],
        definitions: [LocalMedicationSnapshot] = []
    ) async -> MedicationPlan {
        // Distinct local ids = every medication referenced by an intake PLUS
        // every bundled definition (so a med with no intakes still uploads).
        let distinctLocalIds = Array(
            Set(intakes.map(\.medicationId)).union(definitions.map(\.externalId))
        )
        guard !distinctLocalIds.isEmpty else {
            return MedicationPlan(localToServerId: [:], uploadableIntakes: [])
        }

        // Idempotency pre-check: index the server's existing meds by their
        // `(name, dose)` identity so a re-run matches instead of duplicating.
        // A fetch failure is non-fatal — we degrade to create-only (the prior
        // behaviour); the index stays empty and nothing matches.
        var existingByIdentity: [String: String] = [:]
        do {
            let req: APIRequest<[MedicationWireDTO]> = .get("/api/medications")
            let existing = try await api.send(req)
            for wire in existing {
                existingByIdentity[Self.identityKey(name: wire.name, dose: wire.dose)] = wire.id
            }
        } catch {
            HLLog.outbox.warning(
                "Adopt-on-pair: existing-meds fetch failed — proceeding create-only (re-runs may duplicate): \(LogSanitizer.redact(String(describing: error)))"
            )
        }

        var map: [String: String] = [:]
        for localId in distinctLocalIds {
            guard let create = await medicationProvider.medicationDefinition(forLocalId: localId) else {
                HLLog.outbox.warning("Adopt-on-pair: no definition for a local medication — its intakes are skipped.")
                continue
            }
            // Already on the server (this is a re-run, or the user created the
            // same med server-side) → reuse its id, never POST a duplicate.
            let identity = Self.identityKey(name: create.name, dose: create.dose)
            if let serverId = existingByIdentity[identity] {
                map[localId] = serverId
                continue
            }
            do {
                let req: APIRequest<MedicationWireDTO> = try .post(
                    "/api/medications",
                    body: create,
                    idempotencyKey: IdempotencyKey()
                )
                let wire = try await api.send(req)
                map[localId] = wire.toDomain().id
                // Index the freshly-created med so two local defs that collapse
                // to the same identity in this same run don't double-create.
                existingByIdentity[identity] = wire.toDomain().id
            } catch {
                HLLog.outbox.error("Adopt-on-pair medication create failed: \(LogSanitizer.redact(String(describing: error)))")
                // Leave it unmapped — its intakes are skipped this run; a later
                // re-run retries the create. We do NOT throw here: a single
                // medication failing shouldn't block measurements/mood, which
                // already uploaded.
            }
        }
        let uploadable = intakes.filter { map[$0.medicationId] != nil }
        return MedicationPlan(localToServerId: map, uploadableIntakes: uploadable)
    }

    /// The user-meaningful dedup identity for a medication: trimmed,
    /// case-/diacritic-insensitive `name|dose`. Used to match a local definition
    /// against the server's existing meds so an adopt re-run never duplicates.
    static func identityKey(name: String, dose: String) -> String {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return "\(norm(name))|\(norm(dose))"
    }

    private func uploadIntakes(
        _ rows: [LocalIntakeSnapshot],
        localToServerId: [String: String],
        completed: Int,
        total: Int,
        onProgress: ProgressHandler?
    ) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let entries: [BulkIntakeEntryDTO] = rows.compactMap { snap in
            guard let serverId = localToServerId[snap.medicationId] else { return nil }
            let status = IntakeStatus(rawValue: snap.status) ?? .taken
            let skipped = status == .skipped
            // A taken dose carries `takenAt`; a skip omits it + sets skipped.
            // A pending/snoozed historical row backfills as a scheduled slot
            // without a takenAt (the server's canonical-slot upsert places it).
            return BulkIntakeEntryDTO(
                medicationId: serverId,
                scheduledFor: snap.takenAt,
                takenAt: status == .taken ? snap.takenAt : nil,
                skipped: skipped,
                idempotencyKey: snap.externalId,
                // v0.13 WP — a site rides only a taken dose (server gate parity).
                injectionSite: status == .taken ? snap.injectionSite : nil
            )
        }
        var localDone = 0
        for chunk in entries.chunks(of: Self.chunkSize) {
            let payload = BulkIntakePayload(entries: chunk)
            do {
                let req: APIRequest<BulkUpsertResponseDTO> = try .post(
                    "/api/medications/intake/bulk",
                    body: payload,
                    encoder: measurementEncoder,
                    idempotencyKey: IdempotencyKey()
                )
                _ = try await api.send(req)
            } catch {
                HLLog.outbox.error("Adopt-on-pair intake chunk failed: \(LogSanitizer.redact(String(describing: error)))")
                throw AdoptUploadError.chunkFailed(phase: "intakes", completed: completed + localDone, total: total)
            }
            localDone += chunk.count
            await onProgress?(AdoptUploadProgress(completed: completed + localDone, total: total))
        }
        return rows.count
    }
}

// MARK: - Medication → adopt-create body

public extension Medication {
    /// The minimal `MedicationCreate` body the adopt-on-pair upload posts to
    /// recreate a local-only medication server-side before remapping its
    /// intakes. Carries the definition fields the server's create-schema needs
    /// (name + dose + the delivery/category metadata); `schedules` is omitted —
    /// the backfilled intakes carry their own `scheduledFor`, and the user can
    /// rebuild the reminder schedule on the server afterwards. Keeping the
    /// create lean avoids re-deriving the full schedule wire shape here.
    func toAdoptCreateBody() -> MedicationsRepository.MedicationCreate {
        MedicationsRepository.MedicationCreate(
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            dosesPerUnit: dosesPerUnit,
            category: category,
            active: active,
            notificationsEnabled: notificationsEnabled,
            schedules: nil,
            oneShot: oneShot,
            startsOn: nil,
            endsOn: nil,
            deliveryForm: deliveryForm
        )
    }
}

// MARK: - Local-store-backed definition provider (v0.13 W5)

public extension LocalMedicationSnapshot {
    /// The `MedicationCreate` body the adopt-on-pair upload posts to recreate
    /// this local-only medication server-side before remapping its intakes.
    /// Carries the full persisted `[MedicationScheduleDTO]` so the reminder
    /// schedule survives the move (unlike the lean `Medication.toAdoptCreateBody`
    /// which omits schedules). `notificationsEnabled` + the injection-tracking
    /// flag + the course window are preserved.
    func toAdoptCreateBody() -> MedicationsRepository.MedicationCreate {
        MedicationsRepository.MedicationCreate(
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            dosesPerUnit: dosesPerUnit,
            category: category,
            active: !archived,
            notificationsEnabled: notificationsEnabled,
            schedules: schedules.isEmpty ? nil : schedules,
            oneShot: oneShot,
            startsOn: startsOn.map(LocalMedicationSnapshot.isoDayString),
            endsOn: endsOn.map(LocalMedicationSnapshot.isoDayString),
            deliveryForm: deliveryForm,
            trackInjectionSites: trackInjectionSites
        )
    }

    /// `YYYY-MM-DD` for a course-window `Date` (UTC), matching the server
    /// `@db.Date` boundary the create-schema expects.
    static func isoDayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}

/// `AdoptMedicationDefinitionProviding` backed by the `LocalRepository` medication
/// mirror (v0.13 W5). Resolves a local medication id → its full `MedicationCreate`
/// from the persisted definition (including the archived ones, so an archived
/// med's historical intakes still upload). Replaces the prior in-memory
/// `MedicationsStore`-snapshot closure: the store may be unloaded at pair-time,
/// but the local store is always authoritative.
public struct LocalMedicationDefinitionProvider: AdoptMedicationDefinitionProviding {
    private let local: LocalRepository

    public init(local: LocalRepository) {
        self.local = local
    }

    public func medicationDefinition(forLocalId localId: String) async -> MedicationsRepository.MedicationCreate? {
        do {
            // Include archived: an archived med's intakes are still part of the
            // user's history and must move on pair.
            let snaps = try await local.medications(includeArchived: true)
            return snaps.first { $0.externalId == localId }?.toAdoptCreateBody()
        } catch {
            HLLog.outbox.error("Adopt-on-pair: local med definition lookup failed: \(LogSanitizer.redact(String(describing: error)))")
            return nil
        }
    }
}
