import Foundation

/// The HealthKit half of the Health Records lab sync, behind a protocol so the
/// importer is tested without HealthKit.
protocol ClinicalLabRecordReading: Sendable {
    /// `HKHealthStore.supportsHealthRecords()`.
    var supportsHealthRecords: Bool { get }
    /// The separate Health Records read request (lab results only).
    func requestAuthorization() async throws
    /// Lab results added after `anchor` (an archived `HKQueryAnchor`, `nil`
    /// for the first read), at most `limit`, and the anchor after them.
    /// The page after `anchor`; ``ClinicalLabChangesPage/read`` says whether
    /// it was the last one.
    func changes(after anchor: Data?, limit: Int) async throws -> ClinicalLabChangesPage
    /// The records with these sample ids that still exist.
    func records(withIDs ids: [UUID]) async throws -> [ClinicalLabRecord]
}

/// One anchored read of Health Records.
struct ClinicalLabChangesPage: Sendable, Equatable {
    let records: [ClinicalLabRecord]
    let anchor: Data?
    /// How many samples HealthKit handed back, before those that are no lab
    /// record HealthLog can read were dropped: only this count says whether
    /// the page was the last one.
    let read: Int
}

/// Posts one wire body to `POST /api/labs/fhir-batch`.
protocol ClinicalLabRecordUploading: Sendable {
    func upload(_ body: Data) async throws -> ClinicalLabBatchResponse
}

/// The production uploader over the shared API client.
struct ClinicalLabRecordAPIUploader: ClinicalLabRecordUploading {
    static let path = "/api/labs/fhir-batch"

    let api: any APIClientProtocol

    func upload(_ body: Data) async throws -> ClinicalLabBatchResponse {
        // A fresh key per call: the records carry their own identity and the
        // server dedupes on it, so a resend of `write_failed` may never meet
        // a cached answer. The transport's own retries reuse this key.
        try await api.send(APIRequest(method: .post, path: Self.path, body: body))
    }
}

/// What one pass did.
enum ClinicalLabSyncPassResult: Equatable, Sendable {
    /// Not offered here, not chosen, or no account.
    case off
    case completed(ClinicalLabBatchOutcome)
    /// Stopped on a call that may succeed later; the cursor held.
    case held(ClinicalLabBatchOutcome)
}

