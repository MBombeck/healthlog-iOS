import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

// MARK: - AuthStore state enums

// Moved out of `AuthStore.swift` (file_length-Disziplin, PROJECT_GUIDE.md) so the
// #65 web-handoff store leg can grow the main file without tipping the
// SwiftLint `file_length` error at 1000 lines. Both types are self-contained
// (no private-member access), so this is a pure move — call sites keep using
// `AuthStore.Phase` / `AuthStore.AdoptUploadState` unchanged.

public extension AuthStore {
    enum Phase: Equatable {
        case unknown
        case unauthenticated
        /// Intermediate server-branch phase: server-login succeeded + token is
        /// in Keychain, but the user still has to walk the HealthKit and
        /// Notifications permission steps inside `OnboardingFlow`. `RootView`
        /// keeps showing `OnboardingFlow` while `phase == .authenticating(...)`
        /// so those steps actually render. `OnboardingFlow.advanceFromNotifications`
        /// is the single site that promotes this to `.authenticated(user)`.
        ///
        /// Fixes iOS issue #10 (B): pre-v0.6.0.9 the server branch flipped
        /// straight to `.authenticated`, which made `RootView` swap the
        /// onboarding view for `AuthenticatedShell` before SwiftUI could
        /// reconcile the HealthKit / Notifications steps. The standalone
        /// branch was always correct because `enterStandaloneMode()` only
        /// fires AFTER the permission steps; `.authenticating` brings the
        /// server branch into structural parity with that lifecycle.
        case authenticating(User)
        case authenticated(User)
        /// Local-only standalone mode — the user has chosen `OnboardingMode.standalone`
        /// and there is no server account / token. `AuthenticatedShell` renders the
        /// main UI gated on `syncMode.isStandalone`. v0.4.1.
        case standalone

        /// True iff the app is "inside" the main shell (paired-auth or standalone).
        /// Used by biometric-lock gate so local-only users also get re-auth
        /// after Background → Foreground transitions. `.authenticating` is
        /// explicitly **not** unlock-eligible — the user is still inside the
        /// onboarding flow and `AuthenticatedShell` has not mounted yet.
        public var isUnlockEligible: Bool {
            switch self {
            case .authenticated, .standalone: true
            case .unknown, .unauthenticated, .authenticating: false
            }
        }
    }

    // Phase 08 Wave 1 — the owner a post-authentication decision belongs to.
    //
    // See `AuthStore.authenticatedRouteOwner` below; it lives outside this
    // `public extension` because the admission epoch it reads is internal.

    /// v0.11 W4 — calm, observable state of the adopt-on-pair upload. The UI
    /// (onboarding/W5) shows a quiet "moving your data over…" indicator from
    /// this; it stays `.idle` for every normal paired login (the upload only
    /// runs on a standalone→paired transition). See `adoptUploadHook`.
    enum AdoptUploadState: Equatable, Sendable {
        case idle
        case uploading(AdoptUploadProgress)
        case done(AdoptUploadProgress)
        /// Recoverable — the local mirror is intact and an idempotent retry
        /// re-runs safely. The associated progress is how far the move got.
        case failed(AdoptUploadProgress)
    }
}

extension AuthStore {
    /// **Phase 08 Wave 1** — the authenticated owner a post-authentication route
    /// decision belongs to, in the Wave-0 vocabulary.
    ///
    /// `nil` whenever no server account is admitted: `.unknown`,
    /// `.unauthenticated` and `.standalone` have no owner, and standalone in
    /// particular has no server to ask, so there is no completion to look up.
    ///
    /// The generation is what makes a decision **perishable**. It is the
    /// admission epoch `phase`'s own `didSet` already maintains, so a result
    /// computed for `(id, 4)` cannot be applied once the app is on `(id, 5)` —
    /// same account, different admission, with a logout, a terminal 401 or a
    /// server switch in between. Without it, "the owner did not change" and "the
    /// session did not change" look identical, which is exactly the gap a
    /// same-account re-login opens.
    var authenticatedRouteOwner: PostAuthenticationRouteInput.Owner? {
        guard let id = Self.sessionOwner(in: phase) else { return nil }
        return PostAuthenticationRouteInput.Owner(id: id, generation: authSessionGeneration)
    }
}

// MARK: - One authentication transition (Phase 09 / plan 09-07)

