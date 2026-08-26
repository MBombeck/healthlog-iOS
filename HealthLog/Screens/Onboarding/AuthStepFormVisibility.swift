import Foundation

/// #65 / 13-02 — what the app knows about the server's web-handoff login route.
///
/// It replaces a `Bool` because the `Bool` could not say "not yet asked", and
/// that missing third case is the K5 race: the probe fires on the same beat as
/// the step switch (`OnboardingFlow.handleServerURLContinue`), so the auth
/// step's first render happens while the answer is still in flight. A `false`
/// then means both "no web login here" and "we have not looked", and the screen
/// latched its password form open on the strength of the second one.
enum WebLoginAvailability: Equatable, Sendable {
    /// The probe is in flight. Not the same as unavailable.
    case probing
    /// The server serves the web-handoff contract and its login route answers.
    case available
    /// Version too old, route missing, unreachable, or the login route leads
    /// somewhere this device cannot follow.
    case unavailable
}

/// 13-02 — the single rule that decides what the sign-in step shows.
///
/// A value, not a method on the view, so the sequence a device actually walks
/// (step switch → first render → probe lands → fallback tap) can be driven in
/// a test. `ServerAuthStep` builds one of these per body pass from its live
/// inputs and asks it; there is no second copy of the rule anywhere.
struct AuthStepFormVisibility: Equatable, Sendable {
    /// The native form structurally cannot bind this host's passkeys /
    /// password manager, so the browser handoff is the intended primary door.
    let prefersWebHandoff: Bool
    let availability: WebLoginAvailability
    /// Has the password form been opened — by the fallback link, by the
    /// self-hosted passkey CTA, or by a dead-ended web leg?
    let latched: Bool

    /// The browser CTA replaces the native passkey CTA and the divider.
    var showsWebHandoffCTA: Bool {
        prefersWebHandoff && availability == .available
    }

    /// The password form. Under a live handoff CTA it is the fallback and
    /// stays closed until something opens it; everywhere else it is the
    /// primary door and is simply present.
    var showsEmailSection: Bool {
        showsWebHandoffCTA ? latched : true
    }

    /// Whether the password form's `.onAppear` may latch itself open.
    ///
    /// **This one line is K5.** The old answer was an unconditional yes, and
    /// the probe lands *after* the first render, so the form latched itself
    /// open while the answer was still in flight. When the CTA then arrived,
    /// the form was already open and "sign in with password instead" had
    /// nothing left to reveal — a control that observably did nothing.
    ///
    /// The form may latch only where no handoff CTA can still arrive: either
    /// this host never had one, or the probe has come back and said no.
    /// `.probing` on a handoff host is precisely the state in which latching
    /// is a guess, and the guess was wrong.
    var mayLatchOnAppear: Bool {
        !prefersWebHandoff || availability == .unavailable
    }

    /// 16-02 (K5, the polish half) — whether opening the password form should
    /// carry the keyboard into it.
    ///
    /// Only a deliberate reveal does. "Stattdessen mit Passwort in der App
    /// anmelden" is a request for the password form, so the caret belongs in
    /// its first field; the form that was there all along, and the one
    /// ``mayLatchOnAppear`` opens because no handoff CTA can still arrive, are
    /// not requests for a keyboard — raising one over them would cover the very
    /// CTA the user has not decided about yet.
    ///
    /// A value rather than a line inside a button closure, for the reason the
    /// rest of this type exists: the sequence a device actually walks can then
    /// be driven in a test.
    static func revealCarriesFocus(wasShowing: Bool) -> Bool {
        !wasShowing
    }
}
