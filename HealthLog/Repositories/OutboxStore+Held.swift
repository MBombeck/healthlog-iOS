import Foundation
import SwiftData

// W1 (1.3.0, #126 1.1, HealthLog#1173) — the store half of the rows the
// replay holds back: "Erneut senden" and the one-time 1.2.0 update path. See
// `OutboxQueue+Backlog.swift`.

extension OutboxStore {
    /// **W1 (1.3.0) — "Erneut senden" for a live row the replay holds back.**
    /// Clears the retry budget, the back-off stamp and the park marker, so the
    /// next pass sends the row again. Dead-lettered rows are not touched here
    /// (they have ``resubmit(id:)``). Returns `true` when a live row matched.
    ///
    /// 1.4 (S2) — an `unconfirmed:` marker stays, as in
    /// ``requeueRetriableRowsOverBudget(maxAttempts:keepingMarkers:)``: the
    /// row may already be on the server, and the marker dates the first
    /// unconfirmed send. Cleared, the next unreadable answer restarted the
    /// 23-hour window and a re-send could go out past the server's 24-hour
    /// idempotency cache as a second record.
    @discardableResult
    func rearm(id: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id && !$0.deadLettered }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return false }
        op.attempts = 0
        op.lastAttemptAt = nil
        if OutboxReplayService.unconfirmedSince(op.lastError) == nil {
            op.lastError = nil
        }
        try modelContext.save()
        return true
    }

    /// **W1 (1.3.0) — the update path from 1.2.0.** Up to 1.2.0 a timeout or a
    /// lost connection counted against the retry budget like any other
    /// retriable failure, and a row whose budget ran out was held, unsent, for
    /// the seven days before the dead-letter sweep could act. Every live row
    /// over budget whose last note is not a park or unconfirmed marker got
    /// there through retriable failures only (the server never said no), so it
    /// gets its budget back. The note itself stays for diagnosis. Returns the
    /// number of rows re-queued.
    func requeueRetriableRowsOverBudget(maxAttempts: Int, keepingMarkers markers: [String]) throws -> Int {
        let threshold = maxAttempts
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.attempts >= threshold && !$0.deadLettered }
        )
        let due = try modelContext.fetch(descriptor).filter { row in
            !row.delivered && !markers.contains { row.lastError?.hasPrefix($0) ?? false }
        }
        guard !due.isEmpty else { return 0 }
        for row in due {
            row.attempts = 0
            row.lastAttemptAt = nil
        }
        try modelContext.save()
        return due.count
    }
}
