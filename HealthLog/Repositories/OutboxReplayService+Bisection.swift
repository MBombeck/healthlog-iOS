import Foundation

// A2 (1.4, R3 S7) — a whole-batch 422 that names no row, halved.
//
// A server before v1.39.1 answers a schema failure on
// `POST /api/measurements/batch` with a 422 and nothing else: no code, no
// issue path (v1.39.1 and later name the entries, see `MeasurementBatchInvalid`).
// Up to 1.3.0 the replay parked such a page for good, so one bad reading held
// the 499 others of its page back for as long as the server stayed as it was.
//
// The page is now sent again in halves, under fresh keys (a half is another
// body; the server folds a repeated row on its `externalId`), and every half
// the server refuses is halved again, until a refused half is one row. Those
// rows come back `skipped` with ``HealthKitBatchRejection/unclassifiedReason(status:)``
// and the caller records them in the skip register like every other refusal:
// listed in Sync Diagnostics, offered again with every new build.
//
// Two answers end it without a register entry, and the page parks as before:
// no half landed at all (the server refuses everything, not one row), or the
// halving spent ``OutboxReplayService/maxBisectionPosts`` requests first.

extension OutboxReplayService {
    /// Requests one halving may spend after the refused page itself: enough
    /// to pin one bad row in a full page of 500 (two requests on each of nine
    /// levels), small enough that a page whose every row is refused costs one
    /// pass two dozen requests, once.
    static let maxBisectionPosts = 24

    /// What halving a refused page found.
    enum Halving: Equatable {
        /// Some halves landed. `response` is indexed like the page; the rows
        /// refused on their own are in it as `skipped`.
        case isolated(HealthKitBatchResponseDTO)
        /// Nothing landed, or the budget ran out: not one bad row.
        case inconclusive
    }

    /// The 422 halving is for: a whole-batch refusal that names no row.
    static func isUnexplainedRefusal(_ error: Error) -> Bool {
        HealthKitBatchRejection.classify(error) == .notStored(status: 422)
    }

    /// Halves the refused page `entries` and answers like one response. A
    /// session change, an unproven acceptance and any transport failure on
    /// the way stay retryable, as on the page itself.
    func replayHalving(
        _ entries: [HealthKitBatchEntryDTO],
        syncTrigger: SyncTrigger?,
        owner: String
    ) async throws -> HealthKitBatchResponseDTO {
        let found: Halving
        do {
            found = try await Self.halve(entries) { [outbox, measurementsRepo] part in
                let authLease = try await outbox.captureAuthLease(requiringOwner: owner)
                let answer = try await measurementsRepo.replayHealthKitBatch(
                    part,
                    idempotencyKey: IdempotencyKey().raw,
                    syncTrigger: syncTrigger,
                    authLease: authLease
                )
                try await outbox.validateAuthLease(authLease)
                return answer
            }
        } catch is OutboxQueue.OwnerLeaseError {
            throw HLError.network(.other("authenticated session changed"))
        } catch let error as MeasurementBatchAcceptanceError {
            throw HLError.network(.other(error.description))
        }
        guard case let .isolated(response) = found else {
            // Counts only — no identifier, no value.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.info("HK page 422 — halving found no single row (\(entries.count, privacy: .public) rows), parked")
            throw HealthKitReplayParked(reason: .notStoredAfterHalving(status: 422))
        }
        let refused = response.entries.count { $0.status == .skipped }
        // Counts only — no identifier, no value.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("HK page 422 — halved: \(refused, privacy: .public)/\(entries.count, privacy: .public) refused alone")
        return response
    }

    /// The halving itself, over any wire (`send` posts one part). Depth first,
    /// the older half of each pair first, so the requests follow the page.
    static func halve(
        _ entries: [HealthKitBatchEntryDTO],
        send: @Sendable ([HealthKitBatchEntryDTO]) async throws -> HealthKitBatchResponseDTO
    ) async throws -> Halving {
        guard entries.count > 1 else { return .inconclusive }
        var pending = Array(halves(of: entries.indices).reversed())
        var landed: [(range: Range<Int>, response: HealthKitBatchResponseDTO)] = []
        var refused: [Int] = []
        var posts = 0
        while let range = pending.popLast() {
            guard posts < Self.maxBisectionPosts else { return .inconclusive }
            posts += 1
            let part = Array(entries[range])
            do {
                let response = try await send(part)
                try MeasurementBatchAcceptance.validate(
                    postedCount: part.count,
                    postedExternalIds: part.map(\.externalId),
                    response: response,
                    policy: .deployedMeasurementRoute
                )
                landed.append((range, response))
            } catch let error where isUnexplainedRefusal(error) {
                if range.count == 1 {
                    refused.append(range.lowerBound)
                } else {
                    pending += halves(of: range).reversed()
                }
            }
        }
        guard !landed.isEmpty else { return .inconclusive }
        return .isolated(merge(landed, refused: refused, total: entries.count))
    }

    static func halves(of range: Range<Int>) -> [Range<Int>] {
        let middle = range.lowerBound + range.count / 2
        return [range.lowerBound ..< middle, middle ..< range.upperBound]
    }

    /// The landed halves re-indexed onto the page, plus one `skipped` verdict
    /// per row refused on its own.
    static func merge(
        _ landed: [(range: Range<Int>, response: HealthKitBatchResponseDTO)],
        refused: [Int],
        total: Int
    ) -> HealthKitBatchResponseDTO {
        let reason = HealthKitBatchRejection.unclassifiedReason(status: 422)
        var entries: [HealthKitBatchResponseDTO.EntryResult] = []
        var skipped: [HealthKitBatchResponseDTO.SkippedEntry] = []
        for (range, response) in landed {
            for entry in response.entries where (0 ..< range.count).contains(entry.index) {
                entries.append(.init(index: range.lowerBound + entry.index, status: entry.status, reason: entry.reason))
            }
            for skip in response.skipped where (0 ..< range.count).contains(skip.index) {
                skipped.append(.init(index: range.lowerBound + skip.index, reason: skip.reason))
            }
        }
        for index in refused {
            entries.append(.init(index: index, status: .skipped, reason: reason))
            skipped.append(.init(index: index, reason: reason))
        }
        return HealthKitBatchResponseDTO(
            processed: total,
            inserted: landed.reduce(0) { $0 + $1.response.inserted },
            duplicates: landed.reduce(0) { $0 + $1.response.duplicates },
            skipped: skipped.sorted { $0.index < $1.index },
            entries: entries.sorted { $0.index < $1.index }
        )
    }
}
