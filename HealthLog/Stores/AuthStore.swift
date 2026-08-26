import Foundation
import Observation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

@MainActor
@Observable
public final class AuthStore {
    // `Phase` + `AdoptUploadState` live in `AuthStore+Phase.swift`
    // (file_length-Disziplin — moved out so the #65 web-handoff leg has room).

    /// The authenticated phase, and — since 07-09 — the one place the shared
    /// session registry is admitted and invalidated (reasoning: 07-09 on
    /// ``activateAuthenticatedSession(ownerID:)``).
    public private(set) var phase: Phase = .unknown {
        didSet {
            let previousOwner = Self.sessionOwner(in: oldValue)
            let currentOwner = Self.sessionOwner(in: phase)
            guard currentOwner != previousOwner else { return }
            if let currentOwner {
                authSessionGeneration &+= 1
                activateAuthenticatedSession(ownerID: currentOwner)
            } else {
                invalidateAuthenticatedSession()
            }
        }
    }

    public private(set) var lastError: HLError?
    public private(set) var isWorking: Bool = false

    /// **13-02 (K7 client half).** A web-handoff leg ended without a session,
    /// so the password form belongs on screen.
    ///
    /// Published rather than inferred: `ServerAuthStep`'s own `@State` latch
    /// cannot know that a browser sheet just dead-ended, and a user stranded on
    /// an Apple error page needs the way back to be *already open* when they
    /// dismiss it.
    ///
    /// Set only through the fenced ``revealPasswordFallback(for:)``, so a late
    /// leg cannot reopen a form the newest attempt has moved past; cleared when
    /// a session is accepted, because a signed-in user has no fallback to take.
    public private(set) var passwordFallbackRevealed: Bool = false

    /// Monotonic identity-admission epoch. A web-deletion probe captures this
    /// before suspending and must observe the same value before it can wipe.
    /// Logout itself does not advance the epoch: only admitting an authenticated
    /// owner does, including a same-owner login after an unauthenticated phase.
    private(set) var authSessionGeneration: UInt64 = 0

    /// Monotonic authentication-attempt epoch (09-07 — see `AuthAttempt` in
    /// `AuthStore+Phase.swift`, which owns it; Swift's `private` is file-scoped).
    @ObservationIgnored var authAttemptGeneration: UInt64 = 0

    /// 24-01 — the once-per-launch latch for the blanked-identity repair (see
    /// `AuthStore+IdentityRecovery.swift`). Set before its await, so a failed
    /// recovery is retried on the next launch and never inside this one.
    @ObservationIgnored var didAttemptUserIDRecovery = false

    @ObservationIgnored
    let accountBoundaryTransition = AuthAccountBoundaryTransition()
    @ObservationIgnored var authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()

    public private(set) var adoptUploadState: AdoptUploadState = .idle

    func applySharingRecoveryUser(_ user: User) {
        switch phase {
        case .authenticated: phase = .authenticated(user)
        case .authenticating: phase = .authenticating(user)
        case .unknown, .unauthenticated, .standalone: break
        }
    }

    let auth: AuthService, keychain: KeychainStoring
    /// Lookup-only reference: AuthStore decides phase, SyncModeStore tracks
    /// the user-visible mode. `bootstrap()` reconciles the two so that
    /// upgraders (Keychain-token present, no `syncMode` key set) default to
    /// `.paired` without re-onboarding.
    private weak var syncMode: SyncModeStore?
    /// Non-secret UI/state persistence (the pending-web-deletion marker, #37/#38
    /// Privacy H3). Injectable so the return-detection tests can pin the flag
    /// without touching `.standard`.
    let defaults: UserDefaults

    public init(
        auth: AuthService,
        keychain: KeychainStoring,
        syncMode: SyncModeStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.keychain = keychain
        self.syncMode = syncMode
        self.defaults = defaults
    }

