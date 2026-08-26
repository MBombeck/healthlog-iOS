import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    // Phase 07 / plan 07-06 — the durable half of the cycle import.
    //
    // Split out of `CycleHealthKitImporter.swift` for the same reason
    // `AppleHealthMedicationImporter+DoseImport.swift` exists: the lifecycle half
    // (observers, coalescing, teardown) and the durability half (admission,
    // per-index acceptance, durable retry, cursor commit) are two separate
    // subjects, and together they exceed the file and type budgets in
    // `PROJECT_GUIDE.md`. The members this half reaches are module-internal
    // rather than `private` purely because of that split; nothing outside the
    // module can name them.

    extension CycleHealthKitImporter {
        // MARK: - Sweep

        /// One anchored batch for a single category type, serialized through
        /// the per-type sweep gate (N5.3).
        @available(iOS 18.0, *)
        func runAnchoredSweep(type: HKCategoryType) async -> HealthSyncDisposition {
            // One token per call. Only the first caller's body runs, so only that
            // caller's token is ever filled in; a coalesced trigger reads nothing
            // back and reports `.deferred` — which is exactly what happened to
            // it: it was folded into a sweep that is already in flight.
            let token = UUID()
            await sweepGate.run(key: type.identifier) { [weak self] in
                guard let self else { return }
                let disposition = await performAnchoredSweep(type: type)
                await record(disposition, for: token)
            }
            return takeDisposition(for: token) ?? .deferred
        }

        func record(_ disposition: HealthSyncDisposition, for token: UUID) {
            sweepDispositions[token] = disposition
        }

        func takeDisposition(for token: UUID) -> HealthSyncDisposition? {
            sweepDispositions.removeValue(forKey: token)
        }

        /// One anchored batch for a single category type: admit an account,
        /// fetch new samples since the committed anchor, import the foreign ones
        /// grouped by date, and commit this type's cursor only if the shared rule
        /// says the page is accounted for.
        ///
        /// Only ever entered via `runAnchoredSweep` (one sweep per type at a
        /// time). Each type is committed on its own evidence: a type whose page
        /// held does not ride a sibling type's success.
        @available(iOS 18.0, *)
        func performAnchoredSweep(type: HKCategoryType) async -> HealthSyncDisposition {
            guard let lease = try? admission?() else {
                HLLog.healthKit.info("cycle HK sweep refused — no admitted account")
                return .disabled
            }
            // The anchor prefix this importer owns belongs to the account it was
            // built for. An admitted owner that hashes to a different partition
            // is a different person, and the correct response is to do nothing.
            guard HealthKitService.partitionToken(for: lease.ownerID) == partitionToken else {
                HLLog.healthKit.error("cycle HK sweep refused — admitted owner is not this importer's partition")
                return .disabled
            }
            guard !Task.isCancelled else { return .deferred }
            await establishCursorPartitionIfNeeded(type, requiring: lease)

            let anchor = await committedAnchor(for: type, requiring: lease)
            do {
                // Fence 1 of 3 — before the query.
                try lease.requireCurrent()
                let result = try await fetch(type: type, anchor: anchor)
                // Fence 2 of 3 — an account replacement that landed during the
                // read must not let this page reach the wire under the new owner.
                try lease.requireCurrent()
                let writes = buildWrites(from: result.samples, identifier: type.identifier)
                let page = await drain(writes, requiring: lease)
                return await commitAnchor(result.newAnchor, for: type, page: page, requiring: lease)
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal == .cancelled ? .deferred : .expired
            } catch is CancellationError {
                return .deferred
            } catch {
                // Nothing is committed. A read that failed says nothing about the
                // window it was going to cover, so the anchor stays where it was.
                // Log counts and classes only — never values.
                HLLog.healthKit.error(
                    "cycle HK sweep failed: \(LogSanitizer.redact(type.identifier + " — " + String(describing: error)), privacy: .public)"
                )
                return .failed
            }
        }

        /// Worst-of over the per-type dispositions: one held type makes the whole
        /// refresh incomplete, because "the sweep ran" and "this account's cycle
        /// history is complete" are different statements.
        static func aggregate(_ results: [HealthSyncDisposition]) -> HealthSyncDisposition {
            let ranked: [HealthSyncDisposition] = [
                .failed, .expired, .deferred, .retryPersisted, .disabled, .unsupported, .succeeded
            ]
            for candidate in ranked where results.contains(candidate) {
                return candidate
            }
            return results.first ?? .succeeded
        }

        /// Drain a batch through the bulk endpoint (chunked at the repo cap) and
        /// report, per submitted index, what the server actually proved.
        ///
        /// The externalId UPSERT makes a doubly-delivered replay idempotent, so
        /// re-sending is safe — but it is not free, and it is certainly not
        /// evidence. A row the response never mentions, a `skipped` row, and an
        /// index outside the submitted range are all non-terminal, and each one
        /// becomes a durable outbox row before this type's cursor may move.
        func drain(
            _ writes: [CycleDayLogWrite],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            guard !writes.isEmpty else { return Self.emptyPage }
            var classifications = [HealthSyncAcceptanceClass?](repeating: nil, count: writes.count)
            var transportThrew = false

            for start in stride(from: 0, to: writes.count, by: CycleRepository.bulkCap) {
                let end = min(start + CycleRepository.bulkCap, writes.count)
                let slice = Array(writes[start ..< end])
                do {
                    // The actor-isolated form of `HealthSyncAuthenticatedLease
                    // .admitting(_:)`: that fence takes a non-`Sendable` closure,
                    // which an `actor` may not send. Same two-sided check,
                    // written out (07-04's precedent in the statistics sweep).
                    try lease.requireCurrent()
                    let result = try await repo.bulk(slice)
                    try lease.requireCurrent()
                    Self.apply(result, offset: start, sliceCount: slice.count, into: &classifications)
                    let imported = result.entries.filter { $0.status == .inserted || $0.status == .updated }.count
                    // M-7: both interpolations are pure row counts — operator-grade, no PII.
                    HLLog.healthKit
                        .debug("cycle HK import drained \(imported, privacy: .public)/\(slice.count, privacy: .public) rows") // swiftlint:disable:this hllog_public_privacy_interpolation
                } catch {
                    // A raised transport says nothing about individual rows: the
                    // request may never have been seen at all.
                    transportThrew = true
                    HLLog.healthKit.error(
                        "cycle HK bulk not accepted: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }

            let entries = writes.indices.map { index in
                HealthSyncEntryOutcome(
                    index: index,
                    stableIdentity: Self.stableIdentity(of: writes[index]),
                    classification: classifications[index]
                )
            }
            let held = writes.indices.filter { classifications[$0] != .terminalAccepted }
            guard !held.isEmpty else {
                return HealthSyncPageOutcome(
                    postedCount: writes.count,
                    entries: entries,
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: lease.isCurrent,
                    wasCancelled: false
                )
            }
            let persisted = await persistRetry(held.map { writes[$0] }, requiring: lease)
            return HealthSyncPageOutcome(
                postedCount: writes.count,
                entries: entries,
                transportThrew: transportThrew,
                durableRetryPersisted: persisted,
                durableRetryFailed: !persisted,
                leaseIsCurrent: lease.isCurrent,
                wasCancelled: Task.isCancelled
            )
        }

        /// Folds one bulk response into the page's per-index classification.
        ///
        /// `inserted` / `updated` / `duplicate` are the server's three success
        /// shapes for an upsert keyed on `cycle-hk:<date>`. `skipped` is not: the
        /// route reports it for a row it declined to write, and "declined" is not
        /// "stored". An index the response repeats, omits, or places outside the
        /// submitted range leaves its row unclassified, which holds.
        static func apply(
            _ response: CycleBulkResponse,
            offset: Int,
            sliceCount: Int,
            into classifications: inout [HealthSyncAcceptanceClass?]
        ) {
            for (index, classification) in acceptance(of: response, sliceCount: sliceCount).enumerated()
                where classification != nil
            {
                classifications[offset + index] = classification
            }
        }

        /// Per-index acceptance of one bulk response. `nil` means the row has no
        /// evidence at all — missing, repeated, or out of range.
        ///
        /// Pure + `static` so the rule can be driven without a HealthKit query
        /// or a network round-trip, which is the only way the missing/repeated
        /// shapes can be pinned at all: no fixture server emits them on demand.
        static func acceptance(of response: CycleBulkResponse, sliceCount: Int) -> [HealthSyncAcceptanceClass?] {
            var classifications = [HealthSyncAcceptanceClass?](repeating: nil, count: max(0, sliceCount))
            var seen = Set<Int>()
            for entry in response.entries {
                guard (0 ..< sliceCount).contains(entry.index) else { continue }
                guard seen.insert(entry.index).inserted else {
                    // A repeated index is not a second answer, it is an
                    // ambiguous one. Neither reading is evidence.
                    classifications[entry.index] = nil
                    continue
                }
                let accepted = entry.status == .inserted || entry.status == .updated || entry.status == .duplicate
                classifications[entry.index] = accepted ? .terminalAccepted : .nonterminal
            }
            return classifications
        }

        /// The write's own restart-stable identity — the date-keyed external id
        /// the server upserts on.
        static func stableIdentity(of write: CycleDayLogWrite) -> String {
            write.externalId ?? "cycle-hk:\(write.date)"
        }

        static var emptyPage: HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 0,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }

        /// Writes every day-log the server did not terminally accept as an
        /// owner-bound outbox row under a **derived** idempotency key: a process
        /// that dies between the enqueue and the cursor write rebuilds the same
        /// key on relaunch instead of minting a second operation.
        func persistRetry(
            _ writes: [CycleDayLogWrite],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> Bool {
            for write in writes {
                guard let envelope = HealthSyncRetryEnvelope(
                    ownerID: lease.ownerID,
                    source: lease.source,
                    stableIdentity: Self.stableIdentity(of: write)
                ) else {
                    return false
                }
                do {
                    // The actor-isolated form of the `admitting(_:)` fence.
                    try lease.requireCurrent()
                    try await repo.enqueueDurableDayLog(
                        write,
                        idempotencyKey: envelope.idempotencyKey,
                        requiringCurrentOwner: lease.ownerID
                    )
                    try lease.requireCurrent()
                } catch {
                    // No date, no field, no owner — only the fact that the
                    // durable write did not happen, which is what holds the
                    // cursor for this type.
                    HLLog.healthKit.error("cycle HK durable retry write failed — cursor holds")
                    return false
                }
            }
            return true
        }

        // MARK: - Anchor persistence (UserDefaults, per PROJECT_GUIDE.md battery rationale)

        func anchorKey(for type: HKCategoryType) -> String {
            anchorPrefix + type.identifier
        }

        /// The partition this admission may write for one category type.
        /// Owner-bound by construction: there is no path here that yields
        /// another account's key.
        static func cursorKey(
            for lease: HealthSyncAuthenticatedLease,
            type: HKCategoryType
        ) -> HealthSyncCursorKey? {
            let owner: HealthSyncOwnerLease = lease.owner
            return owner.cursorKey(typeIdentifier: type.identifier)
        }

        /// Adopts the pre-Phase-07 per-user, per-type anchor into the owner
        /// partition, once.
        ///
        /// `.provenOwner` is the honest claim: the legacy key is
        /// `hl.cycle.hk.anchor.<partitionToken(userID)>.<type>`, and the sweep has
        /// already refused unless the admitted owner hashes to exactly this
        /// importer's token. That equality *is* the proof. The adoption runs
        /// through the store's verified write, so an unverifiable migration fails
        /// closed and the partition collects nothing.
        func establishCursorPartitionIfNeeded(
            _ type: HKCategoryType,
            requiring lease: HealthSyncAuthenticatedLease
        ) async {
            guard let cursors,
                  let key = Self.cursorKey(for: lease, type: type),
                  !migratedPartitions.contains(key.storageKey) else { return }
            _ = try? await cursors.migrate(
                key,
                legacyKey: anchorKey(for: type),
                ownership: .provenOwner(lease.ownerID),
                requiring: lease
            )
            migratedPartitions.insert(key.storageKey)
        }

        /// The anchor this account's partition committed for one type, or the
        /// legacy per-user value when no durable store is wired.
        @available(iOS 18.0, *)
        func committedAnchor(
            for type: HKCategoryType,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HKQueryAnchor? {
            if let cursors, let key = Self.cursorKey(for: lease, type: type) {
                return await cursors.queryAnchor(for: key)
            }
            // W-HK-RELIABILITY H-2 — surface decode failures + controlled reset.
            return HealthKitAnchorArchive.loadAnchor(
                forKey: anchorKey(for: type),
                from: defaults,
                label: "cycle:\(type.identifier)"
            )
        }

        /// Commits this type's new anchor if — and only if — the shared rule
        /// permits it.
        ///
        /// There is no path here that writes an anchor without a decision. The
        /// durable store applies ``HealthSyncCursorPolicy/required`` internally;
        /// the un-wired fallback consults ``HealthSyncCursorPolicy/installed``
        /// directly, so a context without a cursor store is never *more*
        /// permissive than production.
        @available(iOS 18.0, *)
        func commitAnchor(
            _ anchor: HKQueryAnchor?,
            for type: HKCategoryType,
            page: HealthSyncPageOutcome,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncDisposition {
            guard let anchor else {
                return page.durableRetryPersisted ? .retryPersisted : .succeeded
            }
            let decision: HealthSyncCommitDecision
            if let cursors, let key = Self.cursorKey(for: lease, type: type),
               let blob = HealthKitAnchorArchive.encodeAnchor(anchor, label: "cycle:\(type.identifier)")
            {
                decision = await cursors.commit(page: page, anchor: blob, for: key, requiring: lease)
            } else {
                decision = HealthSyncCursorPolicy.installed.decide(page)
                if decision == .commit {
                    HealthKitAnchorArchive.saveAnchor(
                        anchor,
                        forKey: anchorKey(for: type),
                        to: defaults,
                        label: "cycle:\(type.identifier)"
                    )
                }
            }
            guard case let .hold(reason) = decision else {
                return page.durableRetryPersisted ? .retryPersisted : .succeeded
            }
            // A fixed enum case naming why the anchor did not move — operator-grade
            // by construction, and it carries no sample, value, or account.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("cycle HK anchor holds — \(reason.rawValue, privacy: .public)")
            switch reason {
            case .cancelled: return .deferred
            case .leaseLost: return .expired
            case .nonterminalEntry, .incompleteIndexCoverage, .retryPersistenceFailed: return .failed
            }
        }
    }

#endif
