import Foundation
import SwiftData

// **#52 — server → local pen back-fill.**
//
// Sits in its own file for the `file_length` discipline (`GLP1LocalStore.swift`
// is at the 600-line cap). Everything here is one operation: replaying a server
// `MedicationInventoryItem` row into the on-device pen list.

public extension GLP1LocalStore {
    /// **Replay one server inventory row into the local pen list.**
    ///
    /// Keyed on `serverID`: an already-mirrored row is UPDATED in place (so a pen
    /// opened or used up on the web converges on device), an unknown row is
    /// INSERTED. This is the back-fill that was deliberately skipped in v0.12
    /// because the server row carried no `manufacturer` / `doseStrength` — since
    /// v1.31.0 (migration 0256) it does, so the pen detail level is no longer
    /// device-local.
    ///
    /// The caller decides whether a server row qualifies as a pen entry at all
    /// (see `PenInventoryStore.penDetail`); this method only persists what it is
    /// handed, and never fabricates a row out of a detail-less container.
    func upsertPenFromServer(
        serverID: String,
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        finishedAt: Date?,
        notes: String?
    ) throws {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.serverID == serverID }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            entry.medicationID = medicationID
            entry.manufacturer = manufacturer
            entry.doseStrength = doseStrength
            entry.dispensedAt = dispensedAt
            entry.firstUsedAt = firstUsedAt
            entry.finishedAt = finishedAt
            entry.notes = notes
            entry.syncedAt = .now
        } else {
            modelContext.insert(
                PenInventoryEntry(
                    medicationID: medicationID,
                    manufacturer: manufacturer,
                    doseStrength: doseStrength,
                    dispensedAt: dispensedAt,
                    firstUsedAt: firstUsedAt,
                    finishedAt: finishedAt,
                    notes: notes,
                    serverID: serverID,
                    syncedAt: .now
                )
            )
        }
        try modelContext.save()
    }
}
