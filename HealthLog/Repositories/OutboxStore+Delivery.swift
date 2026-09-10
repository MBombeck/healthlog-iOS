import Foundation
import SwiftData

// Audit B-2 / B-3 — the two row-state writes the fixed replay path needs, split
// out of `OutboxStore.swift` for `file_length` discipline (same reason
// `OutboxQueue+WriteAhead.swift` exists). Nothing here changed isolation: both
// members are still on the `@ModelActor` and still take only Sendable values.

public extension OutboxStore {
    /// **Audit B-2 — stamp a row as taken by the server.** Called the instant a
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

    /// **Audit B-3 — dead-letter one named row without touching its budget.**
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
}
