import Foundation

// Audit B-4 (2026-09-10) — the tolerant half of `ServerMoodLevel`.
//
// `MoodEntry.init(from:)` decoded `mood` with a plain `try c.decode`, and the
// history, the insights window and the heat-map all arrive as ONE array. So a
// level the server adds after this build did not cost its own entry: it threw
// mid-row and took the whole PAGE with it, and the mood screen went blank with
// nothing said. The column is a free string on the server side (documented as
// `SUPER_GUT, GUT, OKAY, SCHLECHT, LAUSIG`), so nothing but this build's own
// enum was keeping the set closed.
//
// An unrecognised level now lands on `.unknown`. The entry keeps its id, its
// timestamp, its tags and its note, renders as a neutral chip, and states
// nothing about valence: `score` is `nil`, so it enters no mean, no trend
// point, no heat-map bucket and no Watch / widget glance. And it never goes
// back out — a mood write is composed from the picker, which offers named
// levels only, and `encode` refuses the sentinel so a future caller cannot
// invent a server `MoodLevel`.

public extension ServerMoodLevel {
    /// Audit B-4 — decodes an unrecognised server level onto ``unknown``
    /// instead of throwing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = ServerMoodLevel(rawValue: raw), known != .unknown else {
            UnknownServerEnumLog.noteFirstSighting(
                of: raw, vocabulary: "mood level", consequence: "entry kept, no score derived from it"
            )
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — every level the SERVER can actually send: `allCases` minus
    /// the decode-only ``unknown`` sentinel. The mood picker, the history
    /// filter and any round-trip lock read this.
    static var serverCases: [ServerMoodLevel] {
        allCases.filter { $0 != .unknown }
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire.
    ///
    /// `__UNKNOWN__` is not a server `MoodLevel`. Mood writes are composed from
    /// the picker (``serverCases``) and from `MoodEntryPatch`, so this throw is
    /// a tripwire for a future caller rather than a live branch — but
    /// `MoodEntry` is `Codable` in both directions (it is cached), so the
    /// branch has to exist.
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ServerMoodLevel.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension MoodEntry {
    /// Audit B-4 — the entries that carry a nameable level, in input order.
    ///
    /// The ONE place the exclusion rule lives, so a future surface cannot fold
    /// the sentinel into an aggregate by writing `map(\.score)` somewhere and
    /// coalescing the `nil` to a number.
    static func scored(_ entries: [MoodEntry]) -> [(entry: MoodEntry, score: Int)] {
        entries.compactMap { entry in entry.score.map { (entry, $0) } }
    }

    /// **Audit B-4 (fix round 1) — the ONE-SLOT rule, in one place.**
    ///
    /// The Home widget's glance and the watch complication each answer "your
    /// latest mood" with a single number, and an entry whose level this build
    /// cannot name has no number to put in that slot. Neither may fabricate one,
    /// and neither may let the sentinel BLANK the slot over a real reading that
    /// is still visible in the app — so both skip forward to the latest NAMEABLE
    /// entry of whatever window they were handed.
    ///
    /// They disagreed before this: the watch took the newest entry and answered
    /// `nil` when it was unnameable, under a comment claiming the widget's rule.
    /// The rule now lives here, so the two surfaces cannot drift again.
    ///
    /// `nil` only when no entry carries a nameable level.
    static func latestNameable(_ entries: [MoodEntry]) -> (entry: MoodEntry, score: Int)? {
        scored(entries).max(by: { $0.entry.recordedAt < $1.entry.recordedAt })
    }

    /// Audit B-4 — the arithmetic mean of the nameable levels, or `nil` when
    /// none of the entries carries one.
    ///
    /// `nil` is not `0` and not `3`: a window in which the app can name no level
    /// has no mood average, and saying so is the whole point of the sentinel.
    static func averageScore(of entries: [MoodEntry]) -> Double? {
        let scores = scored(entries).map { Double($0.score) }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
