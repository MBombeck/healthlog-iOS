import Foundation

/// In-memory conversation history for the Mini-Coach (C3).
///
/// Contract per the operator brief:
///   - 8-turn cap (a "turn" = one user line + one contributor line OR a
///     refused-sentinel for one user line)
///   - No cross-session persistence (lives in the actor's heap only)
///   - Refused turns are recorded as `.refused` sentinels with no
///     original output preserved
///
/// The history is *only* surfaced to the model via
/// ``MiniCoachPrompt/userTurn(ask:category:boundContext:history:locale:)``;
/// the actor never persists or exports it.
public actor MiniCoachHistory {
    public static let turnCap = 8

    private var turns: [HistoryLine] = []
    /// Counts every completed turn — user-line *plus* the matching
    /// contributor / refused entry. Surfaced via ``completedTurns()``.
    ///
    /// UI-Standard R15 (U1) — bis hierher trieb dieser Zähler zusätzlich die
    /// Fünf-Zug-Kadenz des Pauschalsatzes, den ``MiniCoachService`` an jede
    /// fünfte Antwort hängte. Der Satz ist gefallen, die Kadenz (`disclaimerEvery`)
    /// mit ihm.
    private var completedTurnCount = 0

    public init() {}

    /// Record an exchange. The user line is always stored; the second
    /// argument is either the contributor reply (kept verbatim, the
    /// post-hoc filter has already run when this is called) or `nil`
    /// for refused turns (no original output leaks).
    public func record(userAsk: String, assistantReply: String?) {
        // Each pair counts as ONE turn. We push the user line first, then
        // either the contributor line or a refused sentinel.
        turns.append(HistoryLine(role: .user, text: userAsk))
        if let reply = assistantReply {
            turns.append(HistoryLine(role: .assistant, text: reply))
        } else {
            turns.append(HistoryLine(role: .refused, text: ""))
        }
        completedTurnCount += 1
        trimToCap()
    }

    /// Returns the trimmed history rendered as the lines list the
    /// prompt builder consumes. Always at most ``turnCap`` turns.
    public func snapshot() -> [HistoryLine] {
        turns
    }

    /// Test-introspection: number of completed turns since the
    /// session was created. Not reset by `trimToCap()` — that only
    /// drops *visible* history.
    public func completedTurns() -> Int {
        completedTurnCount
    }

    /// Test-introspection: visible turn count (after trim).
    public func visibleTurnCount() -> Int {
        // Each "turn" is two lines (user + reply-or-refused).
        turns.count / 2
    }

    /// Reset everything. The brief is explicit: no cross-session
    /// persistence — but inside one session a hard reset is still
    /// useful (operator might wire it to a "neues Gespräch"-button in
    /// C5 / C6).
    public func reset() {
        turns.removeAll()
        completedTurnCount = 0
    }

    // MARK: - Helpers

    private func trimToCap() {
        // Each turn is two entries; cap by turn count, not raw entries.
        let maxEntries = Self.turnCap * 2
        if turns.count > maxEntries {
            let dropCount = turns.count - maxEntries
            turns.removeFirst(dropCount)
        }
    }
}