extension AuthStore {
    /// **A perishable authentication attempt.**
    ///
    /// Every flow that can end in an `AuthSession` — password, MFA (TOTP,
    /// recovery code and security key), registration, passkey, native SSO and
    /// the hosted web-handoff login — opens exactly one of these and publishes
    /// through it. It is captured **before** the flow's first suspension and
    /// re-read **after** it, which is the only window an authentication result
    /// can go stale in.
    ///
    /// **Two fences, for 09-06's reason rather than a new one.**
    ///
    /// * ``generation`` — the newest attempt wins. Cancellation cannot stand in
    ///   for this: a flow that has already returned from its `await` is not
    ///   cancelled, it is merely *late*. Nor can the account boundary:
    ///   ``AuthStore/loginWithSSO(anchor:)`` and
    ///   ``AuthStore/loginWithWebLogin(anchor:)`` deliberately do not hold it
    ///   while their web sheet is up, because holding it across an unbounded
    ///   modal would block sign-out and account deletion for the sheet's whole
    ///   lifetime.
    /// * ``entryPhase`` together with ``admissionGeneration`` — the account
    ///   situation the attempt began in. A generation alone cannot catch a
    ///   same-generation account change: `enterStandaloneMode()`,
    ///   `beginServerPairing()`, `handleUnauthorized()` and the web-deletion
    ///   reconciliation's terminal publication each decide the account
    ///   *without* taking the authentication boundary, and none of them moves
    ///   the attempt epoch. The phase alone is not enough either — a sign-out
    ///   followed by a same-owner sign-in returns the phase to an equal value
    ///   while moving the admission epoch — so both halves are kept.
    ///
    /// The shape is `ForegroundSession`'s (09-06) at a different boundary, and
    /// the re-read is the one `reconcilePendingWebDeletion()` already performs
    /// around its own probe.
    struct AuthAttempt {
        let generation: UInt64
        let entryPhase: Phase
        let admissionGeneration: UInt64
    }

    /// Opens an attempt: raises the working state, clears the transient error
    /// the previous attempt may have left on the form, and captures both fences.
    func beginAuthAttempt() -> AuthAttempt {
        authAttemptGeneration &+= 1
        publishWorkingState(true)
        publishError(nil)
        return AuthAttempt(
            generation: authAttemptGeneration,
            entryPhase: phase,
            admissionGeneration: authSessionGeneration
        )
    }

    /// Both fences, checked together — never one of them.
    func isCurrent(_ attempt: AuthAttempt) -> Bool {
        attempt.generation == authAttemptGeneration
            && attempt.entryPhase == phase
            && attempt.admissionGeneration == authSessionGeneration
    }

    /// **The single post-session state transition.** Every flow's success path
    /// ends here, so "an authenticated session was accepted" is one statement
    /// with one fence rather than seven assignments with none.
    @discardableResult
    func acceptSession(_ session: AuthSession, for attempt: AuthAttempt) -> Bool {
        guard isCurrent(attempt) else {
            HLLog.auth.warning("A late authentication result was refused — the attempt is no longer current.")
            return false
        }
        // A session supersedes any challenge that raised it (the TOTP and
        // security-key paths already did this; the other five now do too).
        clearMfaState()
        // 13-02 — and it supersedes any fallback a previous dead end opened:
        // a signed-in user has no fallback left to take.
        clearPasswordFallback()
        admitAuthenticating(session.user)
        return true
    }

    /// **13-02.** The web leg's way back, published so the auth step can show
    /// the password form to a user who has just been returned from a browser
    /// that led nowhere.
    ///
    /// Fenced exactly like ``failAttempt(_:for:)`` — and for the same reason.
    /// The web sheet deliberately does not hold the account boundary while it
    /// is up (holding it across an unbounded modal would block sign-out), so a
    /// leg can come back *late*; a late leg must not reopen a form the newest
    /// attempt has already moved past.
    @discardableResult
    func revealPasswordFallback(for attempt: AuthAttempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        publishPasswordFallbackRevealed(true)
        return true
    }

    func clearPasswordFallback() {
        publishPasswordFallbackRevealed(false)
    }

    /// The second-factor branch: password-accepted-but-challenged, and the SSO
    /// callback's `mfa_ticket`. Fenced identically — the phase stays pre-auth.
    @discardableResult
    func acceptMfaChallenge(ticket: String, methods: [MfaMethod], for attempt: AuthAttempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        beginMfaChallenge(ticket: ticket, methods: methods)
        return true
    }

