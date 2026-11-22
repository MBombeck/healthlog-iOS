import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

// Doses deleted in Apple Health leave the server too (#181, contract #182
// part B §4: `DELETE /api/medications/intake/by-external-ids`, soft delete,
// stock refunded).
//
// The dose import reads by date through the ledger, which cannot tell "deleted"
// from "no longer shared" (a medication taken off the HealthLog list hides its
// doses the same way). So deletions come from their own anchored query on the
// dose-event type, which reports exactly what HealthKit deleted. Its first read
// only sets the anchor: an installation that updates sends nothing for
// deletions that happened before.

/// A reader that can report deleted dose events. A separate protocol so test
/// doubles of ``AppleHealthMedicationReading`` stay as they are.
protocol AppleHealthDoseDeletionReading: Sendable {
    /// The dose-event UUIDs deleted since `anchor` and the anchor after them.
    /// A `nil` anchor reads nothing but the anchor.
    func readDoseDeletions(after anchor: Data?) async throws -> AppleHealthDoseDeletionPage
}

struct AppleHealthDoseDeletionPage: Sendable, Equatable {
    let deletedIDs: [String]
    let anchor: Data?
}

/// The deletion anchor and the deletions still owed, per dose partition,
/// beside the dose ledger in the same storage.
struct AppleHealthDoseDeletionState: Codable, Sendable, Equatable {
    static let formatVersion = 1
    static let maxPending = 5000

    var version = Self.formatVersion
    var anchor: Data?
    var pending: [String] = []

    static func storageKey(for ledger: AppleHealthDoseLedger) -> String {
        ledger.storageKey + ".deletions"
    }

    static func load(_ storage: HealthSyncCursorStorage, ledger: AppleHealthDoseLedger) -> AppleHealthDoseDeletionState {
        guard let data = storage.read(storageKey(for: ledger)),
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == formatVersion else { return AppleHealthDoseDeletionState() }
        return state
    }

    @discardableResult
    func save(_ storage: HealthSyncCursorStorage, ledger: AppleHealthDoseLedger) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        storage.write(Self.storageKey(for: ledger), data)
        return Self.load(storage, ledger: ledger) == self
    }

    /// `ids` added to what is owed, without repeats, bounded.
    mutating func owe(_ ids: [String]) {
        var seen = Set<String>()
        pending = Array((pending + ids).filter { !$0.isEmpty && seen.insert($0).inserted }.suffix(Self.maxPending))
    }
}

extension AppleHealthMedicationImporter {
    /// Reads the doses deleted since the last pass and sends them to the
    /// delete route, or keeps them while the route is closed or out of reach.
    /// Never touches the dose import's own progress beyond taking the deleted
    /// doses out of it.
    func forwardDoseDeletions(ledger: AppleHealthDoseLedger, requiring lease: HealthSyncAuthenticatedLease) async {
        guard let deletions = deletionReader else { return }
        var state = AppleHealthDoseDeletionState.load(ledgerStorage, ledger: ledger)
        do {
            try lease.requireCurrent()
            let page = try await deletions.readDoseDeletions(after: state.anchor)
            try lease.requireCurrent()
            state.owe(page.deletedIDs)
            state.anchor = page.anchor ?? state.anchor
            // The anchor moves only together with what it owes.
            guard state.save(ledgerStorage, ledger: ledger) else { return }
        } catch {
            HLLog.healthKit.info("APPLE-MED deleted doses not read this pass")
            return
        }
        guard !state.pending.isEmpty, deletesRouteOpen() else { return }
        // The ledger is the dose import's outbox: a deleted dose leaves it
        // before its delete, so no later sweep posts it again (a re-post would
        // insert a new dose on the server).
        do {
            try ledger.forget(Set(state.pending), requiring: lease)
        } catch {
            return
        }
        let ids = state.pending
        do {
            for start in stride(from: 0, to: ids.count, by: AppleHealthDeleteDomain.maxIDsPerRequest) {
                let end = min(start + AppleHealthDeleteDomain.maxIDsPerRequest, ids.count)
                try lease.requireCurrent()
                try await repo.deleteAppleHealthIntakes(Array(ids[start ..< end]))
            }
        } catch let error where !AppleHealthDeleteRefusal.isFinal(error) {
            // Kept; the next pass sends them again (the route is idempotent).
            HLLog.healthKit.info("APPLE-MED dose deletions kept for a later pass")
            return
        } catch {
            // Refused for good: the same body would earn the same answer.
        }
        state.pending = []
        state.save(ledgerStorage, ledger: ledger)
    }
}

extension MedicationsRepository {
    /// `DELETE /api/medications/intake/by-external-ids` (server 1.48.0):
    /// soft delete of this account's Apple Health doses by dose-event UUID.
    func deleteAppleHealthIntakes(_ externalIDs: [String]) async throws {
        guard !externalIDs.isEmpty else { return }
        let req: APIRequest<EmptyResponse> = try .delete(
            AppleHealthDeleteDomain.medicationIntake.path,
            body: ExternalIDBatch(externalIds: externalIDs)
        )
        _ = try await api.send(req)
    }
}

#if canImport(HealthKit)
    extension AppleHealthMedicationReader: AppleHealthDoseDeletionReading {
        func readDoseDeletions(after anchor: Data?) async throws -> AppleHealthDoseDeletionPage {
            let start = anchor.flatMap { HealthKitAnchorArchive.decodeAnchor($0, label: "dose-deletions") }
            let store = HKHealthStore()
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: HKObjectType.medicationDoseEventType(),
                    predicate: nil,
                    anchor: start,
                    limit: HKObjectQueryNoLimit
                ) { _, _, deleted, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    // The first read (no anchor) only sets the anchor.
                    let ids = start == nil ? [] : (deleted ?? []).map(\.uuid.uuidString)
                    let blob = newAnchor.flatMap { HealthKitAnchorArchive.encodeAnchor($0, label: "dose-deletions") }
                    continuation.resume(returning: AppleHealthDoseDeletionPage(deletedIDs: ids, anchor: blob))
                }
                store.execute(query)
            }
        }
    }
#endif
