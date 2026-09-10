import Foundation
import Synchronization

// Audit A-7 (2026-09-10) — why a module that is off is off.
//
// `GET /api/auth/me` has always carried a boolean `modules` map, and the app
// has always obeyed it: a `false` makes the row, the tile and the screen
// disappear. What the boolean cannot say is WHOSE decision that was. A person
// whose operator switched the labs module off instance-wide, and a person
// viewing someone else's record through a scoped sharing grant, both saw the
// same thing — a More tab with a row missing and a switchboard offering a
// switch that would not have moved anything.
//
// Server v1.38.15 answers that with `moduleAccess: { <key>: <state> }`, one
// state per module, alongside the unchanged booleans
// (`src/lib/sharing/module-disclosure.ts`). The invariant the server holds and
// every client may lean on is `modules[key] == (moduleAccess[key] ==
// "enabled")` — the map explains the boolean, it never contradicts it.
//
// The vocabulary is the server's and it will grow, so the enum is open in the
// decode direction exactly like `ServerMeasurementType` and `IntakeStatus`: an
// unrecognised token lands on ``unknown``, the map survives whole, and the
// person is told the honest thing — the module is off for a reason this build
// cannot name — instead of the map being dropped and the row vanishing
// silently all over again.

/// Audit A-7 — why a feature module is (not) available to the current user,
/// as resolved server-side (`moduleAccess`, server v1.38.15).
///
/// Precedence is resolved by the SERVER, outside-in: `unavailable` >
/// `not_granted` > `disabled` > `enabled`. The client never re-derives it — it
/// renders the state it is handed.
public enum ModuleAccessState: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// On. The client may paint the surface.
    case enabled
    /// The record's own switch is off — the person can turn it back on.
    case disabled
    /// The active account-sharing grant does not open this module (delegate
    /// session), or the module reads across the whole record under a scoped
    /// grant. Not the viewer's switch to move.
    case notGranted = "not_granted"
    /// The operator's instance-wide switch, or a code-level hard-off.
    case unavailable
    /// Decode-only sentinel for a token this build does not know. Never sent.
    case unknown = "__UNKNOWN__"

    /// Audit A-7 — decodes an unrecognised server token onto ``unknown``
    /// instead of throwing.
    ///
    /// `moduleAccess` decodes as a `[String: ModuleAccessState]`, and a throw
    /// from one value fails the WHOLE dictionary — which would take the map
    /// (and with it every reason) with it. That is the failure this init
    /// exists for.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = ModuleAccessState(rawValue: raw), known != .unknown else {
            UnknownModuleAccessStateLog.noteFirstSighting(of: raw)
            self = .unknown
            return
        }
        self = known
    }

    /// Audit A-7 — refuses to put ``unknown`` back on the wire. `__UNKNOWN__`
    /// is not a server access state; a client that sent it would be inventing
    /// one. No production path encodes this type (it is a response shape), so
    /// the throw is a tripwire for a future caller, not a live branch.
    public func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ModuleAccessState.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Audit A-7 — every state the SERVER can actually send: `allCases` minus
    /// the decode-only ``unknown`` sentinel.
    public static var serverCases: [ModuleAccessState] {
        allCases.filter { $0 != .unknown }
    }

    /// Audit A-7 — the boolean this state must agree with. The server's
    /// invariant is `modules[key] == (moduleAccess[key] == "enabled")`; this is
    /// that expression, named once.
    public var impliesEnabled: Bool {
        self == .enabled
    }

    /// Audit A-7 — whether a switchboard row may still offer its toggle.
    ///
    /// `disabled` is the person's own switch, so the row stays exactly as it is
    /// today (off, interactive). Every other off-state belongs to somebody else
    /// — the grant owner or the operator — and an inviting switch there would
    /// promise something the PATCH cannot deliver.
    public var offersSwitch: Bool {
        self == .enabled || self == .disabled
    }

    /// Audit A-7 — the catalogue key of the sentence explaining this state, or
    /// `nil` for ``enabled`` (nothing to explain).
    ///
    /// Kept as a raw dotted key rather than two parallel copies of the copy, so
    /// the same sentence serves a SwiftUI `LocalizedStringKey` and a plain
    /// `String` consumer (``offReason``) without being written twice.
    public var offReasonKey: String? {
        switch self {
        case .enabled: nil
        case .disabled: "module.access.off.disabled"
        case .notGranted: "module.access.off.notGranted"
        case .unavailable: "module.access.off.unavailable"
        case .unknown: "module.access.off.unknown"
        }
    }

    /// Audit A-7 — the localized sentence explaining this state, or `nil` for
    /// ``enabled``.
    public var offReason: String? {
        guard let offReasonKey else { return nil }
        return String(localized: String.LocalizationValue(offReasonKey))
    }
}

/// Audit A-7 — logs each unrecognised `moduleAccess` token **once per
/// process**.
///
/// The token is a server enum name (`not_granted`-shaped) — never a value,
/// never an identifier, never anything read off the record — so it is
/// operator-grade and logged `.public`: an operator reading a sysdiagnose has
/// to be able to see WHICH state to name next, and a redacted token cannot
/// tell them.
enum UnknownModuleAccessStateLog {
    private static let seen = Mutex<Set<String>>([])

    static func noteFirstSighting(of raw: String) {
        let isNew = seen.withLock { $0.insert(raw).inserted }
        guard isNew else { return }
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.warning(
            "Unknown module access state \(raw, privacy: .public) — module treated as off, reason unnamed"
        )
    }
}

/// Audit A-7 — logs a `modules` / `moduleAccess` DISAGREEMENT once per module.
///
/// The server's invariant says the two halves cannot disagree. If they ever do,
/// the boolean wins (it is the half every gate has obeyed since #30) and no
/// reason is shown — a wrong explanation is worse than none. The app does not
/// crash on it; it says so, once, with the module key and both halves, all of
/// which are wire vocabulary and safe to log `.public`.
enum ModuleAccessDisagreementLog {
    private static let seen = Mutex<Set<String>>([])

    static func note(wireKey: String, enabled: Bool, state: ModuleAccessState) {
        let isNew = seen.withLock { $0.insert(wireKey).inserted }
        guard isNew else { return }
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.warning(
            """
            Module \(wireKey, privacy: .public): modules=\(enabled, privacy: .public) \
            disagrees with moduleAccess=\(state.rawValue, privacy: .public) — boolean wins, no reason shown
            """
        )
    }
}
