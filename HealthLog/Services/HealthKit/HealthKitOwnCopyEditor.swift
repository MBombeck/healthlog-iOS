import Foundation
import os
#if canImport(HealthKit)
    import HealthKit
#endif

// MARK: - Own-copy editing (pure, HealthKit-free)

/// A HealthKit object as the own-copy editor sees it.
struct HealthKitCopyRecord: Sendable, Equatable {
    let objectID: UUID
    let typeIdentifier: String
    let externalUUID: String?
    let isFromThisApp: Bool
}

/// What a delete call reached: the objects that are gone (deleted now or no
/// longer there) and whether the call stopped on a failure.
struct HealthKitCopyDeletion: Sendable, Equatable {
    let gone: [UUID]
    let failed: Bool
}

/// Seam between the editor and HealthKit, so the selection is tested against a
/// store double holding own and foreign objects side by side.
protocol HealthKitCopyStore: Sendable {
    /// The subset of `typeIdentifiers` this app may write, and so delete.
    func authorizedTypes(_ typeIdentifiers: [String]) -> [String]
    /// Every own object of `typeIdentifiers` whose external UUID is one of `ids`.
    func copies(withExternalIDs ids: [String], typeIdentifiers: [String]) async throws -> [HealthKitCopyRecord]
    /// Deletes exactly these objects.
    func delete(_ records: [HealthKitCopyRecord]) async -> HealthKitCopyDeletion
}

/// One edit of HealthLog's copies of a reading, as the ledger keeps it. Ids,
/// type names and two facts about the edit, no values.
struct HealthKitPendingCopyEdit: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        /// The reading was deleted: its copies go.
        case remove
        /// The reading was changed: see ``HealthKitOwnCopyEditor/replacementAction(writeAllowed:contentChanged:)``.
        case replace
    }

    let kind: Kind
    let serverIDs: [String]
    let typeIdentifiers: [String]
    /// `MetricKind` raw value of the changed row (replace only).
    var metricKind: String?
    /// Value, unit or time changed (replace only). A note alone is no change.
    var contentChanged: Bool = false
    /// The changed row may reach Apple Health at all (the mirror's source rule).
    var mirrorEligible: Bool = false
}

/// Changing or deleting a reading in HealthLog left its copy in Apple Health
/// unchanged: the write contract knew only "create", and the server mirror
/// skips any row whose copy already exists. The editor removes the copies
/// HealthLog wrote for a reading, so the corrected value can be written anew
/// or the deleted one is gone.
///
/// It touches only objects that carry one of the reading's server ids as
/// external UUID **and** come from this app's own source. A sample another
/// app wrote, even one with a copied UUID, is never selected. A removal that
/// fails stays in the ledger and is retried before the next mirror pass, so
/// Apple Health converges on the server state.
struct HealthKitOwnCopyEditor: Sendable {
    /// What a change does to the existing copy.
    enum ReplacementAction: Equatable {
        /// The person's direction is not known right now: touch nothing, retry.
        case deferred
        /// Leave the copy as it is.
        case keep
        /// Remove the copy and write nothing.
        case remove
        /// Remove the copy and write the changed row.
        case removeAndRewrite
    }

    let store: any HealthKitCopyStore
    let ledger: HealthKitOwnCopyLedger

    /// Pure selection: own source and one of the server ids, nothing else.
    static func ownCopies(in records: [HealthKitCopyRecord], serverIDs: [String]) -> [HealthKitCopyRecord] {
        let ids = Set(serverIDs)
        return records.filter { record in
            guard record.isFromThisApp, let external = record.externalUUID else { return false }
            return ids.contains(external)
        }
    }

    /// Pure rule for a change. `writeAllowed` is `nil` when the direction is
    /// unknown. Where HealthLog may not write, a copy whose number stayed the
    /// same stays too; one whose value, unit or time changed goes, because a
    /// stale number in Apple Health would be a wrong health value.
    static func replacementAction(writeAllowed: Bool?, contentChanged: Bool) -> ReplacementAction {
        guard let writeAllowed else { return .deferred }
        if writeAllowed { return .removeAndRewrite }
        return contentChanged ? .remove : .keep
    }

