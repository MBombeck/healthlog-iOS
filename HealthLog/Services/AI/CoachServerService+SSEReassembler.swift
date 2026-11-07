import Foundation

/// Split out of `CoachServerService.swift` (1.5 COACH-R) so the new frame
/// handling fits without the file growing past its lint baseline.
extension CoachServerService {
    /// **BH-final-diff H5 — SSE multi-`data:`-line reassembly.** A single SSE
    /// event may legitimately span MULTIPLE `data:` lines that must be re-joined
    /// with `\n` before decoding; the previous per-line decoder `try?`-decoded
    /// each physical line, so a split frame silently dropped its tokens.
    ///
    /// But the app's own streams (and the test stubs) emit one COMPLETE `data:`
    /// JSON object per line with NO blank-line separator between events. A naive
    /// "accumulate until blank line" reassembler would merge those back-to-back
    /// frames into one undecodable blob. So the dispatch is **decode-driven**:
    ///
    ///   - Buffered `data:` lines are joined with `\n` and emitted when (a) a
    ///     blank line (the spec event terminator) is seen, or (b) a NEW `data:`
    ///     line arrives while the already-buffered payload ALONE forms a complete
    ///     (decodable) event — proving the previous event ended without a blank
    ///     line. A genuinely split frame's partial buffer does NOT decode, so it
    ///     keeps accumulating until the joined payload is whole.
    ///
    /// Tolerant of proxy newline variants: a line is fed already split on
    /// `\n`/`\r\n` boundaries; a lone `\r` left on a line is stripped. Non-`data:`
    /// SSE fields (`event:`, `id:`, `retry:`, comments `:`) are ignored.
    struct SSEEventReassembler {
        private var dataLines: [String] = []
        /// Predicate that returns `true` when the joined buffer already forms a
        /// complete (decodable) event — drives the no-blank-line dispatch.
        private let isComplete: (String) -> Bool

        /// - Parameter isComplete: returns `true` when the candidate joined
        ///   payload decodes to a full event. Defaults to "non-empty" for callers
        ///   that only need blank-line framing.
        init(isComplete: @escaping (String) -> Bool = { !$0.isEmpty }) {
            self.isComplete = isComplete
        }

        /// Feed one physical SSE line. Returns a completed event payload when the
        /// line terminates one (a blank line, OR a new `data:` line that follows
        /// an already-complete buffer); otherwise `nil`.
        mutating func feed(_ rawLine: some StringProtocol) -> String? {
            // Strip a trailing lone CR (CRLF transports where only `\n` split).
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                return flush()
            }
            // SSE comment line (starts with ':') — ignore.
            guard !line.hasPrefix(":") else { return nil }
            guard let colon = line.firstIndex(of: ":") else {
                // A field name with no value (e.g. a bare "data") — per spec the
                // value is empty; only meaningful for `data`.
                if line == "data" { dataLines.append("") }
                return nil
            }
            let field = line[line.startIndex ..< colon]
            guard field == "data" else { return nil } // ignore event:/id:/retry:
            var value = String(line[line.index(after: colon)...])
            // Per spec, a single leading space after the colon is stripped.
            if value.hasPrefix(" ") { value.removeFirst() }
            // Decode-driven dispatch: if the buffer ALREADY forms a complete
            // event, this new `data:` line begins the NEXT event — emit the prior
            // one first (no blank-line separator), then start fresh.
            var completed: String?
            if !dataLines.isEmpty, isComplete(dataLines.joined(separator: "\n")) {
                completed = flush()
            }
            dataLines.append(value)
            return completed
        }

        /// Emit any buffered event payload (joined with `\n`) and reset. Returns
        /// `nil` when nothing is buffered. Call at end-of-stream to flush a final
        /// event that was not newline-terminated.
        mutating func flush() -> String? {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }
    }
}
