import Foundation

/// Platform-agnostic seam so `MedicationHealthSyncStore` can drive the importer
/// without importing HealthKit. Single fire-and-forget surface.
public protocol AppleHealthMedicationSyncing: Sendable {
    /// Mirror the current Apple Health medications + import their new dose events
    /// (read-only). Self-gates on a present auth token; the caller (toggle
    /// enable / foreground / BG sweep) needs no summary.
    func triggerAppleHealthMedicationSync() async
}

/// **GH #47 (server v1.28) — Apple Health medications + intake importer.**
///
/// Read-only mirror. Each sweep:
///  1. Reads the account's medications (`GET /api/medications`, which since
///     server v1.32.25 echoes `externalSource`) and reconciles that server truth
///     into the registry's concept → server-med-id routing table.
///  2. Reads `HKUserAnnotatedMedication`s (via the ``AppleHealthMedicationReading``
///     seam) and upserts **only concepts the server does not already mirror, or
///     whose name/form changed**, through `POST /api/medications` with
///     `externalSource:"APPLE_HEALTH"` + the stable concept key as `externalId`.
///  3. Reads `HKMedicationDoseEvent`s since the persisted cursor, maps each
///     taken/skipped dose onto its mirrored med, and bulk-imports them via
///     `POST /api/medications/intake/bulk` (`source:"APPLE_HEALTH"` + dose UUID
///     as `externalId`). A replay yields per-entry `duplicate` → the cursor
///     advances, never a retry.
///
/// **CU-10 — why step 2 skips.** This used to re-post *every* annotated
/// medication on *every* sweep and lean on server idempotency alone to dedup.
/// That made the whole feature hostage to `externalId` stability: once the key
/// rotated (it did — `String(describing:)` on an opaque HK type returns a memory
/// address), the upsert key never matched and each sweep minted a fresh row. 23
/// phantom medications appeared on the operator's live instance in a single day.
/// The key is stable now (``AppleHealthConceptKey``), but the discipline stands
/// on its own: server idempotency is the backstop, not the primary mechanism.
///
/// **Source-exclusive:** an Apple dose whose concept is not (yet) mirrored is
/// held back — never sent — so the batch can't trip the server's
/// `medications.intake.bulk.apple_health_not_mirrored` 422. If the server still
/// rejects a chunk with that code, the run stops WITHOUT advancing the cursor so
/// the doses retry once their med is mirrored.
///
/// **Phase 07 / plan 07-05 — per-dose durable progression.** The sweep used to
/// keep one `Date` watermark and move it to the newest dose it managed to
/// import. A dose held back for a not-yet-mirrored concept therefore vanished
/// behind the next success, and an equal-timestamp sibling was dropped by the
/// strict `>` read. ``AppleHealthDoseLedger`` replaces it: identity is the
/// HealthKit dose-event UUID, the read resumes at the *oldest pending* instant
/// rather than the newest imported one, and the whole partition is bound to the
/// account admitted before the first read.
///
/// Never recomputes compliance (PROJECT_GUIDE.md) — it only feeds the server ledger.
public actor AppleHealthMedicationImporter {
    private let reader: AppleHealthMedicationReading
    // `repo` and `registry` are internal, not private: the dose-import half of
    // this actor lives in `AppleHealthMedicationImporter+DoseImport.swift`.
    let repo: MedicationsRepository
    private let keychain: KeychainStoring
    let registry: AppleHealthMirrorRegistry
    private let clock: @Sendable () -> Date
    /// The account this sweep works for, resolved fresh on every run. `nil` only
    /// in contexts with no session at all, where every sweep refuses: without an
    /// owner there is no partition to write and no one to attribute a dose to.
    private let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?
    private let ledgerStorage: HealthSyncCursorStorage

    /// Apple's bulk-intake ceiling (server contract): 500 entries per call.
    static let maxEntriesPerBatch = 500
    /// Server error code for an Apple dose targeting a non-mirrored med.
    static let notMirroredErrorCode = "medications.intake.bulk.apple_health_not_mirrored"

    /// Public construction keeps the pre-Phase-07 shape and admits nothing, so a
    /// caller outside the composition root gets a sweep that refuses rather than
    /// one that runs under an ambient account.
    public init(
        reader: AppleHealthMedicationReading,
        repo: MedicationsRepository,
        keychain: KeychainStoring,
        registry: AppleHealthMirrorRegistry,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            reader: reader,
            repo: repo,
            keychain: keychain,
            registry: registry,
            clock: clock,
            admission: nil,
            ledgerStorage: .standard
        )
    }

    init(
        reader: AppleHealthMedicationReading,
        repo: MedicationsRepository,
        keychain: KeychainStoring,
        registry: AppleHealthMirrorRegistry,
        clock: @escaping @Sendable () -> Date = { Date() },
        admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?,
        ledgerStorage: HealthSyncCursorStorage = .standard
    ) {
        self.reader = reader
        self.repo = repo
        self.keychain = keychain
        self.registry = registry
        self.clock = clock
        self.admission = admission
        self.ledgerStorage = ledgerStorage
    }

    /// Run one full sweep. Returns a summary the tests assert against.
    @discardableResult
    public func sync() async -> AppleHealthMedicationSyncSummary {
        // Gate: pre-login → nothing to mirror.
        guard keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false else {
            HLLog.healthKit.debug("APPLE-MED sync skipped — no auth token")
            return .zero
        }
        guard reader.isAvailable else {
            HLLog.healthKit.debug("APPLE-MED sync skipped — HealthKit medications unavailable")
            return .zero
        }
        // One admission, captured before the first read and revalidated at every
        // repository, wire, and ledger boundary below. No fallback to an ambient
        // Keychain read: an unprovable owner syncs nothing.
        guard let lease = try? admission?() else {
            HLLog.healthKit.info("APPLE-MED sync refused — no admitted account")
            return .zero
        }
        let owner: HealthSyncOwnerLease = lease.owner
        guard let ledgerKey = AppleHealthDoseLedger.key(for: owner) else {
            HLLog.healthKit.error("APPLE-MED sync refused — dose partition could not be keyed")
            return .zero
        }
        let ledger = AppleHealthDoseLedger(storage: ledgerStorage, key: ledgerKey, clock: clock)
        do {
            // One-shot fold of the legacy date watermark. The legacy key itself
            // is read, never written and never deleted — it is this plan's
            // rollback material.
            try ledger.seedFromDateCursorIfNeeded(registry.doseCursor(), requiring: lease)
        } catch {
            HLLog.healthKit.error("APPLE-MED sync refused — dose ledger could not be established")
            return .zero
        }

        var summary = AppleHealthMedicationSyncSummary.zero

        // 1) Server truth first — reconcile the routing table before deciding
        //    what still needs a create.
        let serverMirrors = await reconcileWithServer()

        // Read both HealthKit surfaces once. Keeping failures independent means
        // an unavailable dose history never prevents medication reconciliation,
        // while an unavailable medication list never discards already-routable
        // dose events.
        //
        // The resume instant is the oldest dose still unaccounted for, not the
        // newest one imported: a held dose keeps the window open behind every
        // later success, and because the HealthKit predicate includes its start
        // instant, an equal-timestamp sibling comes back with it.
        let resumeAt = ledger.resumeInstant()
        let medicationRecords = await readMedicationRecords()
        let doseRecords = await readDoseRecords(since: resumeAt)

        // 2) Mirror the medications the server does not already carry.
        if let medicationRecords {
            let enriched = Self.addKnownDoseText(to: medicationRecords, from: doseRecords ?? [])
            summary = await mirrorMedications(
                into: summary,
                serverMirrors: serverMirrors,
                medications: enriched,
                requiring: lease
            )
        }

        // 3) Import dose events, then record exactly which ones are done. A
        //    failed read commits nothing: "we could not look" is not "there was
        //    nothing there".
        if let doseRecords {
            summary = await importDoses(
                into: summary,
                doses: doseRecords,
                ledger: ledger,
                requiring: lease
            )
        }
        // Phase 07 / plan 07-07 — 07-05's handoff: the pending set is the only
        // signal that Apple doses are being withheld for a concept the user
        // never mirrored, and it was readable only from a debugger. It is an
        // integer here, next to the quarantine count the stats sweep reports.
        let stillPending = ledger.pendingIdentities().count
        await MainActor.run {
            HKSyncDiagnostics.shared.recordWithheldCounts(pendingAppleDoses: stillPending)
        }
        Self.logSweep(summary)
        return summary
    }

    /// Operator-grade counts only (no PII) — bound to locals for the log.
    private static func logSweep(_ summary: AppleHealthMedicationSyncSummary) {
        let mirrored = summary.medicationsMirrored
        let skippedKnown = summary.medicationsSkippedKnown
        let inserted = summary.dosesInserted
        let duplicate = summary.dosesDuplicate
        let heldBack = summary.dosesHeldBackNotMirrored
        HLLog.healthKit
            .info(
                """
                APPLE-MED sync done — mirrored=\(mirrored, privacy: .public) \
                skippedKnown=\(skippedKnown, privacy: .public) \
                inserted=\(inserted, privacy: .public) \
                duplicate=\(duplicate, privacy: .public) \
                heldBack=\(heldBack, privacy: .public)
                """
            )
    }

    // MARK: - Server reconciliation

    /// `externalId → server medication` for every row the server itself flags as
    /// Apple-Health-mirrored. `nil` when the read failed — the caller must then
    /// fall back to the local registry rather than treat "nothing" as truth.
    private func reconcileWithServer() async -> [String: Medication]? {
        let medications: [Medication]
        do {
            medications = try await repo.list()
        } catch {
            HLLog.healthKit.error(
                "APPLE-MED server reconcile failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return nil
        }
        var byExternalID: [String: Medication] = [:]
        for med in medications where med.isAppleHealthMirrored {
            guard let externalId = med.externalId, !externalId.isEmpty else { continue }
            byExternalID[externalId] = med
        }
        registry.reconcile(
            serverMirrors: byExternalID.mapValues(\.id),
            knownMedicationIDs: Set(medications.map(\.id))
        )
        return byExternalID
    }

    // MARK: - Medication mirror

    private func readMedicationRecords() async -> [AppleHealthMedicationRecord]? {
        do {
            return try await reader.readMedications()
        } catch {
            HLLog.healthKit.error(
                "APPLE-MED read medications failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return nil
        }
    }

    private func readDoseRecords(since cursor: Date?) async -> [AppleHealthDoseRecord]? {
        do {
            return try await reader.readDoseEvents(since: cursor)
        } catch {
            HLLog.healthKit.error(
                "APPLE-MED read dose events failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return nil
        }
    }

    /// The medication concept does not expose a strength. Dose events do, so
    /// use the newest observed non-empty quantity/unit as the mirror's honest
    /// display dose while preserving the event-level value below.
    private static func addKnownDoseText(
        to medications: [AppleHealthMedicationRecord],
        from doses: [AppleHealthDoseRecord]
    ) -> [AppleHealthMedicationRecord] {
        var latestByConcept: [String: AppleHealthDoseRecord] = [:]
        for dose in doses where dose.doseText != nil {
            if let current = latestByConcept[dose.conceptIdentifier], current.recordedAt >= dose.recordedAt {
                continue
            }
            latestByConcept[dose.conceptIdentifier] = dose
        }
        return medications.map { medication in
            guard medication.doseText == nil,
                  let doseText = latestByConcept[medication.conceptIdentifier]?.doseText else { return medication }
            return medication.withDoseText(doseText)
        }
    }

    private func mirrorMedications(
        into summaryIn: AppleHealthMedicationSyncSummary,
        serverMirrors: [String: Medication]?,
        medications: [AppleHealthMedicationRecord],
        requiring lease: HealthSyncAuthenticatedLease
    ) async -> AppleHealthMedicationSyncSummary {
        var summary = summaryIn

        for record in medications {
            // Known = the server says so (authoritative, v1.32.25+) or — when the
            // GET failed or the server predates the provenance echo — the local
            // registry remembers a mapping.
            let serverKnown = serverMirrors?[record.externalId]
            let registryKnown = registry.medicationId(forConcept: record.conceptIdentifier)
            if let id = serverKnown?.id ?? registryKnown {
                registry.recordMirror(conceptIdentifier: record.conceptIdentifier, medicationId: id)
                if let serverKnown, Self.mirrorIsStale(record, server: serverKnown) {
                    // The Health-app entry was renamed / re-formed — post so the
                    // mirror follows. The server upsert lands on the same row.
                    summary = await postMirror(record, into: summary, requiring: lease)
                } else {
                    summary.medicationsSkippedKnown += 1
                }
                continue
            }
            summary = await postMirror(record, into: summary, requiring: lease)
        }
        return summary
    }

    /// Whether the mirrored server row still matches what Apple Health carries.
    /// Only the fields the mirror actually writes are compared. A non-nil dose
    /// learned from a HealthKit event replaces the neutral placeholder.
    private static func mirrorIsStale(_ record: AppleHealthMedicationRecord, server: Medication) -> Bool {
        record.name != server.name
            || record.deliveryForm != server.deliveryForm
            || server.active == record.isArchived
            || (record.doseText != nil && record.doseText != server.dose)
    }

    private func postMirror(
        _ record: AppleHealthMedicationRecord,
        into summaryIn: AppleHealthMedicationSyncSummary,
        requiring lease: HealthSyncAuthenticatedLease
    ) async -> AppleHealthMedicationSyncSummary {
        var summary = summaryIn
        // Derived, not minted: the concept key is stable by construction
        // (CU-10), so a relaunch mid-upsert rebuilds the same operation identity.
        let envelope = HealthSyncRetryEnvelope(
            ownerID: lease.ownerID,
            source: lease.source,
            stableIdentity: "medication-mirror|" + record.externalId
        )
        do {
            try lease.requireCurrent()
            let mirrored = try await repo.mirrorAppleHealthMedication(
                record,
                idempotencyKey: envelope?.idempotencyKey
            )
            try lease.requireCurrent()
            registry.recordMirror(
                conceptIdentifier: record.conceptIdentifier,
                medicationId: mirrored.id
            )
            summary.medicationsMirrored += 1
        } catch {
            summary.medicationsFailed += 1
            guard case let HLError.server(status, code, _) = error, status == 422 else {
                HLLog.healthKit.error(
                    "APPLE-MED mirror upsert failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return summary
            }
            switch code {
            case MedicationsRepository.mirrorLimitErrorCode:
                // v1.32.25 growth cap — not a transport failure and not
                // retriable. The user has more Apple Health medications than
                // HealthLog mirrors; they need to be told that, in those words.
                summary.mirrorLimitRejections += 1
                HLLog.healthKit.info("APPLE-MED mirror refused — limit_exceeded (422)")
            case MedicationsRepository.unstableExternalIDErrorCode:
                summary.unstableExternalIDRejections += 1
            default:
                HLLog.healthKit.error("APPLE-MED mirror rejected 422 code=\(code ?? "-", privacy: .public)")
            }
        }
        return summary
    }
}

extension AppleHealthMedicationImporter: AppleHealthMedicationSyncing {
    public func triggerAppleHealthMedicationSync() async {
        await sync()
    }
}