/// Reads lab results from Health Records and sends them to the server.
///
/// The cursor moves only past records that got an answer: a page is read
/// after the anchor, sent in calls of up to 200, and the new anchor is kept
/// once every call of the page was answered. `write_failed` and records the
/// answer left out go on a resend list that the next pass sends first; a
/// call that got no answer stops the pass and keeps anchor and list.
actor ClinicalLabRecordImporter {
    private let reader: any ClinicalLabRecordReading
    private let uploader: any ClinicalLabRecordUploading
    private let cursors: ClinicalLabRecordCursorStore
    /// Whether the gate is open and the person chose the sync, read per pass.
    private let isEnabled: @Sendable () -> Bool
    /// The account the pass works for, read again before every commit.
    private let owner: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var isRunning = false

    /// Pages per pass; a page is at most 200 records.
    static let pagesPerPass = 5

    init(
        reader: any ClinicalLabRecordReading,
        uploader: any ClinicalLabRecordUploading,
        cursors: ClinicalLabRecordCursorStore = ClinicalLabRecordCursorStore(),
        isEnabled: @escaping @Sendable () -> Bool,
        owner: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.uploader = uploader
        self.cursors = cursors
        self.isEnabled = isEnabled
        self.owner = owner
        self.now = now
    }

    nonisolated var supportsHealthRecords: Bool {
        reader.supportsHealthRecords
    }

    func requestAuthorization() async throws {
        try await reader.requestAuthorization()
    }

    /// One bounded pass. A second caller while one runs gets `.off` and
    /// leaves the work to the running pass.
    func sync(pages: Int = ClinicalLabRecordImporter.pagesPerPass) async -> ClinicalLabSyncPassResult {
        guard isEnabled(), let account = owner(), !isRunning else { return .off }
        isRunning = true
        defer { isRunning = false }
        var cursor = cursors.load(owner: account)
        var total = ClinicalLabBatchOutcome()
        var sent = 0
        defer {
            if owner() == account {
                cursor.lastPass = now()
                cursor.lastSent = sent
                cursor.lastInserted = total.inserted
                cursor.lastDuplicate = total.duplicate
                cursor.totalInserted += total.inserted
                cursors.save(cursor, owner: account)
            }
        }

        // The records owed a resend go first.
        guard await resendOwed(&cursor, total: &total, sent: &sent, account: account) else { return .held(total) }

        for _ in 0 ..< max(1, pages) {
            guard !Task.isCancelled else { return .held(total) }
            guard let page = try? await reader.changes(after: cursor.anchor, limit: ClinicalLabRecordBatching.maxRecordsPerCall) else {
                return .held(total)
            }
            switch await send(page.records, account: account) {
            case let .answered(outcome):
                total.add(outcome)
                sent += page.records.count
                let resend = Self.merged(cursor.resend, outcome.resend)
                // Past the bound the page is not taken: its records come
                // again with the page instead of being cut off the list.
                guard resend.count <= ClinicalLabRecordCursor.maxResend else { return .held(total) }
                cursor.resend = resend
                cursor.anchor = page.anchor ?? cursor.anchor
            case .held:
                return .held(total)
            }
            // A full page of samples may carry fewer records (unreadable ones
            // stay home); only a short read of samples ends the history.
            if page.read < ClinicalLabRecordBatching.maxRecordsPerCall { break }
        }
        return .completed(total)
    }

    /// Sends the records owed a resend; `false` when the pass must hold.
    private func resendOwed(
        _ cursor: inout ClinicalLabRecordCursor,
        total: inout ClinicalLabBatchOutcome,
        sent: inout Int,
        account: String
    ) async -> Bool {
        guard !cursor.resend.isEmpty else { return true }
        guard let resent = try? await reader.records(withIDs: cursor.resend) else { return false }
        guard case let .answered(outcome) = await send(resent, account: account) else { return false }
        total.add(outcome)
        sent += resent.count
        cursor.resend = outcome.resend
        return true
    }

    private enum SendResult {
        case answered(ClinicalLabBatchOutcome)
        case held
    }

    /// The resend list in order, each record once, the oldest first.
    static func merged(_ list: [UUID], _ more: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return (list + more).filter { seen.insert($0).inserted }
    }

    /// Sends the records in calls; `held` as soon as one call got no final
    /// answer or the account changed.
    private func send(_ records: [ClinicalLabRecord], account: String) async -> SendResult {
        let split = ClinicalLabRecordBatching.batches(records)
        var outcome = ClinicalLabBatchOutcome()
        outcome.skipped += split.leftOut.count
        for batch in split.batches {
            guard let answered = await sendCall(batch, account: account) else { return .held }
            outcome.add(answered)
        }
        return .answered(outcome)
    }

    /// One call. A refused call of several records is halved and each half
    /// sent alone, so one bad record or a body the server finds too large
    /// costs only itself; `nil` when a call got no final answer.
    private func sendCall(_ batch: [ClinicalLabRecord], account: String) async -> ClinicalLabBatchOutcome? {
        guard owner() == account else { return nil }
        do {
            let body = try ClinicalLabRecordBatching.body(for: batch)
            let response = try await uploader.upload(body)
            guard owner() == account else { return nil }
            return .classify(response, batch: batch)
        } catch {
            guard ClinicalLabCallFailure.of(error) == .refused else { return nil }
            guard batch.count > 1 else {
                var failed = ClinicalLabBatchOutcome()
                failed.failed = 1
                return failed
            }
            let middle = batch.count / 2
            guard let first = await sendCall(Array(batch[..<middle]), account: account),
                  let second = await sendCall(Array(batch[middle...]), account: account) else { return nil }
            var both = first
            both.add(second)
            return both
        }
    }
}

extension ClinicalLabSyncPassResult {
    /// The orchestrator's word for this pass.
    func capabilityResult(_ capability: HealthSyncCapability) -> HealthSyncCapabilityResult {
        switch self {
        case .off:
            .disabled(capability)
        case let .completed(outcome):
            .succeeded(
                capability,
                submitted: outcome.inserted + outcome.duplicate + outcome.skipped + outcome.failed + outcome.resend.count,
                settled: outcome.inserted + outcome.duplicate + outcome.skipped + outcome.failed
            )
        case let .held(outcome):
            HealthSyncCapabilityResult(
                capability: capability,
                disposition: .deferred,
                itemsSettled: outcome.inserted + outcome.duplicate + outcome.skipped + outcome.failed,
                itemsHeld: outcome.resend.count,
                failure: .transport
            )
        }
    }
}
