import Foundation

/// **Phase 08 Plan 15 — the deliberate, ephemeral gate in front of engineering
/// detail.**
///
/// Notification tokens, APNs environments, banner-category identifiers, pending
/// local-request identifiers, background wake timestamps and HealthKit anchors
/// are support instruments. They belong in the binary — a user whose banner
/// never arrives has to be able to hand somebody a token prefix — but reaching
/// them must be an act, not a third tap from Settings.
///
/// **Why a value type held as view-local `@State`.** The alternative shapes
/// were all worse in the same way: a reference type in `AppContainer` outlives
/// the screen and has to be swept on logout (one more thing to forget); a
/// `UserDefaults` flag survives a cold launch, which is exactly the property a
/// support session must not have. A `struct` in `@State` cannot be reached by
/// anything the screen does not hand it, dies with the view, and is recreated
/// `.locked` on the next mount — so "resets on dismissal", "resets on logout"
/// (the whole authenticated shell unmounts) and "locked on cold launch" are all
/// the same one mechanism rather than three cleanup paths.
///
/// **Why two steps and not one.** `confirm()` is unreachable from `.locked`:
/// the only way into `.confirmed` is `requestConfirmation()` first, so the
/// consequence has been stated on screen before the second tap. A single
/// `unlock()` would make an accidental tap enough, which is the property this
/// gate exists to remove.
struct SupportDiagnosticsSession: Equatable, Sendable {
    /// The three states a support session can be in. There is deliberately no
    /// fourth — nothing here is "partly unlocked".
    enum Stage: Equatable, Sendable {
        /// Nothing engineering-facing is composed. Every mount starts here.
        case locked
        /// The consequence has been stated and the user has not answered yet.
        case confirming
        /// Redacted detail may be composed, for this mount only.
        case confirmed
    }

    private(set) var stage: Stage

    /// A fresh session is always locked. There is no initializer that takes a
    /// stage, so no caller — and no cold launch — can start unlocked.
    init() {
        stage = .locked
    }

    var isConfirmed: Bool {
        stage == .confirmed
    }

    var isAwaitingConfirmation: Bool {
        stage == .confirming
    }

    /// First step: state the consequence. A no-op from anywhere but `.locked`,
    /// so a double tap cannot walk the user back out of a live session.
    mutating func requestConfirmation() {
        guard stage == .locked else { return }
        stage = .confirming
    }

    /// Second step. Deliberately unreachable from `.locked`.
    mutating func confirm() {
        guard stage == .confirming else { return }
        stage = .confirmed
    }

    /// The session boundary: `onDisappear`, a cancelled confirmation, or any
    /// other reason the screen stops being the thing in front of the user.
    mutating func end() {
        stage = .locked
    }
}

/// Redaction for the values a confirmed session is allowed to compose.
///
/// The gate decides *whether* detail is shown; this decides *how much*. Both
/// halves are needed: a confirmed session that then prints a whole device token
/// has moved the leak rather than closed it.
enum SupportDiagnosticsRedaction {
    /// The marker that says something was cut. Kept as one symbol so a test can
    /// assert that a rendered fragment is never the whole value.
    static let elision = "…"

    /// At most `keeping` characters of `value`, always followed by the elision
    /// marker when anything was dropped. `nil` in, `nil` out — an absent value
    /// is its own answer and must not be rendered as an empty fragment.
    static func fragment(_ value: String?, keeping: Int = 8) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard keeping > 0 else { return elision }
        guard value.count > keeping else { return value }
        return String(value.prefix(keeping)) + elision
    }

    /// The trailing form, for values whose tail is the identifying part.
    static func tail(_ value: String?, keeping: Int = 8) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard keeping > 0 else { return elision }
        guard value.count > keeping else { return value }
        return elision + String(value.suffix(keeping))
    }
}
