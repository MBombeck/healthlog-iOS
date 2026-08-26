import Foundation

// Phase 07 Wave 3 — the dose-import half of the Apple-Health medication sweep.
//
// An extension rather than a second type: this is the same transaction, and the
// mirror half above it is what decides whether a dose is routable at all. It
// lives in its own file because per-dose progression pushed the actor body past
// the `type_body_length` gate, and because "what one chunk proved" is the part a
// reader comes here for.

extension AppleHealthMedicationImporter {
    /// One importable dose, paired with the identity the ledger and the server
    /// both key on. The two must not drift, so they travel together.
    struct PreparedDose {
        let identity: String
        let entry: MedicationsRepository.BulkIntakeEntry
    }

    /// What one chunk proved: the running tally, which identities the server
    /// terminally settled, and whether the sweep may keep going.
    struct ChunkOutcome {
        let summary: AppleHealthMedicationSyncSummary
        let settled: Set<String>
        /// `true` when the sweep must stop without attempting later chunks.
        /// Their doses stay pending, which is what makes the stop recoverable.
        let stop: Bool
    }

    func importDoses(
        into summaryIn: AppleHealthMedicationSyncSummary,
        doses: [AppleHealthDoseRecord],
        ledger: AppleHealthDoseLedger,
        requiring lease: HealthSyncAuthenticatedLease
    ) async -> AppleHealthMedicationSyncSummary {
        var summary = summaryIn

        // Every dose this sweep saw, with the instant it was recorded at. This
        // is what lets the ledger keep a hole open behind a moving horizon.
        var observed: [String: Date] = [:]
        // Identities that are terminally done: landed, deterministically refused,
        // or not importable by contract. Everything else stays pending.
        var accountedFor: Set<String> = []

        // Map each importable dose onto its mirrored med. Doses whose concept is
        // not mirrored are held back (source-exclusive) — never sent, and never
        // accounted for, so the next sweep resumes at the oldest of them.
        var prepared: [PreparedDose] = []
        for dose in doses {
            observed[dose.eventUUID] = dose.recordedAt
            guard let medId = registry.medicationId(forConcept: dose.conceptIdentifier) else {
                summary.dosesHeldBackNotMirrored += 1
                continue
            }
            guard let entry = MedicationsRepository.BulkIntakeEntry.appleHealth(
                dose: dose,
                mirroredMedicationId: medId
            ) else {
                // Neither taken nor skipped → not imported by contract, and that
                // is a terminal statement about the dose rather than a failure.
                summary.dosesIgnored += 1
                accountedFor.insert(dose.eventUUID)
                continue
            }
            prepared.append(PreparedDose(identity: dose.eventUUID, entry: entry))
        }

        for chunk in prepared.chunked(into: Self.maxEntriesPerBatch) {
            let outcome = await transmit(chunk, into: summary, requiring: lease)
            summary = outcome.summary
            accountedFor.formUnion(outcome.settled)
            if outcome.stop { break }
        }

        // Record what is done and what is still owed. A ledger write that does
        // not survive its own read-back leaves the partition exactly where it
        // was: the next sweep re-offers the same doses and the server folds the
        // repeat on the dose UUID.
        do {
            try ledger.commit(observed: observed, accountedFor: accountedFor, requiring: lease)
        } catch {
            HLLog.healthKit.error("APPLE-MED dose ledger not committed — sweep holds its window")
        }
        return summary
    }

    /// Sends one chunk and reports exactly which identities the server settled.
    ///
    /// The idempotency key is **derived** from the chunk's own sorted dose UUIDs
    /// rather than minted per attempt, so a process that dies between the POST
    /// and the ledger write rebuilds the same key on relaunch and the server
    /// deduplicates instead of writing a second intake row.
    private func transmit(
        _ chunk: [PreparedDose],
        into summaryIn: AppleHealthMedicationSyncSummary,
        requiring lease: HealthSyncAuthenticatedLease
    ) async -> ChunkOutcome {
        var summary = summaryIn
        let identities = chunk.map(\.identity)
        let envelope = HealthSyncRetryEnvelope(
            ownerID: lease.ownerID,
            source: lease.source,
            stableIdentity: identities.sorted().joined(separator: "|")
        )
        do {
            // Check 1 of 2 — before the request.
            try lease.requireCurrent()
            let response = try await repo.bulkImportAppleHealthDoses(
                chunk.map(\.entry),
                idempotencyKey: envelope?.idempotencyKey
            )
            // Check 2 of 2 — an account replacement that lands during the await
            // must not let this chunk stamp progress into the new owner's ledger.
            try lease.requireCurrent()

            summary.dosesInserted += response.inserted
            summary.dosesUpdated += response.updated
            summary.dosesDuplicate += response.duplicates
            summary.dosesSkipped += response.skipped.count
            // v1.32.37 — a refused `externalId` comes back as a per-entry skip
            // while the rest of the chunk lands. Count it, never abort: the
            // reason is deterministic, so holding the dose back would re-offer
            // the same entry on every future sweep.
            let unstable = response.unstableExternalIDSkips
            if unstable > 0 {
                summary.dosesSkippedUnstableExternalID += unstable
                HLLog.healthKit.info(
                    "APPLE-MED bulk skipped \(unstable, privacy: .public) entries — unstable_external_id"
                )
            }
            return ChunkOutcome(
                summary: summary,
                settled: Self.settledIdentities(in: response, of: identities),
                stop: false
            )
        } catch {
            if case let HLError.server(status, code, _) = error,
               status == 422, code == Self.notMirroredErrorCode
            {
                // A mirrored-med race — stop WITHOUT accounting for anything, so
                // the doses retry once their med is mirrored. Never a blind
                // retry.
                HLLog.healthKit.info("APPLE-MED bulk stopped — apple_health_not_mirrored (422)")
                summary.notMirroredRejections += 1
            } else {
                HLLog.healthKit.error(
                    "APPLE-MED bulk import failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                summary.failedBatches += 1
            }
            return ChunkOutcome(summary: summary, settled: [], stop: true)
        }
    }

    /// Which of the posted identities the server terminally settled.
    ///
    /// Exact and per index, in the same spirit as ``MeasurementBatchAcceptance``:
    /// an index the response never mentions is **not** settled, because a
    /// response that says nothing about a row is not evidence the row was
    /// stored. Two outcomes settle a row — it landed
    /// (`inserted`/`updated`/`duplicate`), or the server refused it for the one
    /// deterministic reason a retry can never fix.
    private static func settledIdentities(
        in response: MedicationsRepository.AppleHealthBulkIntakeResponse,
        of identities: [String]
    ) -> Set<String> {
        var settled: Set<String> = []
        for entry in response.entries where entry.didLand {
            guard identities.indices.contains(entry.index) else { continue }
            settled.insert(identities[entry.index])
        }
        for skip in response.skipped
            where skip.reason == AppleHealthConceptKey.unstableExternalIDReason
        {
            guard identities.indices.contains(skip.index) else { continue }
            settled.insert(identities[skip.index])
        }
        return settled
    }
}

// MARK: - Chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