    /// Removes the own copies of `edit`. Returns `true` when none is left.
    /// Without write access to any of its types HealthLog cannot have written
    /// a copy, so nothing starts and nothing lands in the ledger. Otherwise the
    /// edit is written to the ledger first and leaves it only on success.
    @discardableResult
    func remove(_ edit: HealthKitPendingCopyEdit) async -> Bool {
        let types = store.authorizedTypes(edit.typeIdentifiers)
        guard !edit.serverIDs.isEmpty, !types.isEmpty else {
            ledger.removePending(edit)
            return true
        }
        ledger.addPending(edit)
        do {
            let records = try await store.copies(withExternalIDs: edit.serverIDs, typeIdentifiers: types)
            let own = Self.ownCopies(in: records, serverIDs: edit.serverIDs)
            if !own.isEmpty {
                // Noted before the delete, one entry per object and type: the
                // deletion pages that follow must not tombstone a reading
                // HealthLog removed itself. A failed delete takes back exactly
                // the entries of the objects that are still there.
                let noted = ledger.noteSelfDeleted(own.compactMap { record in
                    record.externalUUID.map { (serverID: $0, typeIdentifier: record.typeIdentifier) }
                })
                let result = await store.delete(own)
                if result.failed {
                    let gone = Set(result.gone)
                    let kept = zip(own.filter { $0.externalUUID != nil }, noted)
                        .filter { !gone.contains($0.0.objectID) }
                        .map(\.1)
                    ledger.forgetSelfDeleted(kept)
                    HLLog.healthKit.error("Own-copy removal deferred: delete failed")
                    return false
                }
            }
            ledger.removePending(edit)
            return true
        } catch {
            HLLog.healthKit.error(
                "Own-copy removal deferred err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return false
        }
    }

    /// Applies a change. `write` writes the changed row and runs only for
    /// ``ReplacementAction/removeAndRewrite`` after a complete removal.
    @discardableResult
    func replace(
        _ edit: HealthKitPendingCopyEdit,
        writeAllowed: Bool?,
        write: (@Sendable () async throws -> Void)?
    ) async -> ReplacementAction {
        guard !store.authorizedTypes(edit.typeIdentifiers).isEmpty else {
            ledger.removePending(edit)
            return .keep
        }
        let action = Self.replacementAction(writeAllowed: writeAllowed, contentChanged: edit.contentChanged)
        switch action {
        case .deferred:
            ledger.addPending(edit)
        case .keep:
            ledger.removePending(edit)
        case .remove:
            await remove(edit)
        case .removeAndRewrite:
            guard await remove(edit), let write else { break }
            do {
                try await write()
            } catch {
                // The server mirror writes the current row on its next pass.
                HLLog.healthKit.error(
                    "Own-copy rewrite failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
        return action
    }

    /// Retries every edit that could not finish. A change runs again with
    /// the direction as known now; its rewrite is left to the mirror pass that
    /// follows, which writes the server's current row. Returns how many are left.
    @discardableResult
    func retryPending(writeAllowed: @Sendable (HealthKitPendingCopyEdit) async -> Bool?) async -> Int {
        for edit in ledger.pending() {
            switch edit.kind {
            case .remove:
                await remove(edit)
            case .replace:
                await replace(edit, writeAllowed: writeAllowed(edit), write: nil)
            }
        }
        return ledger.pending().count
    }
}

// MARK: - Ordering

/// Runs the copy edits of the app strictly one after another, in the order
/// they were handed in: a rewrite must never overtake the delete that follows
/// it for the same reading.
final class HealthKitCopyEditQueue: Sendable {
    static let shared = HealthKitCopyEditQueue()

    private let last = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        last.withLock { previous in
            let prior = previous
            previous = Task {
                await prior?.value
                await operation()
            }
        }
    }

    /// Waits for everything handed in so far.
    func drain() async {
        await last.withLock { $0 }?.value
    }
}

// MARK: - Ledger

/// Durable state of the own-copy editor: edits still to do, and one entry per
/// object HealthLog deleted itself (server id and type). Holds ids and
/// HealthKit type names only, no values. File-backed, readable after first
/// unlock, bounded, written under its lock.
final class HealthKitOwnCopyLedger: Sendable {
    struct SelfDeletion: Codable, Sendable, Equatable {
        let serverID: String
        let typeIdentifier: String
        let at: Date
    }

    private struct State: Codable, Sendable {
        var pending: [HealthKitPendingCopyEdit] = []
        var selfDeleted: [SelfDeletion] = []
    }

    /// How long a self-deletion is remembered. The deletion page of an
    /// anchored query arrives within the next passes; a week is generous.
    static let selfDeletionMemory: TimeInterval = 7 * 24 * 60 * 60
    /// Upper bounds; the oldest entries give way.
    static let maxPending = 500
    static let maxSelfDeleted = 2000

    static let shared = HealthKitOwnCopyLedger(url: defaultURL())

    private let url: URL?
    private let state: OSAllocatedUnfairLock<State>

    init(url: URL?) {
        self.url = url
        let loaded: State = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        state = OSAllocatedUnfairLock(initialState: loaded)
    }

    private static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("healthkit-own-copy-ledger.json", isDirectory: false)
    }

    func pending() -> [HealthKitPendingCopyEdit] {
        state.withLock { $0.pending }
    }

    func addPending(_ edit: HealthKitPendingCopyEdit) {
        update { state in
            guard !state.pending.contains(edit) else { return }
            state.pending.append(edit)
            if state.pending.count > Self.maxPending {
                state.pending.removeFirst(state.pending.count - Self.maxPending)
            }
        }
    }

    func removePending(_ edit: HealthKitPendingCopyEdit) {
        update { $0.pending.removeAll { $0 == edit } }
    }

    /// Notes one self-deletion per object. Returns the entries in input order.
    @discardableResult
    func noteSelfDeleted(_ objects: [(serverID: String, typeIdentifier: String)], now: Date = .now) -> [SelfDeletion] {
        let entries = objects.map { SelfDeletion(serverID: $0.serverID, typeIdentifier: $0.typeIdentifier, at: now) }
        update { state in
            state.selfDeleted += entries
            if state.selfDeleted.count > Self.maxSelfDeleted {
                state.selfDeleted.removeFirst(state.selfDeleted.count - Self.maxSelfDeleted)
            }
        }
        return entries
    }

    /// Takes back entries whose delete did not happen.
    func forgetSelfDeleted(_ entries: [SelfDeletion]) {
        update { state in
            for entry in entries {
                if let index = state.selfDeleted.firstIndex(of: entry) {
                    state.selfDeleted.remove(at: index)
                }
            }
        }
    }

    /// The ids of a deletion page of `typeIdentifier` that HealthLog did not
    /// delete itself. Each self-deletion of that id and type answers exactly
    /// one deleted object and is then used up; only the rest may become
    /// mirror tombstones.
    func withoutSelfDeleted(_ serverIDs: [String], typeIdentifier: String, now: Date = .now) -> [String] {
        let memory = Self.selfDeletionMemory
        return update { state in
            state.selfDeleted.removeAll { now.timeIntervalSince($0.at) > memory }
            var kept: [String] = []
            for id in serverIDs {
                if let index = state.selfDeleted.firstIndex(where: { $0.serverID == id && $0.typeIdentifier == typeIdentifier }) {
                    state.selfDeleted.remove(at: index)
                } else {
                    kept.append(id)
                }
            }
            return kept
        }
    }

    /// Wipes everything (logout): the ids belong to the account leaving.
    func clear() {
        update { $0 = State() }
    }

    @discardableResult
    private func update<Result: Sendable>(_ change: @Sendable (inout State) -> Result) -> Result {
        let url = url
        return state.withLock { current in
            let result = change(&current)
            // Written under the lock, so the file never ends on an older state.
            Self.persist(current, to: url)
            return result
        }
    }

    private static func persist(_ snapshot: State, to url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            HLLog.healthKit.error("Own-copy ledger write failed")
        }
    }
}

// MARK: - Live store

#if canImport(HealthKit)
    /// The live store: queries limited to this app's source, deletion by
    /// object id within that source, the blood-pressure correlation first.
    struct HealthStoreCopyStore: HealthKitCopyStore {
        let store: HKHealthStore

