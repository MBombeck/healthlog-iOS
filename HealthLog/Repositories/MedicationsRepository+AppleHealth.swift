import Foundation

/// **GH #47 (server v1.28) — Apple Health medications + dose-event mirror.**
///
/// Two read-only-mirror wire paths, kept off the store's optimistic CRUD +
/// outbox surfaces (the importer is a background HealthKit reconciler, not a
/// user write): a direct medication upsert and the bulk dose-import. The bulk
/// entry type is the existing ``MedicationsRepository/BulkIntakeEntry`` (now
/// carrying the optional `source` + `externalId`); this file adds only the
/// richer per-entry response the importer needs to advance its cursor.
public extension MedicationsRepository {
    // MARK: - Mirror error codes

    /// **Server v1.32.25 — mirror growth cap.** A *new* mirror create is refused
    /// with `422` + `meta.errorCode` once the account already holds 30
    /// medications mirrored from the same `externalSource`. Idempotent re-posts
    /// of an existing mirror and native creates are never gated, so this means
    /// exactly one thing: Apple Health carries more medications than HealthLog
    /// will mirror. It deserves its own explanation, not a generic banner.
    static let mirrorLimitErrorCode = "medications.mirror.limit_exceeded"

    /// Client-minted code for the CU-10 pre-flight refusal in
    /// ``mirrorAppleHealthMedication(_:)``. Not a server code — the server's own
    /// refusal (v1.32.37) rides an untyped `422` "Validation failed" envelope, so
    /// this is the client naming the same condition before it goes on the wire.
    static let unstableExternalIDErrorCode = "medications.mirror.unstable_external_id"

    // MARK: - Medication mirror upsert

    /// Upsert an Apple-Health-mirrored medication via `POST /api/medications`
    /// carrying `externalSource:"APPLE_HEALTH"` + `externalId` (the HK
    /// medication concept id). Idempotent per (user, source, concept): a re-post
    /// returns the EXISTING med (200, full envelope) rather than minting a
    /// duplicate. **That idempotency is the backstop, not the dedup mechanism**
    /// — the importer calls this only for concepts the server does not already
    /// mirror or whose name/form changed (CU-10). Leaning on it alone is what
    /// made a rotating `externalId` cost a live instance 23 phantom rows.
    ///
    /// Returns the server row projected into ``Medication``, with the
    /// Apple-Health provenance stamped locally as a backstop (since v1.32.25 the
    /// medications GET echoes `externalSource` itself).
    ///
    /// **CU-10 pre-flight.** Since v1.32.37 the server refuses an `externalId`
    /// that cannot be a stable identity with a hard `422` naming `externalId`.
    /// That envelope reaches the client as an untyped "Validation failed" — the
    /// transport layer does not surface `details.issues[].path` — so the check
    /// runs here, where the value is still in hand and the refusal can name the
    /// real reason. Throws ``HLError/server(status:code:message:)`` with
    /// ``MedicationsRepository/unstableExternalIDErrorCode``: an honest failure,
    /// never a silent skip that would look like a successful mirror.
    ///
    /// **Phase 07 / plan 07-05.** `idempotencyKey` is now a parameter. The
    /// mirror upsert used to mint a fresh key on every attempt, which made the
    /// replay window structurally unusable: two attempts at the same concept
    /// were two different operations as far as the server's dedup was concerned,
    /// and only the `(user, source, externalId)` uniqueness saved the row. The
    /// importer derives the key from ``HealthSyncRetryEnvelope`` so a relaunch
    /// rebuilds it. `nil` keeps the pre-Phase-07 behaviour for callers that have
    /// no stable identity to derive from.
    func mirrorAppleHealthMedication(
        _ record: AppleHealthMedicationRecord,
        idempotencyKey: String? = nil
    ) async throws -> Medication {
        if let shape = AppleHealthConceptKey.classify(record.externalId) {
            HLLog.healthKit.error(
                "APPLE-MED mirror refused pre-flight — unstable externalId shape=\(shape.rawValue, privacy: .public)"
            )
            throw HLError.server(
                status: 422,
                code: Self.unstableExternalIDErrorCode,
                message: String(localized: "settings.applehealth.medSync.error.unstableExternalId")
            )
        }
        // The server requires a non-empty `dose`. Apple Health does not always
        // carry a strength string on the concept, so a mirrored med falls back
        // to a neutral placeholder (the mirror is read-only; the field is
        // cosmetic and the doses come from HealthKit, not this string).
        let body = MedicationCreate(
            name: record.name,
            dose: record.doseText ?? "—",
            active: !record.isArchived,
            deliveryForm: record.deliveryForm,
            externalSource: IntakeSource.appleHealth.wireValue,
            externalId: record.externalId,
            rxNormCode: record.rxNormCode,
            asNeeded: record.asNeeded
        )
        let req: APIRequest<MedicationWireDTO> = try .post(
            "/api/medications",
            body: body,
            idempotencyKey: idempotencyKey.map(IdempotencyKey.init(raw:)) ?? IdempotencyKey()
        )
        let wire = try await api.send(req)
        // Stamp the provenance we KNOW (server GET/POST don't echo it) so the
        // UI's source-exclusive gate (no manual dose logging) applies at once.
        return wire.toDomain().withAppleHealthProvenance(externalId: record.externalId)
    }

