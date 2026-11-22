import Foundation

// Apple Health ingest v2 rows that could not reach the server at once: symptom
// pages and deletions for the delete-by-externalId routes, bound to the
// account whose samples they carry. Platform-free like the rest of the queue.

public extension OutboxQueue.Payloads {
    /// `uploadAppleHealthSymptoms`: one page for the symptom batch.
    struct UploadAppleHealthSymptoms: Codable, Sendable {
        public let entries: [AppleHealthSymptomEntryDTO]
        public init(entries: [AppleHealthSymptomEntryDTO]) {
            self.entries = entries
        }
    }

    /// `deleteAppleHealthRecords`: at most 500 sample UUIDs for one route.
    struct DeleteAppleHealthRecords: Codable, Sendable {
        public let domain: AppleHealthDeleteDomain
        public let externalIds: [String]
        public init(domain: AppleHealthDeleteDomain, externalIds: [String]) {
            self.domain = domain
            self.externalIds = externalIds
        }
    }
}

public extension OutboxQueue {
    func enqueueAppleHealthSymptoms(
        _ entries: [AppleHealthSymptomEntryDTO],
        idempotencyKey: String,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        guard !entries.isEmpty else { return }
        try await enqueue(
            .init(
                kind: .uploadAppleHealthSymptoms,
                payload: JSONEncoder.hlDefault.encode(Payloads.UploadAppleHealthSymptoms(entries: entries)),
                idempotencyKey: idempotencyKey,
                ownerUserID: ownerUserID
            ),
            requiringCurrentOwner: ownerUserID
        )
    }

    func enqueueAppleHealthDeletion(
        _ externalIDs: [String],
        domain: AppleHealthDeleteDomain,
        idempotencyKey: String,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        guard !externalIDs.isEmpty else { return }
        try await enqueue(
            .init(
                kind: .deleteAppleHealthRecords,
                payload: JSONEncoder.hlDefault.encode(
                    Payloads.DeleteAppleHealthRecords(domain: domain, externalIds: externalIDs)
                ),
                idempotencyKey: idempotencyKey,
                ownerUserID: ownerUserID
            ),
            requiringCurrentOwner: ownerUserID
        )
    }

    /// Deletions win over older queued uploads (server 1.48.2: a deleted id
    /// stays blocked for 75 days, then a re-post would insert it again).
    /// Every live upload row of `kind` that names one of `externalIDs` is
    /// rewritten without those records, under a new key; a row left empty
    /// goes. Rows already handed to the server (`delivered`) stay. Returns
    /// how many records were taken out.
    @discardableResult
    func pruneQueuedAppleHealthUploads(
        _ kind: Operation.Kind,
        removing externalIDs: Set<String>,
        ownerUserID: String
    ) async -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        if kind == .syncHealthKitSample {
            return await pruneQueuedHealthKitEntries(ownerUserID: ownerUserID) { externalIDs.contains($0.externalId) }.count
        }
        if let recordKey = Self.singleRecordKey(of: kind) {
            return await pruneQueuedSingleRecords(kind, recordKey: recordKey, removing: externalIDs, ownerUserID: ownerUserID)
        }
        guard let arrayKey = Self.recordArrayKey(of: kind) else { return 0 }
        var removed = 0
        let rows = await snapshot
        for op in rows where op.kind == kind && op.ownerUserID == ownerUserID && !op.delivered {
            guard var object = (try? JSONSerialization.jsonObject(with: op.payload)) as? [String: Any],
                  let records = object[arrayKey] as? [[String: Any]] else { continue }
            let kept = records.filter { !externalIDs.contains($0["externalId"] as? String ?? "") }
            guard kept.count < records.count else { continue }
            object[arrayKey] = kept
            do {
                if !kept.isEmpty {
                    let payload = try JSONSerialization.data(withJSONObject: object)
                    try await enqueue(
                        .init(
                            kind: kind,
                            payload: payload,
                            idempotencyKey: "\(op.idempotencyKey).pruned\(kept.count)",
                            ownerUserID: ownerUserID
                        ),
                        requiringCurrentOwner: ownerUserID
                    )
                }
                try await remove(id: op.id)
                removed += records.count - kept.count
            } catch {
                HLLog.outbox.error("queued Apple Health upload could not be pruned")
            }
        }
        return removed
    }

    /// **Entries taken out of queued HealthKit pages.** Every live
    /// `.syncHealthKitSample` row of `ownerUserID` that carries an entry `drop`
    /// names is rewritten without it, under a new key and with its trigger; a
    /// row left empty goes. Delivered rows stay. Returns what was taken out.
    ///
    /// #5: a sample deleted in Health whose upload still waits would otherwise
    /// come back after its delete. #3: a day total waiting here would replay an
    /// older value over a newer one.
    @discardableResult
    func pruneQueuedHealthKitEntries(
        ownerUserID: String,
        where drop: @escaping @Sendable (HealthKitBatchEntryDTO) -> Bool
    ) async -> [HealthKitBatchEntryDTO] {
        var removed: [HealthKitBatchEntryDTO] = []
        for op in await snapshot where op.kind == .syncHealthKitSample && op.ownerUserID == ownerUserID && !op.delivered {
            guard let payload = try? JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: op.payload) else { continue }
            let taken = payload.entries.filter(drop)
            guard !taken.isEmpty else { continue }
            let kept = payload.entries.filter { !drop($0) }
            do {
                if !kept.isEmpty {
                    try await enqueueHealthKitBatch(
                        kept,
                        encoder: .hlBatch,
                        idempotencyKey: "\(op.idempotencyKey).pruned\(kept.count)",
                        syncTrigger: payload.syncTrigger,
                        requiringCurrentOwner: ownerUserID
                    )
                }
                try await remove(id: op.id)
                removed += taken
            } catch {
                HLLog.outbox.error("queued HealthKit page could not be pruned")
            }
        }
        return removed
    }

    /// Rows of `kind` that carry exactly one record (a cycle day-log) whose
    /// `externalId` is in `externalIDs` go as a whole (server 1.48.0: a late
    /// re-post of a deleted Apple Health day revives it).
    private func pruneQueuedSingleRecords(
        _ kind: Operation.Kind,
        recordKey: String,
        removing externalIDs: Set<String>,
        ownerUserID: String
    ) async -> Int {
        var removed = 0
        for op in await snapshot where op.kind == kind && op.ownerUserID == ownerUserID && !op.delivered {
            guard let object = (try? JSONSerialization.jsonObject(with: op.payload)) as? [String: Any],
                  let record = object[recordKey] as? [String: Any],
                  record["source"] as? String == "APPLE_HEALTH",
                  let id = record["externalId"] as? String, externalIDs.contains(id) else { continue }
            do {
                try await remove(id: op.id)
                removed += 1
            } catch {
                HLLog.outbox.error("queued Apple Health day-log could not be pruned")
            }
        }
        return removed
    }

    /// The JSON key of the one record in an upload row that carries a single
    /// Apple Health record.
    internal static func singleRecordKey(of kind: Operation.Kind) -> String? {
        switch kind {
        case .logCycleDayLog: "write"
        default: nil
        }
    }

    /// The JSON key of the record list in an upload row this pruning knows.
    internal static func recordArrayKey(of kind: Operation.Kind) -> String? {
        switch kind {
        case .uploadAppleHealthSymptoms: "entries"
        case .uploadWorkoutBatch: "workouts"
        default: nil
        }
    }
}