    /// A benign user/system dismissal: the spinner stops and **no** banner is
    /// raised. Deliberately does not touch `mfaChallenge`, so a cancelled
    /// security-key sheet leaves the challenge up.
    func acceptBenignCancellation(for _: AuthAttempt) {
        HLLog.auth.debug("Auth-Flow vom Nutzer abgebrochen — kein Fehlerbanner.")
    }

    /// Maps a benign user/system passkey-sheet cancellation to
    /// `HLError.canceled` (which the shared classifier swallows without a
    /// banner) and passes every other error through untouched. `.unknown` and
    /// `.notInteractive` are folded in alongside `.canceled` because the system
    /// reports a dismissed-without-selection sheet under those codes on some iOS
    /// builds — none of them is a real failure the user should see a red banner
    /// for. Moved here from `AuthStore.swift` by 09-07: it is a classifier, and
    /// the classifiers now live together.
    /// Whether a verify failure means the MFA TICKET is dead (expired / invalid /
    /// consumed / over-cap) — eject to the password form — as opposed to a wrong
    /// code, which is retriable. The TOTP/recovery verify path surfaces the 401
    /// body (see `APIClient.preserves401Body`); the dead-ticket sentinel is the
    /// server message "Invalid or expired challenge", whereas a wrong code is
    /// "Invalid code". Matched on stable substrings ("expired"/"challenge") that a
    /// wrong-code message carries neither of. Bare `.unauthorized` (e.g. the
    /// WebAuthn verify leg, which is not body-preserving) is treated as
    /// NOT-dead → retriable, so a rejected assertion stays on the sheet. Moved
    /// here from `AuthStore.swift` by 09-07 for the same reason as below.
    static func indicatesDeadMfaTicket(_ err: HLError) -> Bool {
        guard case let .server(status, _, message) = err, status == 401 else { return false }
        let normalized = message.lowercased()
        return normalized.contains("expired") || normalized.contains("challenge")
    }

    static func normalizePasskeyError(_ error: any Error) -> any Error {
        #if canImport(AuthenticationServices)
            if let asError = error as? ASAuthorizationError {
                switch asError.code {
                case .canceled, .unknown, .notInteractive:
                    return HLError.canceled
                default:
                    return error
                }
            }
        #endif
        return error
    }

    /// The single terminal-error transition: publish the mapped error, leave the
    /// phase alone. A late attempt publishes nothing.
    @discardableResult
    func failAttempt(_ error: HLError, for attempt: AuthAttempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        publishError(error)
        return true
    }

    /// Lowers the working state **iff** this is still the newest attempt.
    ///
    /// Only the attempt fence applies here: if a newer attempt is running, its
    /// spinner is not this one's to clear; but if the account situation moved
    /// underneath a still-newest attempt, nobody else will clear it.
    func finishAuthAttempt(_ attempt: AuthAttempt) {
        guard attempt.generation == authAttemptGeneration else { return }
        publishWorkingState(false)
    }

    /// begin → run → classify → finish, shared by all six flows.
    ///
    /// `classify` exists for the MFA legs alone, whose failure routing decides
    /// between "stay on the sheet and retry" and "the ticket is dead, go back to
    /// the password form"; everything else takes the default mapping.
    func runAttempt(
        classify: (@MainActor (HLError, AuthAttempt) -> Void)? = nil,
        _ body: @MainActor (AuthAttempt) async throws -> Void
    ) async {
        let attempt = beginAuthAttempt()
        defer { finishAuthAttempt(attempt) }
        do {
            try await body(attempt)
        } catch let err as HLError where err == .canceled {
            acceptBenignCancellation(for: attempt)
        } catch let err as HLError {
            if let classify {
                classify(err, attempt)
            } else {
                failAttempt(err, for: attempt)
                HLLog.auth.error("Auth-Fehler: \(err.localizedDescription, privacy: .private)")
            }
        } catch {
            // `lastError` is delivered towards UI / telemetry — redact explicitly
            // so the raw string never lands in the interface.
            failAttempt(.unknown(LogSanitizer.redact(String(describing: error))), for: attempt)
            HLLog.auth.error("Unbekannter Auth-Fehler: \(String(describing: error), privacy: .private)")
        }
    }
}