    // MARK: - Bulk dose import

    /// Import Apple-Health dose entries via `POST /api/medications/intake/bulk`.
    /// Each entry carries `source:"APPLE_HEALTH"` + `externalId` (the HK
    /// dose-event UUID, both-or-neither). Idempotent: a replay yields per-entry
    /// `duplicate` + the existing id, so the caller advances its cursor and
    /// never retries. An entry targeting a non-mirrored med fails the whole
    /// batch `422 medications.intake.bulk.apple_health_not_mirrored`, surfaced
    /// as ``HLError/server(status:code:message:)`` with that code.
    ///
    /// **Phase 07 / plan 07-05.** `idempotencyKey` is a parameter so the caller
    /// can *derive* it from the chunk's own dose UUIDs instead of minting one
    /// per attempt. A process that dies between this POST and its ledger write
    /// rebuilds the identical key on relaunch, so the replay window folds the
    /// repeat rather than the route relying on `externalId` uniqueness alone.
    func bulkImportAppleHealthDoses(
        _ entries: [BulkIntakeEntry],
        idempotencyKey: String? = nil
    ) async throws -> AppleHealthBulkIntakeResponse {
        let req: APIRequest<AppleHealthBulkIntakeResponse> = try .post(
            "/api/medications/intake/bulk",
            body: AppleHealthBulkIntakeBody(entries: entries),
            idempotencyKey: idempotencyKey.map(IdempotencyKey.init(raw:)) ?? IdempotencyKey()
        )
        return try await api.send(req)
    }
}

// MARK: - Wire types

/// Request body wrapper for the bulk endpoint (1–500 entries).
struct AppleHealthBulkIntakeBody: Codable {
    let entries: [MedicationsRepository.BulkIntakeEntry]
}

public extension MedicationsRepository {
    /// Decoded `data` of `POST /api/medications/intake/bulk` with the full
    /// per-entry detail the mirror import needs (`api.send` unwraps the
    /// `{data,error,meta}` envelope, so this models the inner object).
    struct AppleHealthBulkIntakeResponse: Codable, Sendable, Equatable {
        public let processed: Int
        public let inserted: Int
        public let updated: Int
        public let duplicates: Int
        public let skipped: [Skip]
        public let entries: [EntryResult]

        public init(
            processed: Int,
            inserted: Int,
            updated: Int,
            duplicates: Int,
            skipped: [Skip],
            entries: [EntryResult]
        ) {
            self.processed = processed
            self.inserted = inserted
            self.updated = updated
            self.duplicates = duplicates
            self.skipped = skipped
            self.entries = entries
        }

        /// Rows that landed (advance the cursor): inserted + updated + duplicate.
        public var landed: Int {
            inserted + updated + duplicates
        }

        /// **Server v1.32.37 — entries refused for an unstable `externalId`.**
        ///
        /// The bulk surface deliberately does NOT fail the payload over one bad
        /// row: the offending entry comes back `skipped` with
        /// `reason: "unstable_external_id"` and the other 499 still land. So this
        /// is a count to report, never a reason to abort the sweep or to hold the
        /// cursor back — the reason is deterministic, so a retry would refuse the
        /// same entry forever.
        public var unstableExternalIDSkips: Int {
            skipped.filter { $0.reason == AppleHealthConceptKey.unstableExternalIDReason }.count
        }

        public struct Skip: Codable, Sendable, Equatable {
            public let index: Int
            public let reason: String
        }

        /// Per-entry result. `inserted`/`updated`/`duplicate` → the row landed
        /// (advance the cursor); `skipped` → not stored (see `reason`).
        public struct EntryResult: Codable, Sendable, Equatable {
            public let index: Int
            public let status: String
            public let reason: String?
            public let id: String?

            public var didLand: Bool {
                status == "inserted" || status == "updated" || status == "duplicate"
            }
        }
    }
}
