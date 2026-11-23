import Foundation

// **#191 — one vocabulary for a dose, everywhere.**
//
// The term list the server team fixed for 1.49.0 (actions as verbs, states as
// participles) and the glyph rule, in one Foundation-only place shared by the
// app, the widgets, the Live Activity and the Watch. Card, ledger, widget,
// Live Activity, Watch, notification actions and Siri read their words and
// glyphs from here, so "Ausgelassen", "Jetzt fällig" and "Geplant" cannot come
// back on one surface while the others moved on.
//
// The glyph rule: clock for pending and due, alert for overdue, triangle for
// missed (and for an overdue dose late in its window), check for taken (amber
// when taken late), skip-forward for skipped. Never a check on a dose that is
// still to take.

/// What a dose is, in the server's words (`state` on today rows and on
/// dose-history rows), plus "taken late" as its own phase.
public enum MedicationDosePhase: String, Sendable, CaseIterable, Codable {
    /// Wire `upcoming`: not yet due. Shown as "Pending".
    case pending
    case due
    case overdue
    case taken
    /// Wire `taken` with `takenLate: true`.
    case takenLate
    case skipped
    case missed

    /// The phase of a wire `state`, `nil` for a word this build does not know.
    public init?(wire state: String?, takenLate: Bool = false) {
        switch state?.lowercased() {
        case "upcoming", "pending": self = .pending
        case "due": self = .due
        case "overdue": self = .overdue
        case "taken": self = takenLate ? .takenLate : .taken
        case "skipped": self = .skipped
        case "missed": self = .missed
        default: return nil
        }
    }

    /// `true` while the dose can still be taken.
    public var isOpen: Bool {
        switch self {
        case .pending, .due, .overdue, .missed: true
        case .taken, .takenLate, .skipped: false
        }
    }

    /// `true` for the open phases the dashboard counts as "a dose is open now"
    /// and "next doses" (#191 point 10): `upcoming`, `due` or `overdue`.
    public var isUpcomingOrDue: Bool {
        self == .pending || self == .due || self == .overdue
    }

    /// The state's word (term list, #191).
    public var title: String {
        switch self {
        case .pending: String(localized: "med.dose.state.pending", defaultValue: "Pending")
        case .due: String(localized: "med.dose.state.due", defaultValue: "Due")
        case .overdue: String(localized: "med.dose.state.overdue", defaultValue: "Overdue")
        case .taken: String(localized: "med.dose.state.taken", defaultValue: "Taken")
        case .takenLate: String(localized: "med.dose.state.taken_late", defaultValue: "Taken late")
        case .skipped: String(localized: "med.dose.state.skipped", defaultValue: "Skipped")
        case .missed: String(localized: "med.dose.state.missed", defaultValue: "Missed")
        }
    }
}

/// The glyph of a dose (#191 glyph rule).
public enum MedicationDoseGlyph: String, Sendable, Equatable {
    case clock
    case alert
    case triangle
    case check
    case skipForward

    /// The SF Symbol.
    public var systemName: String {
        switch self {
        case .clock: "clock"
        case .alert: "exclamationmark.circle"
        case .triangle: "exclamationmark.triangle"
        case .check: "checkmark.circle.fill"
        case .skipForward: "forward.end"
        }
    }
}

/// How loud a dose reads. The surfaces map it to their own colour tokens.
public enum MedicationDoseTone: String, Sendable, Equatable {
    /// Pending: secondary text.
    case quiet
    /// Due: the accent.
    case due
    /// Overdue: amber.
    case warning
    /// Missed, and overdue late in its window: red.
    case critical
    /// Taken on time: green.
    case success
    /// Taken late: amber.
    case late
    /// Skipped: secondary text.
    case muted
}

/// Phase, glyph and tone of one dose.
public struct MedicationDoseLook: Sendable, Equatable {
    public let phase: MedicationDosePhase
    public let glyph: MedicationDoseGlyph
    public let tone: MedicationDoseTone

    /// - Parameter lateInWindow: an overdue dose late in its window reads
    ///   with the triangle (and red), like a missed one.
    public init(phase: MedicationDosePhase, lateInWindow: Bool = false) {
        self.phase = phase
        switch phase {
        case .pending:
            glyph = .clock
            tone = .quiet
        case .due:
            glyph = .clock
            tone = .due
        case .overdue:
            glyph = lateInWindow ? .triangle : .alert
            tone = lateInWindow ? .critical : .warning
        case .taken:
            glyph = .check
            tone = .success
        case .takenLate:
            glyph = .check
            tone = .late
        case .skipped:
            glyph = .skipForward
            tone = .muted
        case .missed:
            glyph = .triangle
            tone = .critical
        }
    }

    /// The look of a wire `state`; `nil` for an unknown word.
    public init?(wire state: String?, takenLate: Bool = false, lateInWindow: Bool = false) {
        guard let phase = MedicationDosePhase(wire: state, takenLate: takenLate) else { return nil }
        self.init(phase: phase, lateInWindow: lateInWindow)
    }

    /// The word for the state.
    public var title: String {
        phase.title
    }
}

/// The actions and sentences of the term list (#191).
public enum MedicationDoseWords {
    public static var take: String {
        String(localized: "med.dose.action.take", defaultValue: "Take")
    }

    public static var skip: String {
        String(localized: "med.dose.action.skip", defaultValue: "Skip")
    }

    public static var undo: String {
        String(localized: "med.dose.action.undo", defaultValue: "Undo")
    }

    /// "Remind me later (30 min)".
    public static func snooze(minutes: Int) -> String {
        String(
            format: String(localized: "med.dose.action.snooze", defaultValue: "Remind me later (%lld min)"),
            minutes
        )
    }

    /// "Reminder snoozed until 08:30".
    public static func snoozedUntil(_ time: String) -> String {
        String(format: String(localized: "med.dose.state.snoozed_until", defaultValue: "Reminder snoozed until %@"), time)
    }

    /// The hint under a missed dose.
    public static var missedStillCounts: String {
        String(localized: "med.dose.state.missed_still_counts", defaultValue: "Taking it now still counts, as late.")
    }

    /// "Log intake", the form and the entry.
    public static var logIntake: String {
        String(localized: "med.dose.form.title", defaultValue: "Log intake")
    }

    /// "{name}: taken, {time}".
    public static func toastTaken(name: String, time: String) -> String {
        String(format: String(localized: "med.dose.toast.taken", defaultValue: "%1$@: taken, %2$@"), name, time)
    }

    /// "{name}: skipped".
    public static func toastSkipped(name: String) -> String {
        String(format: String(localized: "med.dose.toast.skipped", defaultValue: "%@: skipped"), name)
    }
}
