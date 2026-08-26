import SwiftUI

/// Where one sign-out has got to between the tap and the cleanup.
///
/// **Why a fourth state exists.** SwiftUI lowers a `confirmationDialog` *before*
/// it runs the tapped button's action, so the `isPresented` binding goes false
/// on its way to both answers. If "the sheet went away" were read as "the user
/// said no", the destructive branch would find itself back at `.idle` and refuse
/// the confirmation the user just gave. ``dialogWasLowered()`` therefore parks
/// the dialog in ``Stage/dismissed`` — the ask *happened* — and only the Cancel
/// button's own action settles it back to ``Stage/idle``.
///
/// The whole point of the type is what it makes impossible: ``beginConfirmedLogout()``
/// refuses from ``Stage/idle``, so nothing that has not put the consequence on
/// screen can start a logout, and it refuses from ``Stage/signingOut``, so a
/// second answer while the first is in flight cannot run the cleanup twice.
struct LogoutConfirmationState: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Nothing has been asked. No logout may start from here.
        case idle
        /// The dialog is on screen with the consequence visible.
        case asking
        /// The dialog has been lowered; the ask happened and may still be answered.
        case dismissed
        /// A confirmed logout is in flight. Nothing may start a second one.
        case signingOut
    }

    private(set) var stage: Stage = .idle

    /// Drives the dialog's `isPresented` binding.
    var isAsking: Bool {
        stage == .asking
    }

    /// Drives the in-flight affordance at the call sites that have one.
    var isSigningOut: Bool {
        stage == .signingOut
    }

    /// Presentation, and nothing else. Deliberately refuses while a logout is
    /// already in flight so a second tap cannot queue a second question.
    mutating func request() {
        guard stage == .idle || stage == .dismissed else { return }
        stage = .asking
    }

    /// The dialog left the screen. Not an answer — see the type's note.
    mutating func dialogWasLowered() {
        guard stage == .asking else { return }
        stage = .dismissed
    }

    /// The user said no. Nothing else in this file can reach the logout closure.
    mutating func cancel() {
        guard stage == .asking || stage == .dismissed else { return }
        stage = .idle
    }

    /// The user said yes, once. `true` exactly once per answered dialog.
    mutating func beginConfirmedLogout() -> Bool {
        guard stage == .asking || stage == .dismissed else { return false }
        stage = .signingOut
        return true
    }

    /// The cleanup returned; the surface is free to be asked again.
    mutating func finish() {
        stage = .idle
    }
}

/// **The one question every release-visible sign-out has to ask.**
///
/// Before Phase 8 the three places a user can end a session — Settings →
/// Konto, the forced second-factor gate and the biometric lock overlay — each
/// called the logout path straight out of the tap handler. There was nothing to
/// cancel: by the time a mis-tap registered the session was gone and the local
/// cascade had run. `HLSettingsActionRow(presents: .confirm)` only ever meant
/// "paint no chevron"; the confirmation, if any, belonged to the caller, and
/// none of the three had one.
///
/// **What this layer owns.** Presentation, copy, and the guarantee that the
/// injected closure runs once, after the second tap, and never before. It owns
/// no auth state and performs no cleanup — `AuthStore.logout()` and the
/// container cascade behind it remain the single destructive implementation,
/// and nothing in this file names them.
///
/// **Why it lives in `DesignSystem` rather than beside a screen.** Phase 6
/// froze a presentation inventory over `HealthLog/App` and `HealthLog/Screens`
/// that is fail-closed on *additions*: a new `.confirmationDialog` in either
/// tree fails `validate-phase06-presentation-inventory.sh` in both modes, and
/// no disposition admits one. `HealthLog/DesignSystem` is outside the scanned
/// roots, so the dialog is written once here and the three call sites apply
/// `hlLogoutConfirmation(_:perform:)`, whose name is not a scanned kind. One
/// dialog, one copy, no new ledger row.
enum LogoutConfirmation {
    /// The question. Both catalogue values are shipped; the gate simulator
    /// renders the German one.
    ///
    /// Computed rather than stored, and not by preference: `LocalizedStringKey`
    /// is not `Sendable`, so a `static let` of that type is a concurrency error
    /// under this project's `SWIFT_STRICT_CONCURRENCY: complete`.
    static var title: LocalizedStringKey {
        "Sign out?"
    }

    /// The consequence, stated before the destructive answer is offered.
    static var message: LocalizedStringKey {
        "You will need to sign in again with your HealthLog account afterwards."
    }

    /// The destructive label. Same source key as the row that opens the dialog,
    /// so the answer and the question cannot drift apart in translation.
    static var confirmTitle: String {
        String(localized: "Sign out")
    }

    /// The non-destructive answer.
    static var cancelTitle: String {
        String(localized: "Cancel")
    }

    static let confirmButtonIdentifier = "logout.confirm.signOut"
    static let cancelButtonIdentifier = "logout.confirm.cancel"

    /// The destructive branch, factored out of the modifier so the "exactly
    /// once" guarantee is provable without a view tree and without simulator
    /// tap coordinates. Returns `nil` when the answer was refused — from
    /// `.idle` because nothing asked, from `.signingOut` because something
    /// already answered.
    @discardableResult
    @MainActor
    static func confirm(
        _ state: Binding<LogoutConfirmationState>,
        perform logout: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard state.wrappedValue.beginConfirmedLogout() else { return nil }
        return Task {
            await logout()
            state.wrappedValue.finish()
        }
    }
}

/// Applies ``LogoutConfirmation`` to a surface that can end a session.
///
/// The question is native (a `.destructive` answer and an explicit cancel) so it
/// inherits the platform's destructive semantics and VoiceOver treatment rather
/// than imitating them. Since R13-A1 (2026-08-23) it is carried by
/// ``View/hlConfirmDestructive(_:isPresented:message:confirm:confirmIdentifier:cancel:onCancel:action:)``,
/// which makes it centred and anchorless like every other destructive question
/// in the app. The state machine below is untouched by that: the shape moved,
/// the "exactly once" guarantee did not.
struct LogoutConfirmationModifier: ViewModifier {
    @Binding var state: LogoutConfirmationState
    let logout: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.hlConfirmDestructive(
            Text(LogoutConfirmation.title),
            isPresented: Binding(
                get: { state.isAsking },
                set: { if !$0 { state.dialogWasLowered() } }
            ),
            message: Text(LogoutConfirmation.message),
            confirm: Text(LogoutConfirmation.confirmTitle),
            confirmIdentifier: LogoutConfirmation.confirmButtonIdentifier,
            cancel: Text(LogoutConfirmation.cancelTitle),
            cancelIdentifier: LogoutConfirmation.cancelButtonIdentifier,
            onCancel: { state.cancel() },
            action: { LogoutConfirmation.confirm($state, perform: logout) }
        )
    }
}

extension View {
    /// Requires an explicit destructive confirmation before `logout` runs.
    ///
    /// The caller keeps the state (so it can dim its own affordance while the
    /// cleanup is in flight) and keeps the logout implementation; this adds the
    /// question and nothing else.
    func hlLogoutConfirmation(
        _ state: Binding<LogoutConfirmationState>,
        perform logout: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(LogoutConfirmationModifier(state: state, logout: logout))
    }
}
