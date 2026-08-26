import Foundation

/// **W-THRESHOLD-NUDGE (v0.15.2) — the pure, MDR-safe out-of-range nudge decision.**
///
/// This is the single, regulatory-sensitive place that decides whether a calm,
/// retrospective nudge should be surfaced for a just-logged reading. It is a
/// **reflection of the user's own data against the user's / their data's own
/// ranges — NOT the app making a medical judgment.** Read the invariants below
/// as hard constraints; they exist because this is the app's most
/// regulatory-sensitive surface.
///
/// **MDR invariants (NON-NEGOTIABLE):**
/// 1. **No app-invented clinical thresholds.** The decision keys ONLY on the
///    server-computed verdict (`LabResultDTO.rangeStatus`) plus the bounds that
///    came from the server / the user's own biomarker catalog
///    (`referenceLow` / `referenceHigh`). The app NEVER encodes its own idea of
///    "normal glucose" — when the server reports `.inRange` / `.unknown`, or
///    there are no bounds, there is NO nudge.
/// 2. **Retrospective + factual only.** The produced copy states a fact about
///    the reading vs the range. It NEVER diagnoses, advises treatment, or
///    reassures — `ThresholdNudgeContent` carries only the value, the bounds,
///    and the non-diagnostic disclaimer.
/// 3. **Server authority wins — no double-nudge.** When `serverHasEscalated` is
///    true (the server's anomaly engine / a `SYSTEM_ALERT` already raised this
///    reading), the client DEFERS and emits no nudge of its own.
/// 4. **Opt-in.** Off by default; `isOptedIn == false` ⇒ no nudge, regardless
///    of everything else.
/// 5. **Debounce.** A standing breach (the same kind breaching the same bound
///    direction again) is suppressed via `alreadyNudgedForBreach`, so a chronic
///    out-of-range value does not nudge on every reading.
enum ThresholdNudgeEvaluator {
    /// Why a nudge was withheld. Surfaced for diagnostics / tests so each guard
    /// is provable; never shown to the user.
    enum SuppressReason: Equatable {
        /// The opt-in is off (default). No nudge.
        case optedOut
        /// The server reported the reading in-range. No nudge (and crucially, no
        /// "all clear" — absence of a nudge is NEVER an all-clear).
        case inRange
        /// The server could not place the reading against a range (`unknown` /
        /// no bounds). The app must NOT invent a threshold ⇒ no nudge.
        case noRange
        /// The server already escalated this reading (anomaly / SYSTEM_ALERT).
        /// Defer to the server — no double-nudge.
        case serverEscalated
        /// This standing breach already nudged. Debounced — no re-nudge.
        case debounced
    }

    /// The outcome of the pure decision.
    enum Decision: Equatable {
        /// Surface exactly ONE calm, retrospective nudge with this content.
        case nudge(ThresholdNudgeContent)
        /// Withhold the nudge, with the reason.
        case suppress(SuppressReason)
    }

    /// The pure decision. No side effects, no `UNUserNotificationCenter`, no
    /// network — every input is passed in so the call is fully testable.
    ///
    /// - Parameters:
    ///   - lab: the freshly-created (server-resolved) lab result. Its
    ///     `rangeStatus` is the SERVER's verdict and the only out-of-range
    ///     signal we ever act on.
    ///   - isOptedIn: the user's opt-in (default off).
    ///   - serverHasEscalated: `true` when the server already raised this
    ///     reading (anomaly / SYSTEM_ALERT) — defer to it.
    ///   - alreadyNudgedForBreach: `true` when this standing breach
    ///     (kind + direction) already produced a nudge — debounce.
    static func evaluate(
        lab: LabResultDTO,
        isOptedIn: Bool,
        serverHasEscalated: Bool,
        alreadyNudgedForBreach: Bool
    ) -> Decision {
        // Gate 1 — opt-in. Off by default; nothing fires unless the user asked.
        guard isOptedIn else { return .suppress(.optedOut) }

        // Gate 2 — server authority. If the server already escalated this exact
        // reading, we DEFER — never a double-nudge for the same condition.
        guard !serverHasEscalated else { return .suppress(.serverEscalated) }

        // Gate 3 — server verdict. We act ONLY on the server-computed status.
        // `.inRange` / `.unknown` ⇒ no nudge; we never invent a threshold.
        switch lab.rangeStatus {
        case .inRange:
            return .suppress(.inRange)
        case .unknown:
            return .suppress(.noRange)
        case .below, .above:
            break // out-of-range per the server — continue.
        }

        // Gate 4 — the breach must be backed by an actual bound. Belt-and-braces
        // against a malformed row that says `below`/`above` with no bound: with
        // no bound there is nothing factual to state, so we withhold rather than
        // fabricate a range.
        guard ThresholdNudgeContent.boundedValue(for: lab) != nil else {
            return .suppress(.noRange)
        }

        // Gate 5 — debounce a standing breach.
        guard !alreadyNudgedForBreach else { return .suppress(.debounced) }

        // All gates passed — emit ONE calm, retrospective, non-diagnostic nudge.
        return .nudge(ThresholdNudgeContent(lab: lab))
    }

    /// Stable debounce key for a (kind, breach-direction) pair, so a standing
    /// out-of-range value does not re-nudge on every reading. Keyed on the
    /// linked biomarker id when present (the user's catalog marker), else the
    /// analyte name — plus the breach direction, so a value that crosses from
    /// `above` to `below` is treated as a NEW breach and may nudge again.
    static func debounceKey(for lab: LabResultDTO) -> String? {
        let direction: String
        switch lab.rangeStatus {
        case .below: direction = "below"
        case .above: direction = "above"
        case .inRange, .unknown: return nil
        }
        let marker = lab.biomarkerId ?? lab.analyte.lowercased()
        guard !marker.isEmpty else { return nil }
        return "\(marker)#\(direction)"
    }
}
