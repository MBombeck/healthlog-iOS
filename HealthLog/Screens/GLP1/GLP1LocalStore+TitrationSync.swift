import Foundation
import SwiftData

// **#169 — the upload marker of a titration step.**
//
// Own file for the `file_length` discipline (`GLP1LocalStore.swift` sits at
// the 600-line cap). `serverID` and `syncedAt` have been on
// `TitrationStepEntry` since schema v1, always `nil` until now, so the marker
// needs no migration: a row from a 1.7 build simply reads as "not uploaded".

public extension GLP1LocalStore {
    /// Marks a step as uploaded under the server's id.
    func setTitrationServerID(localID: String, serverID: String) throws {
        let descriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.id == localID }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.serverID = serverID
        entry.syncedAt = .now
        try modelContext.save()
    }

    /// Drops every local copy of a server step.
    func deleteTitrationSteps(serverID: String) throws {
        let target: String? = serverID
        let descriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.serverID == target }
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
