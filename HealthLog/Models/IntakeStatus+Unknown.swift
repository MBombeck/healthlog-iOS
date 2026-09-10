import Foundation
import Synchronization

// Audit B-5 (2026-09-10) — the tolerant half of `IntakeStatus`, the one wire
// enum the medication ledger is counted from.
//
// The enum was closed in both directions and lost data in both.
//
// Reading: `MedicationIntake.status` is a plain `try c.decode`, and the
// today-ledger arrives as ONE array (`[MedicationIntake]`). A status the server
// adds after this build therefore threw mid-row and took the whole page with it
// — every sibling dose of that day gone, with nothing said. The server has
// grown this enum before (`missed` is exactly such an addition, kept as a read
// value for precisely this reason).
//
// Counting: the standalone mirror stores the status as a bare String, and five
// call sites resolved it with `?? .taken`. A row a LATER build wrote, or a data
// import carried in, was read back as a dose actually administered — it raised
// the compliance rate, anchored the recurrence engine's rolling cadence, and
// uploaded to the server as a real administration on adopt-on-pair.
//
// So the enum stops being closed. An unrecognised value lands on `.unknown`,
// the row keeps its id, its medication and its scheduled instant — and states
// nothing beyond that. `.unknown` is a BUCKET, not a disposition: two rows on
// it may carry two different tokens, so it is never taken, never skipped, never
// pending, and it never goes back out on the wire (`writableRawValue` refuses
// it, exactly as it refuses the terminal `.missed`).

public extension IntakeStatus {
    /// Audit B-5 — decodes an unrecognised status token onto ``unknown``
    /// instead of throwing.
    ///
    /// This is the seam for the whole read path: the today-ledger array, the
    /// paginated intake events and the offline cache all decode through it, and
    /// none of them has a per-row tolerant wrapper to fall back on.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(stored: raw, origin: "wire")
    }

    /// Audit B-5 — resolves a status raw value read back from LOCAL storage
    /// (`LocalIntakeEntry.status`, a bare String column) onto a case.
    ///
    /// Replaces `IntakeStatus(rawValue:) ?? .taken`. A value this build cannot
    /// name is the one thing it is certainly NOT: a dose the user confirmed.
    init(stored raw: String, origin: StaticString = "stored") {
        guard let known = IntakeStatus(rawValue: raw), known != .unknown else {
            UnknownIntakeStatusLog.noteFirstSighting(of: raw, origin: origin)
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-5 — `true` for a status that means "this dose was administered".
    ///
    /// The single place the counting rule lives, so a future case cannot be
    /// folded into the taken bucket by writing `!= .skipped` somewhere. The
    /// sentinel is not taken; it is also not skipped and not pending, so it
    /// never enters a numerator and never removes an expectation from a
    /// denominator (the schedule owns that side).
    var countsAsTaken: Bool {
        self == .taken
    }
}

/// Audit B-5 — logs each unrecognised intake-status token **once per process**.
///
/// A ledger page full of one new status would otherwise write one identical
/// warning per row. The token is a status enum name (`missed`-shaped) — never a
/// value, a note, a dose or an identifier — so it is operator-grade and logged
/// `.public`: an operator reading a sysdiagnose has to be able to see WHICH
/// status to name next, and a redacted token cannot tell them.
enum UnknownIntakeStatusLog {
    private static let seen = Mutex<Set<String>>([])

    static func noteFirstSighting(of raw: String, origin: StaticString) {
        let isNew = seen.withLock { $0.insert("\(origin):\(raw)").inserted }
        guard isNew else { return }
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.warning(
            "Unknown medication intake status \(raw, privacy: .public) — row kept, counted as neither taken nor skipped"
        )
    }
}
