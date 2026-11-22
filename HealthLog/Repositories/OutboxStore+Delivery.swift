import Foundation
import SwiftData

// The two row-state writes the fixed replay path needs, split
// out of `OutboxStore.swift` for `file_length` discipline (same reason
// `OutboxQueue+WriteAhead.swift` exists). Nothing here changed isolation: both
// members are still on the `@ModelActor` and still take only Sendable values.

public extension OutboxStore {
    /// **Stamp a row as taken by the server.** Called the instant a
    /// dispatch succeeds and BEFORE the row is deleted, so a delete that fails
    /// leaves behind a row the next drain finishes locally instead of re-sending.
    func markDelivered(id: UUID) throws {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return }
        op.delivered = true
        try modelContext.save()
    }

    /// **Dead-letter one named row without touching its budget.**
    /// The sweep in ``markDeadLetters(maxAttempts:minAge:now:)`` abandons a row
    /// that spent its retries; this abandons a row whose *stored payload* this
    /// build can no longer decode, which is not a server verdict and must not be
    /// deleted. Same destination: retained on disk, out of the replay snapshot,
    /// recoverable via ``resubmit(id:)``. Returns `true` when a live row matched.
    @discardableResult
    func markDeadLetter(id: UUID, lastError: String?, now: Date) throws -> Bool {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id && !$0.deadLettered }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return false }
        op.deadLettered = true
        op.deadLetteredAt = now
        if let lastError {
            op.lastError = String(lastError.prefix(256))
        }
        try modelContext.save()
        return true
    }

    /// Whether the row is still on disk, live or dead-lettered.
    func exists(id: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetchCount(descriptor) > 0
    }

    /// Takes the note off a row, so the replay reads it as never sent.
    func clearLastError(id: UUID) throws {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return }
        op.lastError = nil
        try modelContext.save()
    }
}

/// One row the store had to delete unread: its kind and its owner, nothing of
/// what it held.
struct OutboxUnreadableDiscard: Sendable, Equatable {
    let kindRaw: String
    let ownerUserID: String?
}

extension OutboxStore {
    /// Deletes rows whose payload can never be opened again (the key that
    /// sealed them is gone, or the blob is damaged) and remembers each one, so
    /// the loss reaches the user and not only the log. The caller saves.
    func discardUnreadable(_ rows: [OutboxOperation]) {
        for row in rows {
            // A row the server already has loses nothing by going.
            if !row.delivered {
                unreadableDiscards.append(OutboxUnreadableDiscard(kindRaw: row.kindRaw, ownerUserID: row.ownerUserID))
            }
            modelContext.delete(row)
        }
    }

    /// Hands over, once, the deleted rows that belonged to `owner`. Rows of
    /// another account wait for their owner to sign in.
    func takeUnreadableDiscards(ownedBy owner: String) -> [OutboxUnreadableDiscard] {
        let owned = unreadableDiscards.filter { $0.ownerUserID == owner }
        unreadableDiscards.removeAll { $0.ownerUserID == owner }
        return owned
    }
}
