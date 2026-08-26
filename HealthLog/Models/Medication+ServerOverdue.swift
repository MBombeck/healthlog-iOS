import Foundation

// **Parity 1.9 — the server-owned overdue predicate, per scheduled slot.**
//
// Lives in its own file rather than growing `Medication.swift`, which is already
// past the `file_length` budget (PROJECT_GUIDE.md: split into thematic extensions
// instead of growing).

public extension Medication {
    /// **Is THIS scheduled slot the one the server flagged as overdue?**
    ///
    /// The server owns overdue (`nextDueOverdue`, `verdict.ts:157-163`); it
    /// flags exactly one open slot per medication and addresses it by its
    /// instant (``nextDueAt``). A consumer that renders a per-slot list
    /// therefore has to ask "is this row that slot", not "is this row's time in
    /// the past" — the latter is the client recompute the project's own doctrine
    /// forbids (PROJECT_GUIDE.md: *Med-Compliance = Server-Dose-History-Ledger, kein
    /// Client-Recompute*).
    ///
    /// The `tolerance` absorbs sub-second wire/parse drift between an intake
    /// row's `scheduledAt` and the medication row's `nextDueAt`. It is slot
    /// IDENTITY matching — never an overdue judgement of its own.
    ///
    /// A slot the server has NOT flagged (an older missed dose that fell out of
    /// its catch-up band) is deliberately not overdue here: the server no longer
    /// considers it open or takeable, and painting it red anyway is exactly the
    /// divergence this closes.
    func isServerFlaggedOverdueSlot(_ scheduledAt: Date, tolerance: TimeInterval = 60) -> Bool {
        guard hasOpenOverdueDose, let due = nextDueAt else { return false }
        return abs(scheduledAt.timeIntervalSince(due)) <= tolerance
    }
}
