import Foundation

// A whole-batch 422 that names no row, halved.
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
// One answer ends it without a register entry, and the page parks as before:
// no half landed at all (the server refuses everything, not one row).
//
// #14 — a halving that spends ``OutboxReplayService/maxBisectionPosts``
// requests first keeps what it found: the halves that landed are delivered,
// the rows refused alone go into the register, and the parts it had not got to
// are queued again as rows of their own, which the next pass halves with a
// budget of their own. Up to 1.6 the whole page parked marked "halved" and went
// out whole on every pass from then on: two bad rows in different halves of
// one page held the 498 others for good.

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
        /// The budget ran out with parts still unsent: what landed and what
        /// was refused alone, plus the index ranges of the unsent parts.
        case partial(HealthKitBatchResponseDTO, remaining: [Range<Int>])
        /// Nothing landed: not one bad row.
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
        owner: String,
        idempotencyKey: String
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
            throw HLError.authenticatedSessionChanged
        } catch let error as MeasurementBatchAcceptanceError {
            throw HLError.network(.other(error.description))
        }
        if case let .partial(response, remaining) = found {
            try await requeueUnsentParts(
                remaining.map { Array(entries[$0]) },
                syncTrigger: syncTrigger,
                owner: owner,
                idempotencyKey: idempotencyKey
            )
            // Counts only — no identifier, no value.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.info("HK page 422 — halving budget spent, \(remaining.count, privacy: .public) part(s) queued again")
            return response
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
        // A one-row page refused as a whole is that row refused on its own;
        // a rest a spent halving queued can be exactly that (#14).
        guard entries.count > 1 else {
            return entries.isEmpty ? .inconclusive : .isolated(merge([], refused: [0], total: 1))
        }
        var pending = Array(halves(of: entries.indices).reversed())
        var landed: [(range: Range<Int>, response: HealthKitBatchResponseDTO)] = []
        var refused: [Int] = []
        var posts = 0
        while let range = pending.popLast() {
            guard posts < Self.maxBisectionPosts else {
                guard !landed.isEmpty else { return .inconclusive }
                let remaining = (pending + [range]).sorted { $0.lowerBound < $1.lowerBound }
                return .partial(merge(landed, refused: refused, total: entries.count), remaining: remaining)
            }
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

    /// #14 — the parts a spent halving did not reach, each as a row of its
    /// own under the page's owner and trigger. The key is derived from the
    /// page's and the part's position, so a pass that dies after some of them
    /// were written finds those waiting and does not add them twice. Any part
    /// that cannot be written keeps the page as it is (retryable).
    func requeueUnsentParts(
        _ parts: [[HealthKitBatchEntryDTO]],
        syncTrigger: SyncTrigger?,
        owner: String,
        idempotencyKey: String
    ) async throws {
        for (offset, part) in parts.enumerated() where !part.isEmpty {
            let key = "\(idempotencyKey).rest\(offset).\(part.count)"
            if await outbox.hasLiveOperation(idempotencyKey: key) { continue }
            do {
                try await outbox.enqueueHealthKitBatch(
                    part,
                    encoder: .hlBatch,
                    idempotencyKey: key,
                    syncTrigger: syncTrigger,
                    requiringCurrentOwner: owner
                )
            } catch {
                throw HLError.network(.other("halving rest not queued"))
            }
        }
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
        let reason = HealthKitBatchRejection.individuallyRefusedReason(status: 422)
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
