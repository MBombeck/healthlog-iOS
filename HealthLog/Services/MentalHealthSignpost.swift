import Foundation
import os

/// **SAFETY — private, on-device-only signpost for the mental-health screener.**
///
/// The PHQ-9 / GAD-7 surface is a clinical-safety surface with a HARD privacy
/// contract (INV-C §4 / §7): the item answers and the item-9 self-harm flag are
/// NEVER logged. We still want a private, Instruments-oriented heartbeat that "a
/// screener was submitted" so a debug session can confirm the flow ran — but it
/// must carry NO PII: no instrument-specific copy, no score, and crucially NO
/// item-9 flag value.
///
/// `OSSignposter` is the right tool: signposts are ephemeral, Instruments-scoped
/// markers, not persistent unified-log lines. This emits a single bare event with
/// a static name and ZERO arguments — there is nothing here for `LogSanitizer` to
/// redact because nothing sensitive is ever passed in.
enum MentalHealthSignpost {
    private static let signposter = OSSignposter(
        subsystem: "dev.healthlog.app",
        category: "mental-health"
    )

    /// Mark that a screener submit was initiated. Deliberately argument-free —
    /// records neither the instrument, the answers, nor the item-9 flag.
    static func submitStarted() {
        signposter.emitEvent("screener.submit")
    }
}