    public func bootstrap() async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        let isAuth = await auth.isAuthenticated
        // 24-01 — reads the slot, and heals it first when a pre-fix refresh
        // blanked it. A healthy install resolves without a network call; the
        // poisoned one gets exactly one `GET /api/auth/me`, because the profile
        // read that knows the id is itself lease-fenced and cannot run until
        // the id exists. See `AuthStore+IdentityRecovery.swift`.
        if isAuth, let id = await resolveBootstrapUserID() {
            // We don't fetch the User profile here yet — the bootstrap is fast/best-effort.
            // build-75 — seed the best-available identity label captured at
            // login (`AuthService.identityHint`) into `displayName` so the
            // Dashboard / Profile avatar paints real initials immediately
            // instead of a `"?"` monogram while the server profile loads. The
            // hint is local-only (Keychain) and is overwritten by the real
            // profile the moment `SettingsStore.load()` lands.
            let nameHint = keychain.getString(forKey: KeychainKey.userDisplayName)
            phase = .authenticated(User(id: id, email: nil, username: nil, displayName: nameHint, createdAt: .now))
            // Existing v0.4.0 upgraders: token-present + `syncMode == nil` means
            // they completed onboarding before SyncMode existed. Default `.paired`.
            if syncMode?.mode == nil { syncMode?.setMode(.paired) }
            return
        }
        // No token present. If the user previously chose standalone the
        // OnboardingMode key sticks; render the standalone shell without
        // re-prompting.
        if syncMode?.mode == .standalone {
            phase = .standalone
            return
        }
        phase = .unauthenticated
    }

    /// Onboarding helper: marks the device as standalone-only, transitions to
    /// `.standalone` phase. Caller (`OnboardingFlow.standalone` branch) invokes
    /// this AFTER the local HK + backfill steps complete.
    public func enterStandaloneMode() {
        syncMode?.setOnboardingChoice(.standalone)
        phase = .standalone
    }

    /// Onboarding-completion helper for server-mode: records the choice and
    /// keeps the existing phase transition path (login flow drives `.authenticated`).
    public func markOnboardingMode(_ choice: OnboardingMode) {
        syncMode?.setOnboardingChoice(choice)
    }

    /// Pair-later flow per `22-standalone-and-server-pairing.md §3.3`. The
    /// standalone user taps "Mit Server verbinden" in Settings; we drop them
    /// back into `OnboardingFlow` by clearing standalone mode + resetting
    /// `phase = .unauthenticated`. The OnboardingFlow's mode-selection step
    /// is skipped server-side via a follow-up (v0.4.2) — for v0.4.1 the
    /// user simply picks "Mit Server" again. Local SwiftData is untouched;
    /// after successful login an upload-backfill pass copies existing
    /// measurements to the server (v0.4.2 milestone).
    public func beginServerPairing() {
        // v0.11 W4 — remember that THIS pairing is an adopt-on-pair flow (the
        // user was standalone and is now joining a server). `clearOnLogout()`
        // wipes the runtime `mode` immediately, so by the time login completes
        // the live mode no longer reads standalone — we can't detect the
        // transition from the store at `.authenticated` time. Capturing the
        // intent here is the robust signal: a normal paired login never calls
        // `beginServerPairing()`, so the flag is never set and the upload never
        // fires for paired-from-start users.
        if syncMode?.isStandalone == true {
            pendingAdoptUpload = true
        }
        syncMode?.clearOnLogout()
        phase = .unauthenticated
    }

    /// v0.11 W4 — set by `beginServerPairing()` when the user was standalone;
    /// consumed once when the phase reaches `.authenticated` (in
    /// `completeOnboarding()`). A normal paired login leaves it `false`, so the
    /// adopt-on-pair upload only ever runs for a genuine standalone→paired
    /// transition.
    private var pendingAdoptUpload = false

    /// Composition-Root hook (set by `AppContainer`) that runs the adopt-on-pair
    /// upload. Returns the terminal progress so the store can publish a
    /// `.done` / `.failed` state. Reports intermediate progress via the
    /// `@Sendable` callback so the UI can animate the move. Lives on AuthStore
    /// (not AuthService) because it threads the iOS-side `LocalRepository` +
    /// `StandaloneAdoptUploadService`, which the Core-resident AuthService can
    /// not see.
    public var adoptUploadHook: (@Sendable (
        @escaping @Sendable (AdoptUploadProgress) async -> Void
    ) async -> Result<AdoptUploadProgress, Error>)?

    /// True while an adopt run is in flight, so a re-entrant trigger (a second
    /// `completeOnboarding()` or a manual retry tap mid-upload) can't double-fire
    /// the hook. Distinct from `pendingAdoptUpload` (which is "a run is owed").
    private var adoptUploadInFlight = false

    /// Fires the adopt-on-pair upload once, if this was a standalone→paired
    /// transition. Called from `completeOnboarding()` (the single terminal
    /// `.authenticated` site for the server branch) and from
    /// ``retryAdoptUpload()`` (the manual retry behind the `.failed` banner).
    /// Idempotent within a run — `adoptUploadInFlight` guards against a
    /// double-fire while one is running. v0.13 WR: the upload is now safely
    /// re-runnable (client-side med-create dedup), so a `chunkFailed` re-arms
    /// `pendingAdoptUpload` and the local mirror is replayed on the next trigger.
    private func runAdoptUploadIfPending() {
        guard pendingAdoptUpload, !adoptUploadInFlight, let hook = adoptUploadHook else { return }
        pendingAdoptUpload = false
        adoptUploadInFlight = true
        adoptUploadState = .uploading(AdoptUploadProgress(completed: 0, total: 0))
        // A weak, @Sendable progress sink the off-actor hook can call. Hoisting
        // it out of the Task keeps the @Sendable closure from capturing the
        // Task's `weak var self` (a concurrently-mutated binding).
        let progressSink: @Sendable (AdoptUploadProgress) async -> Void = { [weak self] progress in
            await MainActor.run {
                self?.publishAdoptProgress(progress)
            }
        }
        Task { [weak self] in
            let result = await hook(progressSink)
            // `Task {}` on a @MainActor store inherits the main actor, so this
            // publish is a direct synchronous call once `self` is still alive.
            guard let self else { return }
            publishAdoptTerminal(result)
        }
    }

    private func publishAdoptProgress(_ progress: AdoptUploadProgress) {
        adoptUploadState = .uploading(progress)
    }

    private func publishAdoptTerminal(_ result: Result<AdoptUploadProgress, Error>) {
        adoptUploadInFlight = false
        switch result {
        case let .success(progress):
            adoptUploadState = .done(progress)
        case let .failure(error):
            let progress = if case let AdoptUploadError.chunkFailed(_, completed, total) = error {
                AdoptUploadProgress(completed: completed, total: total)
            } else {
                AdoptUploadProgress(completed: 0, total: 0)
            }
            adoptUploadState = .failed(progress)
            // v0.13 WR — re-arm so the recovery path can re-run. The upload is
            // idempotent (measurements/mood/intake bulk dedup on externalId; the
            // med-create now dedups client-side by (name, dose)), so a re-run
            // replays the whole local mirror safely and finishes the stranded
            // chunk. `retryAdoptUpload()` (manual, behind the failed banner) or a
            // future reachability hook can fire it.
            pendingAdoptUpload = true
            HLLog.auth
                .warning(
                    "Adopt-on-pair upload failed (recoverable, re-armed): \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
        }
    }

    /// v0.13 WR — manual retry for a `.failed` adopt-on-pair upload (the
    /// affordance behind the failed banner's retry glyph). Re-runs the upload
    /// from the intact local mirror; idempotent, so a re-run never duplicates
    /// server rows (intakes/measurements/mood dedup on externalId, med-create on
    /// `(name, dose)`). No-op if nothing is owed or a run is already in flight.
    public func retryAdoptUpload() {
        runAdoptUploadIfPending()
    }

    public func login(email: String, password: String) async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        await runAttempt { attempt in
            switch try await self.auth.login(email: email, password: password) {
            case let .session(session):
                // v0.6.0.9 — the server branch flips to `.authenticating(user)`
                // so OnboardingFlow can run the HealthKit + Notifications steps
                // before `RootView` swaps in `AuthenticatedShell`; the promotion
                // to `.authenticated(user)` happens in `completeOnboarding()`.
                self.acceptSession(session, for: attempt)
            case let .mfaRequired(ticket, methods):
                // #37 — password accepted, second factor required. The ticket is
                // held transiently (in-memory, ~5 min — never persisted, never
                // logged) and the phase stays pre-auth until a code verifies.
                self.acceptMfaChallenge(ticket: ticket, methods: methods, for: attempt)
            }
        }
    }

    // MARK: - MFA (#37 / v1.23.0 two-factor login)

    /// The single-use MFA ticket. In-memory only (never Keychain / UserDefaults),
    /// cleared on success / expiry / cancel. Sensitive — never logged.
    private var mfaTicket: String?
    /// Wall-clock the ticket was issued at, for the local ~5-minute expiry guard
    /// so an obviously-stale ticket routes the user back to the password form
    /// before a doomed network round-trip.
    private var mfaTicketIssuedAt: Date?
    public private(set) var mfaChallenge: MfaChallenge?

    /// Server tickets are documented as single-use, ~5-minute. We guard locally
    /// a touch tighter so the user is bounced back to the password form before a
    /// guaranteed-expired verify attempt (the server is still authoritative).
    private static let mfaTicketLifetime: TimeInterval = 5 * 60

    private var isMfaTicketExpired: Bool {
        guard let issuedAt = mfaTicketIssuedAt else { return true }
        return Date.now.timeIntervalSince(issuedAt) > Self.mfaTicketLifetime
    }

    /// `internal`: the shared transition helpers in `AuthStore+Phase.swift` call
    /// it. The transient ticket itself stays private to this file.
    func beginMfaChallenge(ticket: String, methods: [MfaMethod]) {
        mfaTicket = ticket
        mfaTicketIssuedAt = .now
        mfaChallenge = MfaChallenge(methods: methods)
    }

    /// `internal` for the same reason ``beginMfaChallenge(ticket:methods:)`` is.
    func clearMfaState() {
        mfaTicket = nil
        mfaTicketIssuedAt = nil
        mfaChallenge = nil
    }

    /// User explicitly backed out of the challenge (Cancel button). Clears the
    /// transient ticket + challenge AND any error, returning a clean password
    /// form.
    public func cancelMFA() {
        clearMfaState()
        lastError = nil
    }

    /// Sheet was dismissed (swipe / programmatic). Clears the transient ticket +
    /// challenge but PRESERVES `lastError` so an expiry message set just before
    /// the dismissal survives onto the password form. Idempotent.
    public func dismissMfaChallenge() {
        clearMfaState()
    }

    /// #37 — completes the challenge with a TOTP or recovery code. On success,
    /// joins the normal post-login handoff (`phase = .authenticating(user)` →
    /// OnboardingFlow → `completeOnboarding()`), identical to a password login.
    ///
    /// A wrong code (server 422) keeps the sheet open with an inline error so the
    /// user can retry. An expired / burned ticket (local guard or server 401)
    /// clears the challenge and routes back to the password form with a clear
    /// "session expired" message — never a dead sheet. The code + ticket are
    /// sensitive and never logged.
    ///
    /// - Parameter rememberDevice: parity item 2.4 — the user ticked "trust this
    ///   device" on the challenge sheet, so the server mints a 30-day
    ///   trusted-device credential and subsequent logins skip the second factor.
    ///   `AuthService.verifyMFA` has accepted this argument since #37 but no
    ///   caller ever passed it, so the flag was dead on iOS. Forced to `false`
    ///   for a recovery-code login: the server refuses to trust a device on that
    ///   path anyway (`mfa/verify/route.ts` — "a recovery-code login signals the
    ///   user lost their device"), and sending `true` would paint a toggle whose
    ///   promise the server silently drops.
    public func verifyMFA(method: MfaMethod, code: String, rememberDevice: Bool = false) async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        guard let ticket = mfaTicket, !isMfaTicketExpired else {
            failMfaTicketExpired()
            return
        }
        await runAttempt(classify: handleMfaVerifyFailure) { attempt in
            let session = try await self.auth.verifyMFA(
                ticket: ticket,
                method: method,
                code: code,
                rememberDevice: method == .recovery ? false : rememberDevice
            )
            self.acceptSession(session, for: attempt)
        }
    }

    /// #37 — completes the challenge with a WebAuthn security key. Reuses
    /// `AuthService.mfaWebauthnVerify` (which reuses `PasskeyService.assert`).
    /// Benign user/system passkey-sheet cancels are mapped to `.canceled` (no
    /// error banner), mirroring `loginWithPasskey`.
    ///
    /// - Parameter rememberDevice: parity item 2.4 — same trusted-device opt-in
    ///   the TOTP path threads. No recovery-code carve-out applies here: a
    ///   security key IS the possession factor, so trusting the device after a
    ///   successful assertion is exactly the web semantic.
    public func verifyMFAWithSecurityKey(
        anchor: ASPresentationAnchorProvider,
        rememberDevice: Bool = false
    ) async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        guard let ticket = mfaTicket, !isMfaTicketExpired else {
            failMfaTicketExpired()
            return
        }
        // A benign passkey-sheet cancel normalises to `.canceled`, which the
        // shared classifier swallows without a banner — and `acceptSession` is
        // the only thing that clears the challenge, so it stays up.
        await runAttempt(classify: handleMfaVerifyFailure) { attempt in
            do {
                let session = try await self.auth.mfaWebauthnVerify(
                    ticket: ticket,
                    presentationAnchor: anchor,
                    rememberDevice: rememberDevice
                )
                self.acceptSession(session, for: attempt)
            } catch {
                throw Self.normalizePasskeyError(error)
            }
        }
    }

    /// Routes a verify failure. #37/H1: the server returns **401 for BOTH** a
    /// WRONG CODE ("Invalid code") and a DEAD TICKET ("Invalid or expired
    /// challenge") — verified against `src/app/api/auth/mfa/verify/route.ts`
    /// (v1.25). Only a dead ticket clears the challenge and returns to the
    /// password form; everything else (a wrong code, a rate-limit, a transient
    /// network blip) STAYS on the sheet so the user can retry. The default is
    /// deliberately "retriable" so a wrong digit is NEVER ejected — only a
    /// positively-identified dead ticket routes back to the password form (the
    /// local ~5-min ticket guard in `verifyMFA` is the backstop for genuine
    /// expiry that the server never gets a chance to report).
    private func handleMfaVerifyFailure(_ err: HLError, for attempt: AuthAttempt) {
        // Fenced at the top rather than only inside `failAttempt`, because the
        // dead-ticket branch tears the challenge down: a late attempt must not
        // eject the user from a sheet a newer one is still driving.
        guard isCurrent(attempt) else { return }
        if Self.indicatesDeadMfaTicket(err) {
            failMfaTicketExpired()
            return
        }
        failAttempt(err, for: attempt)
        HLLog.auth.error("MFA verify failed: \(err.localizedDescription, privacy: .private)")
    }

    /// Clears the challenge and surfaces a localized "session expired" message on
    /// the (now-revealed) password form. The phase is untouched — the user was
    /// never authenticated — so RootView keeps showing the onboarding auth step.
    private func failMfaTicketExpired() {
        clearMfaState()
        lastError = .unknown(String(localized: "onboarding.mfa.expired"))
        HLLog.auth.warning("MFA ticket expired/invalid — returning to password form.")
    }

    /// New-account flow per `05-auth-flows.md §3` + `M2-A11 §6.1`:
    /// `register` chains `register` + `login` server-side so the iOS client
    /// observes a single transition into the post-login intermediate
    /// `.authenticating(user)` phase. The terminal `.authenticated(user)`
    /// flip is driven from `OnboardingFlow.advanceFromNotifications` once
    /// the HealthKit + Notifications permission steps complete.
    /// Rate-limited (5/15min/IP) — duplicate taps debounced by `isWorking`.
    ///
    /// b182 W-B182-INVITE (GH #16) — `inviteToken` (server invite `hlv_<64 hex>`)
    /// is passed straight through to `AuthService.register`. On a closed-
    /// registration instance it is the door key; an invalid/expired token
    /// surfaces as the server's `403` via `runWorkable`'s `lastError`. The token
    /// is sensitive — never logged.
    public func register(
        email: String,
        username: String,
        password: String,
        inviteToken: String? = nil
    ) async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        await runAttempt { attempt in
            let session = try await self.auth.register(
                email: email,
                username: username,
                password: password,
                inviteToken: inviteToken
            )
            self.acceptSession(session, for: attempt)
        }
    }

    public func loginWithPasskey(anchor: ASPresentationAnchorProvider) async {
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        await runAttempt { attempt in
            do {
                let session = try await self.auth.passkeyLogin(presentationAnchor: anchor)
                self.acceptSession(session, for: attempt)
            } catch {
                // v0.11 — a user-cancelled system passkey sheet surfaces as an
                // `ASAuthorizationError` (`.canceled`, sometimes `.unknown` /
                // `.notInteractive`). Normalising it to the benign
                // `HLError.canceled` lets the shared classifier stop the spinner
                // WITHOUT a scary banner; every other error surfaces normally.
                throw Self.normalizePasskeyError(error)
            }
        }
    }

    // MARK: - Publication funnels (09-07)

    /// `phase`, `isWorking` and `lastError` keep their `private(set)` setters —
    /// Swift's `private` is file-scoped and the fenced transition that owns them
    /// lives in `AuthStore+Phase.swift` — so these three named writers exist
    /// instead of widening three public setters to a module in which every screen
    /// could then move the authenticated phase.
    func admitAuthenticating(_ user: User) {
        phase = .authenticating(user)
    }

    func publishWorkingState(_ working: Bool) {
        isWorking = working
    }

    func publishError(_ error: HLError?) {
        lastError = error
    }

    /// 13-02 — the only writer of ``passwordFallbackRevealed``. Callers go
    /// through the fenced `revealPasswordFallback(for:)` / `clearPasswordFallback()`
    /// in `AuthStore+Phase.swift`, which is where the attempt fences live.
    func publishPasswordFallbackRevealed(_ revealed: Bool) {
        passwordFallbackRevealed = revealed
    }

    // MARK: - OIDC SSO (#49 / v1.30.11 native single sign-on)

    #if canImport(AuthenticationServices)
        /// #49 — the native OIDC SSO driver (`ASWebAuthenticationSession`). Wired by
        /// the composition root (`AppContainer`). Nil in unit tests that don't
        /// exercise the web-auth leg; ``loginWithSSO(anchor:)`` surfaces a clear
        /// error then.
        public var oidcAuthenticator: OidcAuthenticating?

        /// #49 — starts the native OIDC SSO flow. Generates app-side PKCE (S256),
        /// opens `…/api/auth/oidc/login?client=native&code_challenge=…` in an
        /// `ASWebAuthenticationSession`, and finalizes the returned
        /// `healthlog://oidc-callback?…` into one of three paths (token exchange /
        /// MFA challenge / surfaced error). Discoverable on every host — critical
        /// for `OIDC_ONLY` instances where password/passkey is refused.
        ///
        /// The PKCE `codeVerifier` lives only in this stack frame until the one-shot
        /// token exchange — never persisted, never logged. A user-cancelled sheet is
        /// benign (no banner), mirroring the passkey-cancel handling.
        public func loginWithSSO(anchor: ASPresentationAnchorProvider) async {
            guard let authenticator = oidcAuthenticator else {
                lastError = .unknown(String(localized: "onboarding.sso.unavailable"))
                HLLog.auth.error("SSO login requested but no OIDC authenticator is wired.")
                return
            }
            // The attempt is opened HERE and carried into the callback: the web
            // sheet holds no account boundary, so a second attempt can start
            // while this one is still up, and only the newest may publish.
            let attempt = beginAuthAttempt()
            defer { finishAuthAttempt(attempt) }

            // App-generated PKCE (S256). The verifier is held in memory only.
            let pkce = OidcPKCE.generate()
            // Ohne eingerichteten Server gibt es keine Origin, gegen die der
            // Flow laufen koennte. Das ist ein ANDERER Zustand als eine nicht
            // baubare URL: "bitte erneut versuchen" waere hier eine Luege, denn
            // kein Wiederholen richtet es — es fehlt eine Adresse.
            guard let baseURL = AppEnvironment.currentBaseURL(keychain: keychain) else {
                failAttempt(.serverNotConfigured, for: attempt)
                HLLog.auth.error("SSO login requested without a configured server.")
                return
            }
            guard let loginURL = OidcNativeFlow.loginURL(baseURL: baseURL, codeChallenge: pkce.codeChallenge) else {
                failAttempt(.unknown(String(localized: "onboarding.sso.error.generic")), for: attempt)
                HLLog.auth.error("SSO login could not build the authorize URL.")
                return
            }

            let outcome = await authenticator.authenticate(
                loginURL: loginURL,
                callbackScheme: OidcNativeFlow.callbackScheme,
                anchor: anchor
            )
            switch outcome {
            case .canceled:
                // Benign user dismissal — no banner (mirrors the passkey cancel).
                acceptBenignCancellation(for: attempt)
            case .failed:
                failAttempt(.unknown(String(localized: "onboarding.sso.error.generic")), for: attempt)
                HLLog.auth.warning("SSO web-auth session failed to complete.")
            case let .callback(url):
                await handleSSOCallback(url, codeVerifier: pkce.codeVerifier, attempt: attempt)
            }
        }

        /// #49 — routes the parsed `healthlog://oidc-callback` into the correct
        /// finalization path. `codeVerifier` is the in-memory PKCE verifier from
        /// ``loginWithSSO(anchor:)``; it is consumed exactly once here and never
        /// logged. `internal` (not `private`) so the flow-routing test can drive it
        /// directly with a canned callback URL.
        /// - Parameter attempt: the attempt ``loginWithSSO(anchor:)`` opened
        ///   before the sheet. `nil` when a test drives the callback directly, in
        ///   which case this leg owns an attempt of its own.
        func handleSSOCallback(_ url: URL, codeVerifier: String, attempt: AuthAttempt? = nil) async {
            guard await beginAuthenticationTransition() else { return }
            defer { finishAuthenticationTransition() }
            let leg = attempt ?? beginAuthAttempt()
            defer { if attempt == nil { finishAuthAttempt(leg) } }
            switch OidcCallback.parse(url) {
            case let .code(code):
                do {
                    // Exchange exactly once → the standard native bundle, stored +
                    // rotated through the existing keychain persistence so refresh
                    // works identically to password/passkey login.
                    let session = try await auth.oidcNativeTokenExchange(code: code, codeVerifier: codeVerifier)
                    acceptSession(session, for: leg)
                } catch let err as HLError where err == .canceled {
                    acceptBenignCancellation(for: leg)
                } catch {
                    // A consumed/expired/mismatched code (single generic 401) is a
                    // login failure — surface it, never a web page. The
                    // code/verifier/token never appear in any log line.
                    failAttempt(.unknown(String(localized: "onboarding.sso.exchangeFailed")), for: leg)
                    HLLog.auth.error(
                        "SSO token exchange failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            case let .mfa(ticket, methods):
                // Reuse the existing #37 second-factor flow verbatim: raise the
                // challenge; `MfaChallengeSheet` completes it at
                // `POST /api/auth/mfa/verify` (or the webauthn pair) with native
                // headers → the standard bundle → stored. An SSO session never
                // satisfies an in-app step-up; this is a first-factor login only.
                acceptMfaChallenge(ticket: ticket, methods: methods, for: leg)
            case let .error(reason):
                failAttempt(.unknown(reason.localizedMessage), for: leg)
                // `logLabel` is operator-grade: a closed-set reason word (no PII,
                // no token) — safe as `.public`.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.auth.warning("SSO callback error: \(reason.logLabel, privacy: .public)")
            case .unrecognized:
                failAttempt(.unknown(String(localized: "onboarding.sso.error.generic")), for: leg)
                HLLog.auth.warning("SSO callback carried no recognised parameters.")
            }
        }

    #endif

    /// Terminal server-branch onboarding handoff: called by
    /// `OnboardingFlow.advanceFromNotifications` once the HealthKit +
    /// Notifications permission steps have run. Promotes the carried user
    /// from `.authenticating(user)` to `.authenticated(user)`, which is the
    /// trigger for `RootView` to swap `OnboardingFlow` for
    /// `AuthenticatedShell`.
    ///
    /// No-op when called from any other phase — defensive against a re-mount
    /// race after `advanceFromNotifications` already fired.
    public func completeOnboarding() {
        guard case let .authenticating(user) = phase else { return }
        phase = .authenticated(user)
        // v0.11 W4 — terminal `.authenticated` site for the server branch. If
        // this login concluded a standalone→paired transition, move the local
        // rows up now (fire-and-forget; the store publishes progress via
        // `adoptUploadState`). No-op for paired-from-start users.
        runAdoptUploadIfPending()
    }

    // CU-15 (catchup-v134 A5): `enrollPasskey` is gone together with
    // `AuthService.passkeyEnroll`. The register-options / register-verify pair
    // is cookie-only + re-proof-gated since server v1.34.1, so over Bearer it
    // could only ever return 401. Passkeys are registered in the web UI —
    // `PasskeyManagementScreen` links there. Passkey **login**
    // (`loginWithPasskey`) is untouched.

    public func logout() async {
        // 06-05 — hold the 06-10 account boundary for the whole sign-out so a
        // replacement admission (or same-owner re-login) queues until the
        // remote revoke, credential wipe, HK-anchor cleanup, and the shared
        // local cascade below have all completed.
        guard await beginAuthenticationTransition() else { return }
        defer { finishAuthenticationTransition() }
        await runWorkable {
            // 06-05 (step 1) — sign-out is terminal from here (the server
            // revoke is best-effort and never aborts the local teardown), so
            // stale the shared authenticated-session lease BEFORE any wipe:
            // no suspended producer may publish into the closing session.
            self.invalidateAuthenticatedSession()
            try await self.auth.logout()
            // v0.7.0 W-LOGOUT (NEW-H-1): the Composition-Root sets
            // `onPostLogoutHook` to `AppContainer.performFullLocalLogout(reason:
            // .userInitiated)` so this UI-driven sign-out runs the SAME
            // cascade as the 401-bridge + account-deletion. Pre-v0.7.0 this
            // path only wiped tokens + ran HK-anchor cleanup, leaving the
            // on-device AI caches / avatar PNG / Coach SwiftData transcript /
            // outbox cipher key behind for the next user on the same device.
            if let hook = self.onPostLogoutHook {
                await hook()
            }
            // v0.12 W7-6 — latent standalone-routing safeguard. The primary fix
            // (W7-1) hides sign-out in standalone Settings, so this branch is
            // normally unreachable. But if sign-out is ever reached on a
            // standalone install, clearing the runtime `syncMode` keeps the
            // in-session outcome well-defined: the user lands on the onboarding
            // mode picker over a now-mode-less install rather than re-running the
            // picker over an install whose flag still says `.standalone`
            // (undefined-feeling). Paired logout already clears `syncMode`
            // elsewhere; this only fires for the standalone edge.
            if self.syncMode?.isStandalone == true {
                self.syncMode?.clearOnLogout()
            }
            self.clearPendingWebDeletion()
            self.phase = .unauthenticated
        }
    }

    /// Composition-Root hook (set by `AppContainer`) that runs the shared
    /// local-logout cascade after `AuthService.logout()` returns. Lives on
    /// AuthStore (not AuthService) because the cascade touches @MainActor
    /// stores + iOS-side singletons (`AvatarCache`, `OnDeviceBriefingCache`,
    /// `LocalLLMBox`, …) which the HealthLogCore-resident AuthService can
    /// not see. See `AppContainer+Logout.swift`.
    public var onPostLogoutHook: (@Sendable () async -> Void)?

    /// GDPR-style account deletion. Workflow:
    /// 1. `AuthService.deleteAccount` ruft den Server-DELETE auf und wiped
    ///    bei Erfolg den Keychain (Bearer + Refresh + Expiries + UserID +
    ///    DeviceID).
    /// 2. Bei Server-Erfolg läuft der `localCleanupHook` (von AppContainer
    ///    gesetzt — leert Outbox + Stores), dann transition `phase =
    ///    .unauthenticated` so dass `RootView` zurück auf `OnboardingFlow`
    ///    schaltet.
    /// 3. Bei Fehler bleibt der Phase-Status unverändert. `lastError` wird
    ///    via `runWorkable` in die UI durchgereicht.
    ///
    /// - Returns: `true` wenn der Account tatsächlich gelöscht wurde, sonst
    ///   `false` — die UI nutzt das Signal, um die Confirm-Sheet zu schließen
    ///   bzw. die Fehlermeldung zu zeigen.
    public func deleteAccount() async -> Bool {
        guard await beginDeletedAccountTransition() else { return false }
        defer { finishDeletedAccountTransition() }
        var ok = false
        await runWorkable {
            try await self.auth.deleteAccount()
            // 06-05 (step 1) — the deletion is committed server-side (a thrown
            // error above skips ALL terminal teardown, preserving the live
            // lease): stale the shared authenticated-session lease before the
            // local cascade so no suspended producer can publish into the
            // deleted session. The cascade re-asserts + drains afterwards.
            self.invalidateAuthenticatedSession()
            // Lokale Aufräumarbeit (Outbox + Stores). Errors werden
            // geschluckt — der Account ist server-seitig schon weg, da würde
            // ein lokaler Wipe-Fehler den User unnötig blockieren.
            await self.localCleanupHook?()
            self.clearPendingWebDeletion()
            self.phase = .unauthenticated
            ok = true
        }
        return ok
    }

    /// Optional Cleanup-Hook der vom AppContainer gesetzt wird, sobald die
    /// Stores existieren. Läuft NACH dem erfolgreichen Server-DELETE (und
    /// nachdem die Keychain bereits gewiped wurde), aber VOR dem
    /// Phase-Wechsel auf `.unauthenticated` — so sind Stores schon leer wenn
    /// `RootView` neu rendert.
    public var localCleanupHook: (@Sendable () async -> Void)?

    /// Scoped cache reset used when a selected record is revoked or its session
    /// context changes. Unlike logout cleanup, this preserves credentials,
    /// outbox ownership, and the authenticated phase.
    public var sharingScopeCleanupHook: (@Sendable () async -> Void)?

    /// Called from `APIClient.onUnauthorized` whenever the server returns 401
    /// **after** ein One-shot-Refresh ebenfalls fehlgeschlagen ist (Bridge in
    /// `APIClient.execute`). Wipes Keychain-Token + Refresh-Bundle,
    /// transitions UI to unauthenticated. Idempotent.
    ///
    /// Triggers for both `.authenticated` (already inside the main shell)
    /// and `.authenticating` (server-login resolved but the user is still
    /// inside `OnboardingFlow` walking the HealthKit + Notifications
    /// permission steps) — a 401 in that brief window otherwise leaves the
    /// onboarding view stuck with an invalid token in Keychain (v0.6.0.9).
    /// 06-05 — asked by the composition 401 bridge BEFORE it runs the shared
    /// cleanup cascade, so the cascade can precede the credential wipe and the
    /// terminal publication without tearing anything down for pre-auth 401s
    /// (wrong password, dead MFA ticket, …) or racing a deletion
    /// reconciliation's stronger cascade.
    func shouldBeginUnauthorizedTeardown() -> Bool {
        guard !deletionOwnsAccountBoundary else { return false }
        switch phase {
        case .authenticated, .authenticating: return true
        case .unknown, .unauthenticated, .standalone: return false
        }
    }

    /// - Returns: `false` when a web-deletion reconciliation already owns the
    ///   account boundary and will run the stronger `.accountDeleted` cascade;
    ///   otherwise `true`, preserving the normal generic `.tokenExpired` bridge.
    @discardableResult
    public func handleUnauthorized() async -> Bool {
        guard !deletionOwnsAccountBoundary else { return false }
        switch phase {
        case .authenticated, .authenticating: break
        case .unknown, .unauthenticated, .standalone: return true
        }
        // 06-05 (step 1) — the 401 is terminal for this session: stale the
        // shared authenticated-session lease BEFORE the credential wipe so no
        // suspended producer can publish once teardown is committed. The
        // shared cascade (`performFullLocalLogout(.tokenExpired)`, run by the
        // composition bridge that holds the account boundary) re-asserts the
        // invalidation and drains every owned task afterwards.
        invalidateAuthenticatedSession()
        // **Audit M4 — pre-wipe identity capture (load-bearing).**
        // `previousUserID` is read into a local BEFORE any keychain key is
        // removed, then passed explicitly into the cleanup. The cleanup
        // therefore receives the pre-wipe id by value and never has to
        // re-read `KeychainKey.userID` (which is gone by the time it runs).
        // The HK-anchor cleanup hook + the importer reset paths
        // (`resetAnchor`/`resetAnchors` in the *Importer actors) honour the same
        // invariant: they clear keys derived from the prefix captured at the
        // importer's `init`, never re-resolving the keychain id — so the wipe
        // can never strand the previous user's anchor under a half-wiped
        // `_anonymous` partition. Pinned by `HKImporterResetIsolationTests`.
        let previousUserID = keychain.getString(forKey: KeychainKey.userID)
        _ = try? await auth.invalidateAndWipeSessionCredentials()
        if let cleanup = onLogoutCleanup {
            // 06-05 — AWAITED, never detached: the anchor cleanup must be
            // complete before this teardown returns, so it can never outlive
            // a replacement account's admission.
            await cleanup(previousUserID)
        }
        phase = .unauthenticated
        HLLog.auth.warning("Session abgelaufen, Token entfernt.")
        return true
    }

    /// Optional Composition-Root-Hook für Side-Effects nach Keychain-Wipe
    /// (z. B. `HealthKitService.clearAnchors(for:)`). Wird vom AppContainer
    /// gesetzt, weil HealthKit-Symbole in der iOS-only-Schicht leben und
    /// HealthLogCore (wo dieser Store sitzt) die nicht kennen darf.
    public func setOnLogoutCleanup(_ cleanup: (@Sendable (String?) async -> Void)?) {
        onLogoutCleanup = cleanup
    }

    private var onLogoutCleanup: (@Sendable (String?) async -> Void)?

    /// Runs owner-partition cleanup while the deleted-account transition still
    /// excludes authentication admission.
    func runDeletedAccountOwnerCleanup(previousOwner: String?) async {
        if let cleanup = onLogoutCleanup {
            await cleanup(previousOwner)
        }
    }

    /// Publishes the terminal phase only after every deletion cleanup await has
    /// completed. The transition gate is released immediately afterward by the
    /// caller, so the login UI and direct auth calls observe a quiescent device.
    func completeDeletedAccountBoundary() {
        phase = .unauthenticated
    }

    #if DEBUG
        /// Test-only seam — drops the store directly into a chosen phase
        /// without going through `AuthService.login` etc. Used by
        /// `AuthStoreBootstrapTests` to exercise the `.authenticating`
        /// transitions added in v0.6.0.9. NOT compiled into Release.
        public func setPhaseForTesting(_ newPhase: Phase) {
            phase = newPhase
        }
    #endif

    private func runWorkable(_ block: @escaping () async throws -> Void) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            try await block()
        } catch let err as HLError where err == .canceled {
            // v0.11 — user cancelled the system passkey sheet (or any benign
            // user/system cancel that `passkeyLogin` mapped to `.canceled`).
            // The spinner just stops; NO error banner. We deliberately do not
            // set `lastError` here — a "Cancelled."/"Abgebrochen." banner on a
            // user-initiated dismiss is noise, not signal. Debug-log only.
            HLLog.auth.debug("Auth-Flow vom Nutzer abgebrochen — kein Fehlerbanner.")
        } catch let err as HLError {
            lastError = err
            HLLog.auth.error("Auth-Fehler: \(err.localizedDescription, privacy: .private)")
        } catch {
            // `lastError` wird Richtung UI / Telemetry ausgeliefert — explizit redacten,
            // damit der String nicht ungefiltert in der UI landet. Der HLLog-Call läuft
            // ohnehin durch HLLogger → LogSanitizer.
            lastError = .unknown(LogSanitizer.redact(String(describing: error)))
            HLLog.auth.error("Unbekannter Auth-Fehler: \(String(describing: error), privacy: .private)")
        }
    }
}

extension AuthStore {
    /// Who this phase admits. `.authenticating` counts: the token is stored.
    static func sessionOwner(in phase: Phase) -> String? {
        switch phase {
        case let .authenticated(user), let .authenticating(user): user.id
        case .unknown, .unauthenticated, .standalone: nil
        }
    }
}