        private static let correlationIdentifier = HKCorrelationTypeIdentifier.bloodPressure.rawValue

        func authorizedTypes(_ typeIdentifiers: [String]) -> [String] {
            typeIdentifiers.filter { identifier in
                if identifier == Self.correlationIdentifier {
                    // The correlation is written through its two quantity types.
                    return [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
                        .allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
                }
                guard let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) else { return false }
                return store.authorizationStatus(for: type) == .sharingAuthorized
            }
        }

        func copies(withExternalIDs ids: [String], typeIdentifiers: [String]) async throws -> [HealthKitCopyRecord] {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: ids),
                HKQuery.predicateForObjects(from: HKSource.default())
            ])
            let thisApp = HKSource.default()
            var records: [HealthKitCopyRecord] = []
            for identifier in typeIdentifiers {
                guard let type = Self.sampleType(identifier) else { continue }
                for sample in try await samples(of: type, matching: predicate) {
                    records.append(HealthKitCopyRecord(
                        objectID: sample.uuid,
                        typeIdentifier: identifier,
                        externalUUID: sample.metadata?[HKMetadataKeyExternalUUID] as? String,
                        isFromThisApp: sample.sourceRevision.source == thisApp
                    ))
                }
            }
            return records
        }

        /// The correlation goes first. Whether HealthKit takes its child
        /// samples with it is left open: the children are looked up again
        /// afterwards, and one that is no longer there counts as gone.
        func delete(_ records: [HealthKitCopyRecord]) async -> HealthKitCopyDeletion {
            let ordered = records.filter { $0.typeIdentifier == Self.correlationIdentifier }
                + records.filter { $0.typeIdentifier != Self.correlationIdentifier }
            let identifiers = ordered.reduce(into: [String]()) { if !$0.contains($1.typeIdentifier) { $0.append($1.typeIdentifier) } }
            var gone: [UUID] = []
            for identifier in identifiers {
                guard let type = Self.sampleType(identifier) else { continue }
                let wanted = ordered.filter { $0.typeIdentifier == identifier }.map(\.objectID)
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    HKQuery.predicateForObjects(with: Set(wanted)),
                    HKQuery.predicateForObjects(from: HKSource.default())
                ])
                do {
                    let present = try await samples(of: type, matching: predicate)
                    let presentIDs = Set(present.map(\.uuid))
                    gone += wanted.filter { !presentIDs.contains($0) }
                    if !present.isEmpty {
                        try await store.delete(present)
                    }
                    gone += presentIDs
                } catch let error as HKError where error.code == .errorNoData {
                    gone += wanted
                } catch {
                    return HealthKitCopyDeletion(gone: gone, failed: true)
                }
            }
            return HealthKitCopyDeletion(gone: gone, failed: false)
        }

        /// Quantity and correlation types; anything else is not a measurement copy.
        static func sampleType(_ identifier: String) -> HKSampleType? {
            if identifier == correlationIdentifier {
                return HKCorrelationType(.bloodPressure)
            }
            return HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        }

        private func samples(of type: HKSampleType, matching predicate: NSPredicate) async throws -> [HKSample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: result ?? [])
                }
                store.execute(query)
            }
        }
    }
#endif
