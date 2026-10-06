import Foundation

// INT-A (#115 / 0.3) — the rows the replay parks are visible.
//
// A parked row (`lastError` starting with `parked:`, see
// `HealthKitReplayParked`) is a HealthKit reading whose importer already moved
// its anchor past it: the server could not map its type yet, the owning module
// was off, or the batch came back with an unexplained 4xx. It stays in the
// queue, uncounted, until the server takes it. Sync Diagnostics counts these
// rows so "waiting" is never mistaken for "uploaded".

extension OutboxQueue {
    /// Live rows of `ownerID` the replay parked.
    func parkedRowCount(ownerID: String) async -> Int {
        let rows = await (try? resolvedStore().snapshot()) ?? []
        return rows.filter { row in
            row.ownerUserID == ownerID
                && (row.lastError?.hasPrefix(HealthKitReplayParked.lastErrorPrefix) ?? false)
        }.count
    }
}
