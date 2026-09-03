import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// v0.4.1 redesign of the auth step. Passkey is the primary CTA per
/// M2-A11 § 5.4 + HIG § Passkeys (*"When you support passkeys, make them
/// the default sign-in method. Don't bury the passkey button behind a
/// chevron."*). Email/Password is a secondary collapsed surface. A
/// "Neues Konto erstellen" sheet handles new-user registration via the
/// chained `POST /api/auth/register` + `POST /api/auth/login` flow per
/// `05-auth-flows.md §3`.
///
/// **Server-URL is no longer entered here** — see `ServerURLStep` which
/// runs as the previous step in server-mode. The dead disclosure that
/// was here in v0.4.0 is gone.
///
/// **Passkey-enrolment-before-login bug fix:** the broken
/// `PasskeyEnrollmentStep` (which 401'd because
/// `/api/auth/passkey/register-options` requires an authenticated caller)
/// is removed from the onboarding flow entirely. Native enrolment is gone
/// app-wide since CU-15 — that route pair turned cookie-only + re-proof-gated
/// on server v1.34.1, so it 401s for a Bearer client wherever it is called
/// from. `Settings → Sicherheit → Passkeys` (`PasskeyManagementScreen`) now
/// links to the server's web UI for registration and keeps the Bearer-reachable
/// list / rename / revoke verbs. Passkey **login** below is unaffected.
struct ServerAuthStep: View {
    /// Injected by `OnboardingFlow`: `true` when the server's
    /// `/api/auth/registration-status` returns `registrationEnabled: true`.
    /// Self-hosted single-user instances usually return `false` after
    /// bootstrapping; this hides the "Neues Konto" CTA accordingly.
    let registrationEnabled: Bool

    /// parity 2.9 — `GET /api/auth/oidc/status`, probed by `OnboardingFlow`.
    /// Decides three things the screen used to guess:
    /// * no IdP configured → the SSO button is hidden instead of dead;
    /// * `OIDC_ONLY` → password + passkey + register are hidden instead of
    ///   being offered and then refused by the server;
    /// * the operator's `buttonLabel` replaces the generic SSO wording.
    /// Defaults to ``OidcStatus/unknown`` (every door visible) so a not-yet-
    /// probed or unreachable server never renders a screen with no way in.
    var oidcStatus: OidcStatus = .unknown

    /// #65 / 13-02 — what `OnboardingFlow` has learned about this server's
    /// web-handoff login route, probed on the same beat as `oidcStatus`.
    /// Combined with a `.selfHosted` region (``prefersWebHandoff(keychain:)``)
    /// `.available` swaps the native passkey/password form for the web-handoff
    /// CTA. Fail-closed: anything but `.available` keeps the native form, and
    /// `.probing` — the state the first render actually sees — is deliberately
    /// distinguishable from `.unavailable` (see ``WebLoginAvailability``).
    var webLoginAvailability: WebLoginAvailability = .probing

    /// b182 W-B182-INVITE (GH #16) — the server invite token (`hlv_<64 hex>`)
    /// from the web invite QR / universal link, threaded down by
    /// `OnboardingFlow`. Non-nil → auto-present the prefilled `RegistrationSheet`
    /// + render a calm "you've been invited" banner. The token is opaque: it is
    /// passed into the register call as-is and shown only as an "invite applied"
    /// chip — never an editable field, never logged.
    var prefilledInviteToken: String?

    /// **R1 — der fehlende Ausgang.**
    ///
    /// Von der Anmeldefläche muss es IMMER einen Weg zur Serveradresse geben,
    /// auch wenn eine gesetzt ist: wer sich vertippt hat, sah bisher nur, dass
    /// die Anmeldung scheitert, und hatte keinen Weg zurück. Das ist kein
    /// Beitext im Sinne von STANDARD R1, sondern der Absprung, den R4 an die
    /// Stelle einer Wegweiser-Prosa setzt.
    var onChangeServer: (() -> Void)?

    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container
    @State private var email: String = ""
    @State private var password: String = ""
    /// 13-02 — the view's only piece of form state. Whether the form is on
    /// screen is decided by ``AuthStepFormVisibility``, not by this flag alone:
    /// a dead-ended web leg opens it through the store as well.
    @State private var emailSectionLatched: Bool = false
    /// 16-02 (K5 polish) — a reveal that has asked for the keyboard but not yet
    /// got it. `@FocusState` set in the same update that creates the field is
    /// dropped: SwiftUI has no field to move focus to yet, so the fallback link
    /// opened the form and left the caret nowhere. The request is parked here
    /// and spent once the form has settled.
    @State private var pendingEmailFocus: Bool = false
    @State private var showRegistration: Bool = false
    @FocusState private var focused: Field?

    enum Field { case email, password }

    /// Passkeys sind an die `rpId` des Servers gebunden, und iOS lässt eine
    /// Registrierung oder Assertion nur zu, wenn diese `rpId` von einer
    /// `webcredentials:`-Domain im Associated-Domains-Entitlement dieses
    /// Builds gedeckt ist. Fehlt sie, findet der Assert keine Credential und
    /// lief früher endlos (der Timeout-Watchdog in `PasskeyService` bleibt
    /// als Verteidigung stehen).
    ///
    /// Die Schranke prüft deshalb die **tatsächliche Fähigkeit des Builds**
    /// (``AppEnvironment/supportsPasskeys(host:bundle:)`` gegen die
    /// mitgelieferten Relying-Party-Domains) statt wie früher den Namen
    /// eines fest eingebauten Hosts. Das alte Kriterium war für jeden
    /// Selbst-Hoster schlicht falsch (GH #65): wer die App mit seiner
    /// eigenen Domain neu baute, bekam die Schaltfläche trotzdem nie zu
    /// sehen.
    private var passkeySupportedForHost: Bool {
        server?.supportsPasskeys ?? false
    }

    /// 09-03 — the configured server as a value, not a per-body Keychain read.
    private var server: ConfiguredServerSnapshot? {
        container?.configuredServer
    }

    /// #65 — soll die Anmeldung an den Browser übergeben werden?
    ///
    /// Nur, wenn der native Weg für diesen Host strukturell nicht
    /// funktionieren kann: der Server ist selbst gehostet (statt eines
    /// vom Build abgedeckten Managed-/Review-Hosts) **und** dieses Build bringt keine
    /// `webcredentials:`-Domain für ihn mit, kann seine Passkeys / seinen
    /// Passwortmanager also nicht binden. Der Browser auf der eigenen
    /// Origin kann es. Wer sein Build mit der passenden Association gebaut
    /// hat, behält den nativen Weg.
    ///
    /// Static + `keychain`-injiziert, damit die Regel unit-testbar ist
    /// (Muster: ``privacyPolicyURL(keychain:)``).
    static func prefersWebHandoff(keychain: KeychainStoring?) -> Bool {
        guard let keychain else { return false }
        return ConfiguredServerSnapshot(
            baseURL: AppEnvironment.currentBaseURL(keychain: keychain)
        ).prefersWebHandoff
    }

    /// #65 — the live UI gate: self-hosted region AND the server serves the
    /// frozen web-handoff contract (`webLoginAvailable`). Both must hold, else
    /// the native passkey/password form stays. Independent of
    /// `oidcStatus.hidesPasswordAffordances` — on an `OIDC_ONLY` self-hosted
    /// instance the web-handoff CTA still shows (its web page offers the IdP);
    /// only the password *fallback* link is additionally gated on password
    /// affordances being allowed.
    private var showsWebHandoff: Bool {
        formVisibility.showsWebHandoffCTA
    }

    /// 13-02 — the rule, built fresh per body pass from the live inputs. The
    /// store's `passwordFallbackRevealed` is folded in here so a web leg that
    /// dead-ended in the browser opens the same form the fallback link does —
    /// one door, two ways of reaching it.
    private var formVisibility: AuthStepFormVisibility {
        AuthStepFormVisibility(
            prefersWebHandoff: server?.prefersWebHandoff ?? false,
            availability: webLoginAvailability,
            latched: emailSectionLatched || authStore.passwordFallbackRevealed,
            passkeySupported: passkeySupportedForHost
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("Sign in")
                        .font(.hlTitle1)
                        .foregroundStyle(HLText.primary)
                    Text("Sign in to your HealthLog account.")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HLSpace.xl)
                .padding(.top, HLSpace.xxl)

                // b182 W-B182-INVITE — calm "you've been invited" banner when
                // the user arrived via the web invite link. Opaque: no token is
                // shown, only the fact that an invite is applied.
                if prefilledInviteToken != nil {
                    inviteBanner
                        .padding(.horizontal, HLSpace.xl)
                }

                // v0.7.0: Passkey-CTA reaktiviert. Der Backend-Handshake
                // ist seit v0.6.1.21 stabil (Server-Repo CHANGELOG), und
                // `PasskeyService` haengt unveraendert am Anchor-Provider —
                // siehe `HealthLogApp.swift:49` (`PasskeyService` wird im
                // Release-Build instanziert; nur Debug nutzt
                // `StubPasskeyService`). Das v0.6.1.16-Gate hatte Passkey
                // im Release dunkel geschaltet, was Apple-HIG verletzt
                // ("When you support passkeys, make them the default") +
                // die App-Store-Review-Note "we support passkeys" gegen
                // den tatsaechlichen Build-Output stellte. Reaktivierung
                // bringt das Erlebnis in Linie mit der HIG-Direktive.
                // parity 2.9 — on an `OIDC_ONLY` instance the server refuses
                // password AND passkey sign-in, so neither the passkey CTA nor
                // the "or" divider that introduces the email form is honest.
                #if canImport(AuthenticationServices) && canImport(UIKit)
                    // #65 — on a self-hosted instance that serves the frozen
                    // web-handoff contract, the web-login CTA REPLACES the native
                    // passkey CTA + "or" divider (the native form can't bind that
                    // host's passkeys / password manager). Managed/review hosts
                    // and pre-contract or offline self-hosted servers keep the
                    // native layout below unchanged.
                    if showsWebHandoff {
                        webHandoffSection
                            .padding(.horizontal, HLSpace.xl)
                    } else if !oidcStatus.hidesPasswordAffordances, formVisibility.showsPasskeyCTA {
                        // Build 272 — the passkey CTA is offered only where the
                        // ceremony can run (`passkeySupportedForHost`). The
                        // audit-02 H-1 "visible but honestly captioned" variant
                        // shipped a primary button whose tap only re-revealed the
                        // already open password form, with a caption naming a
                        // "default HealthLog server" the distributed build does not
                        // have. Where passkeys cannot run, the password form is the
                        // primary door and stands alone.
                        passkeyPrimaryCTA
                            .padding(.horizontal, HLSpace.xl)

                        HStack(spacing: HLSpace.sm) {
                            Rectangle()
                                .fill(HLColor.separator.opacity(0.4))
                                .frame(height: 1)
                            Text("onboarding.passkey.dividerOr")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .layoutPriority(1)
                            Rectangle()
                                .fill(HLColor.separator.opacity(0.4))
                                .frame(height: 1)
                        }
                        .padding(.horizontal, HLSpace.xxl)
                    }
                #endif

                if oidcStatus.hidesPasswordAffordances {
                    // Say WHY the usual doors are missing, rather than
                    // presenting a bare SSO button with no explanation.
                    Text("onboarding.sso.onlyNote")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HLSpace.xl)
                        .accessibilityIdentifier("onboarding.sso.onlyNote")
                } else if formVisibility.showsEmailSection {
                    // #65 / 13-02 — under a live web CTA the password form is the
                    // fallback and stays closed until the fallback link (or a
                    // dead-ended web leg) opens it. Everywhere else it is the
                    // primary door and simply renders. `mayLatchOnAppear` is the
                    // one line that keeps the two apart: latching while the probe
                    // is still in flight is what made the fallback link a no-op.
                    emailSection
                        .padding(.horizontal, HLSpace.xl)
                        .onAppear {
                            if formVisibility.mayLatchOnAppear { emailSectionLatched = true }
                        }
                }

                if let err = authStore.lastError {
                    // R1 — `localizedDescription` ist die Diagnose-Fassung
                    // (fest deutsch, für Logs gedacht). Eine Anmeldefläche
                    // zeigt die lokalisierte Nutzer-Fassung; 4xx-Umschläge
                    // reicht sie unverändert durch, also bleibt „falsches
                    // Passwort" wortgleich.
                    Text(err.userFacingDescription)
                        .font(.hlSubhead)
                        .foregroundStyle(HLColor.statusBad)
                        .padding(.horizontal, HLSpace.xl)
                        // 13-04 — the banner is what a dead-ended web login
                        // leaves behind, so the journey test has to be able to
                        // address it. Identifier only: no visual change.
                        .accessibilityIdentifier("onboarding.auth.errorBanner")
                }

                VStack(spacing: HLSpace.sm) {
                    // #49 / v1.30.11 — native OIDC SSO. parity 2.9: no longer
                    // shown on EVERY host. The old rationale (an `OIDC_ONLY`
                    // instance has no other door) missed the converse — an
                    // instance with NO IdP got a button that could only fail.
                    // `/api/auth/oidc/status` now answers this directly.
                    #if canImport(AuthenticationServices) && canImport(UIKit)
                        if oidcStatus.enabled {
                            // `verbatim:` — `buttonLabel` is operator-supplied
                            // server text and must never be re-resolved against
                            // the string catalog; the fallback is already
                            // resolved by `String(localized:)`.
                            HLButton(
                                verbatim: oidcStatus.buttonLabel ?? String(localized: "onboarding.sso.title"),
                                icon: "person.badge.key.fill",
                                variant: .ghost
                            ) {
                                Task { await authStore.loginWithSSO(anchor: SceneAnchorProvider.shared) }
                            }
                            .accessibilityIdentifier("onboarding.ssoCTA")
                        }
                    #endif
                    // parity 2.9 — `OIDC_ONLY` refuses `POST /api/auth/register`
                    // too: identities come from the IdP, so a "create account"
                    // CTA here leads nowhere.
                    if registrationEnabled, !oidcStatus.hidesPasswordAffordances {
                        HLButton(
                            String(localized: "onboarding.auth.createAccount"),
                            icon: "person.crop.circle.badge.plus",
                            variant: .ghost
                        ) {
                            showRegistration = true
                        }
                        .accessibilityIdentifier("onboarding.registerCTA")
                    }
                    // R1 — der Ausgang. Immer da, unabhängig davon, ob eine
                    // Adresse gesetzt ist: eine falsch eingetippte Adresse
                    // fällt erst hier auf, und bis hierher gab es von dieser
                    // Fläche keinen Weg zurück zu ihr. Bewusst dieselbe stille
                    // Zeilenform wie der Passwort-Rückfall im Web-Handoff
                    // oben — ein Ausgang, keine Werbung.
                    if let onChangeServer {
                        Button(action: onChangeServer) {
                            Text("onboarding.auth.changeServer")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .underline()
                        }
                        .padding(.top, HLSpace.xs)
                        .accessibilityIdentifier("onboarding.changeServerCTA")
                    }
                    // parity 2.9 — pre-login path to the policy, pointed at the
                    // configured instance. Last item: available, not shouted.
                    privacyLink
                        .padding(.top, HLSpace.sm)
                }
                .padding(.horizontal, HLSpace.xl)
                .padding(.bottom, HLSpace.xxxl)
            }
            // A11Y (audit-v0162 §5) — `hlAnimation` suppresses the spring under
            // Reduce Motion so the email section cross-fades in instead of
            // springing (mirrors the OnboardingFlow container's step animation).
            .hlAnimation(.spring(response: 0.3, dampingFraction: 0.85), value: formVisibility)
        }
        .background(HLColor.background)
        .sheet(isPresented: $showRegistration) {
            RegistrationSheet(prefilledInviteToken: prefilledInviteToken)
                .hlSheetPresentation(.form)
        }
        // #37 / v1.23.0 — second-factor challenge. Presented when a password
        // login is accepted but the server requires a second factor
        // (`meta.mfaRequired`). Bound to the store's transient challenge; a
        // swipe / programmatic dismiss clears the ticket (keeps any expiry
        // message). The webauthn affordance is gated on the default passkey
        // host, the same constraint as the passkey login CTA.
        .sheet(isPresented: mfaSheetBinding) {
            if let challenge = authStore.mfaChallenge {
                MfaChallengeSheet(
                    challenge: challenge,
                    passkeySupportedForHost: passkeySupportedForHost
                )
                .hlSheetPresentation(.form)
            }
        }
        // b182 W-B182-INVITE — auto-open the prefilled registration sheet when
        // the user arrived via an invite link. The token implies they want a new
        // account; landing them straight on registration mirrors the web.
        .onAppear {
            // parity 2.9 — an `OIDC_ONLY` instance refuses `POST /api/auth/register`,
            // so auto-presenting the registration sheet would drop an invited
            // user straight into a form the server cannot accept. The invite
            // banner still explains why they are here; the IdP is their door.
            if prefilledInviteToken != nil, !oidcStatus.hidesPasswordAffordances {
                showRegistration = true
            }
        }
    }

    /// b182 W-B182-INVITE — calm invite banner. Communicates "you've been
    /// invited" without ever surfacing the token value.
    private var inviteBanner: some View {
        HLCard {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: "envelope.badge.person.crop.fill")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text("onboarding.invite.banner.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text("onboarding.invite.banner.subtitle")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.inviteBanner")
    }

    #if canImport(AuthenticationServices) && canImport(UIKit)
        /// #65 — the self-hosted web-handoff surface: a primary CTA opening the
        /// instance's own sign-in page in `ASWebAuthenticationSession` (where its
        /// passkeys + password managers work), a hint, and — unless the server
        /// refuses passwords (`OIDC_ONLY`) — a ghost fallback link that reveals
        /// the native password form for a broken web-login config.
        private var webHandoffSection: some View {
            VStack(spacing: HLSpace.xs) {
                HLButton(
                    String(localized: "onboarding.webLogin.cta"),
                    icon: "safari",
                    variant: .primary,
                    size: .large,
                    isLoading: authStore.isWorking
                ) {
                    Task { await authStore.loginWithWebLogin(anchor: SceneAnchorProvider.shared) }
                }
                .accessibilityIdentifier("onboarding.webLoginCTA")

                Text("onboarding.webLogin.hint")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, HLSpace.xxs)

                // parity with the `OIDC_ONLY` gate: an instance that refuses
                // password sign-in must not advertise a password fallback.
                if !oidcStatus.hidesPasswordAffordances {
                    Button {
                        revealEmailSection()
                    } label: {
                        // 16-02 (K5 polish) — it reads as an action now. It was
                        // caption-sized secondary text with an underline, which
                        // is the same ink as the hint two lines above it, and
                        // the operator's report was that it did not look like
                        // anything. Primary ink, the body size the app uses for
                        // a tappable line, and the region rather than the
                        // glyph: the literal 44 is `HLHitTarget.minimum`
                        // spelled out because this call site states its own
                        // frame, exactly as `OnboardingFlow`'s back control does.
                        Text("onboarding.webLogin.fallbackPassword")
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                            .underline()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.top, HLSpace.xs)
                    .accessibilityIdentifier("onboarding.webLoginFallback")
                }
            }
        }

        private var passkeyPrimaryCTA: some View {
            VStack(spacing: HLSpace.xs) {
                HLButton(
                    String(localized: "onboarding.passkey.title"),
                    icon: "faceid",
                    variant: .primary,
                    size: .large,
                    isLoading: authStore.isWorking
                ) {
                    if passkeySupportedForHost {
                        Task { await authStore.loginWithPasskey(anchor: SceneAnchorProvider.shared) }
                    } else {
                        // Self-hosted host: can't assert here — surface the
                        // working email path instead of a doomed ceremony.
                        // 16-02 — through the same seam as the fallback link:
                        // the two reveals had the identical same-tick focus
                        // bug two lines apart, and fixing one of them would
                        // have left the other reading as the defect's twin.
                        revealEmailSection()
                    }
                }
                .accessibilityIdentifier("onboarding.passkeyCTA")
                if passkeySupportedForHost {
                    Text("onboarding.passkey.providers")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                    Text("onboarding.passkey.firstTimeHint")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.top, HLSpace.xxs)
                } else {
                    // Honest degrade (audit 02 · H-1): feature stays visible + explained.
                    Text("onboarding.passkey.selfHostedNote")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, HLSpace.xxs)
                        .accessibilityIdentifier("onboarding.passkey.selfHostedNote")
                }
            }
        }
    #endif

    private var emailSection: some View {
        VStack(spacing: HLSpace.sm) {
            HLCard {
                VStack(spacing: HLSpace.md) {
                    HLTextField(title: String(localized: "onboarding.auth.field.email"), text: $email, kind: .email)
                        .focused($focused, equals: .email)
                    HLTextField(title: String(localized: "onboarding.auth.field.password"), text: $password, kind: .password)
                        .focused($focused, equals: .password)
                }
            }
            HLButton(
                "Sign in",
                variant: .primary,
                size: .large,
                isLoading: authStore.isWorking
            ) {
                Task { await login() }
            }
            .accessibilityIdentifier("onboarding.passwordLoginCTA")
        }
        // 16-02 (K5 polish) — settle, then focus. The same shape 15-02 used for
        // the medication editor, and for the same reason: focus set while the
        // field is still being created lands nowhere at all.
        .task(id: pendingEmailFocus) {
            guard pendingEmailFocus else { return }
            try? await Task.sleep(for: HLSheet.focusDelay)
            guard !Task.isCancelled else { return }
            focused = .email
            pendingEmailFocus = false
        }
    }

    /// Open the password form, and carry the keyboard into it when the opening
    /// was a deliberate act. Both reveals go through here — the fallback link
    /// and the self-hosted passkey CTA — so there is one copy of the rule.
    private func revealEmailSection() {
        let carriesFocus = AuthStepFormVisibility.revealCarriesFocus(
            wasShowing: formVisibility.showsEmailSection
        )
        emailSectionLatched = true
        if carriesFocus { pendingEmailFocus = true }
    }

    // parity 2.9 — the "Forgot password?" link is GONE, not relocated. It
    // opened `<base>/forgot-password`, a route the server app does not serve
    // (recovery is operator-only: `POST /api/admin/users/[id]/reset-password`
    // + `scripts/reset-password.mjs`). Every tap was a 404, in the one flow
    // where a user can least absorb a dead end; audit 02 · C-1 had only fixed
    // *which host* served that 404. Restore it if the route ever ships.

    /// parity 2.9 — pre-login privacy link, resolved against the **configured**
    /// server. Web offers the policy before sign-in
    /// (`auth/login/page.tsx:420-430`); iOS offered no pre-login path at all,
    /// which is App-Review-relevant. Resolving against the configured base
    /// means a self-hoster reads *their* instance's policy, not the operator's.
    /// `nil`, solange kein Server eingerichtet ist — dann gibt es keine
    /// Instanz, deren Datenschutzerklärung wir zeigen könnten, und der Link
    /// entfällt (statt auf einen erfundenen Host zu zeigen).
    static func privacyPolicyURL(keychain: KeychainStoring?) -> URL? {
        ConfiguredServerSnapshot.resolve(keychain: keychain).privacyPolicyURL
    }

    @ViewBuilder
    private var privacyLink: some View {
        if let destination = (server ?? .bundleFallback).privacyPolicyURL {
            Link(destination: destination) {
                Text("onboarding.privacy.link")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .underline()
            }
            .accessibilityIdentifier("onboarding.privacyLink")
        }
    }

    /// #37 — drives the MFA challenge sheet off the store's transient challenge.
    /// A dismissal (swipe / programmatic) clears the ticket via
    /// `dismissMfaChallenge()`, which preserves a just-set expiry `lastError` so
    /// the password form can explain why the user is back. The explicit Cancel
    /// button inside the sheet calls `cancelMFA()` instead (no leftover error).
    private var mfaSheetBinding: Binding<Bool> {
        Binding(
            get: { authStore.mfaChallenge != nil },
            set: { presented in
                if !presented { authStore.dismissMfaChallenge() }
            }
        )
    }

    private func login() async {
        await authStore.login(email: email, password: password)
    }
}

/// Modal sheet for new-account registration. Validates client-side
/// (length + non-empty + email shape) then delegates the actual
/// register + login to `AuthStore.register` which chains the two server
/// calls (see `M2-A11 §6.1` for the rationale).
private struct RegistrationSheet: View {
    /// b182 W-B182-INVITE — the opaque server invite token. Passed into the
    /// register call as-is; surfaced to the user only as an "invite applied"
    /// chip (never an editable field). `nil` for a plain registration.
    var prefilledInviteToken: String?

    @Environment(AuthStore.self) private var authStore
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var localError: String?
    @FocusState private var focused: Field?

    enum Field { case email, username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    Text(
                        String(
                            localized: "Create your HealthLog account on the selected server. You can then sign in with passkey, email, or both."
                        )
                    )
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.xl)
                    .padding(.top, HLSpace.md)

                    // b182 W-B182-INVITE — opaque "invite applied" chip. Confirms
                    // the invite is attached to this registration WITHOUT showing
                    // the token value (it's a secret). Never an editable field.
                    if prefilledInviteToken != nil {
                        inviteAppliedChip
                            .padding(.horizontal, HLSpace.xl)
                    }

                    HLCard {
                        VStack(spacing: HLSpace.md) {
                            HLTextField(title: String(localized: "onboarding.auth.field.email"), text: $email, kind: .email)
                                .focused($focused, equals: .email)
                            HLTextField(title: String(localized: "onboarding.auth.field.displayName"), text: $username, kind: .plain)
                                .focused($focused, equals: .username)
                            HLTextField(
                                title: String(localized: "onboarding.auth.field.passwordMin"),
                                text: $password,
                                kind: .newPassword
                            )
                            .focused($focused, equals: .password)
                        }
                    }
                    .padding(.horizontal, HLSpace.lg)

                    if let localError {
                        Text(localError)
                            .font(.hlSubhead)
                            .foregroundStyle(HLColor.statusBad)
                            .padding(.horizontal, HLSpace.xl)
                    } else if let err = authStore.lastError {
                        Text(err.localizedDescription)
                            .font(.hlSubhead)
                            .foregroundStyle(HLColor.statusBad)
                            .padding(.horizontal, HLSpace.xl)
                    }

                    HLButton(
                        String(localized: "onboarding.registration.submit"),
                        variant: .primary,
                        size: .large,
                        isLoading: authStore.isWorking
                    ) {
                        Task { await register() }
                    }
                    .padding(.horizontal, HLSpace.xl)
                    .accessibilityIdentifier("onboarding.registrationSubmit")

                    Spacer(minLength: HLSpace.xxl)
                }
            }
            .background(HLColor.background)
            .navigationTitle(String(localized: "onboarding.registration.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = .email }
        }
    }

    private func register() async {
        localError = nil
        // Minimal client-side validation; server enforces the canonical rules
        // (length 3-32 for username, zxcvbn >= 3 for password). We just keep
        // the user from spamming the rate-limited endpoint with empty bodies.
        //
        // v0.5.5.1 — email check tightened. The previous `email.contains("@")`
        // happily accepted `@.com`, `a@@b.com`, `foo@bar` etc., which the
        // server would later 422 anyway but only after a network round-trip
        // and a rate-limit hit. RegistrationEmailValidator runs the canonical
        // RFC-shaped regex pre-POST so the user sees the failure inline.
        guard RegistrationEmailValidator.isValid(email) else {
            localError = String(localized: "onboarding.registration.email.invalid")
            return
        }
        guard username.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            localError = String(localized: "onboarding.registration.displayNameTooShort")
            return
        }
        guard password.count >= 8 else {
            localError = String(localized: "onboarding.registration.passwordTooShort")
            return
        }
        await authStore.register(
            email: email,
            username: username,
            password: password,
            inviteToken: prefilledInviteToken
        )
        // RootView + OnboardingFlow observe the phase transition — once the
        // server-login resolves the store lands on `.authenticating(user)`
        // (v0.6.0.9), and OnboardingFlow bounces to the HealthKit step. We
        // dismiss the registration sheet on either transitional `.authenticating`
        // or terminal `.authenticated` to be defensive against a slow parent
        // teardown.
        switch authStore.phase {
        case .authenticating, .authenticated:
            dismiss()
        case .unknown, .unauthenticated, .standalone:
            // b182 W-B182-INVITE — registration didn't complete. If the user
            // came via an invite and the server rejected it (403 — closed
            // instance + invalid/expired/exhausted invite), surface a clear
            // localized inline message instead of the raw server string.
            if prefilledInviteToken != nil, authStore.lastError?.isInvalidInviteError == true {
                localError = String(localized: "onboarding.registration.invite.invalid")
            }
        }
    }

    /// b182 W-B182-INVITE — opaque "invite applied" confirmation chip. Shows the
    /// fact, never the token. Monochrome, glass-free — matches the onboarding
    /// design language.
    private var inviteAppliedChip: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hlCaption)
            Text("onboarding.registration.invite.applied")
                .font(.hlCaption)
        }
        .foregroundStyle(HLText.primary)
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xs)
        .background(HLColor.surface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.inviteAppliedChip")
    }
}

/// Client-side email validator for the onboarding registration sheet.
///
/// Replaces an earlier `email.contains("@")` check that accepted shapes
/// like `@.com`, `a@@b.com`, `foo@bar` (no TLD). The regex enforces a
/// minimum RFC-shaped form — local-part, single `@`, domain with TLD —
/// pre-POST so the user gets inline feedback before the network call.
/// The server still owns canonical validation; this is a UX guard only.
///
/// Implementation note: lives at file-scope (not inside the private
/// `RegistrationSheet`) so the test suite can address it directly.
/// Marked `enum` (no cases) to communicate the namespace-only intent
/// and prevent accidental instantiation. Uses `NSPredicate` for the
/// case-insensitive `MATCHES` operator — `Regex` literals require
/// macOS 13 / iOS 16 + the explicit `(?i)` flag, and the predicate is
/// idiomatic in the surrounding `HealthLogCore` Util layer.
public enum RegistrationEmailValidator {
    /// `^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$` — case-insensitive.
    /// Rejects empty local-part, multiple `@`, missing TLD, TLD shorter
    /// than 2 characters. Accepts standard plus-addressing + subdomains.
    public static func isValid(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$"
        return NSPredicate(format: "SELF MATCHES[c] %@", pattern).evaluate(with: trimmed)
    }
}

struct HLTextField: View {
    enum Kind { case email, password, newPassword, plain }

    let title: String
    @Binding var text: String
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(title)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)

            Group {
                switch kind {
                case .email:
                    TextField("", text: $text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .password:
                    SecureField("", text: $text)
                        .textContentType(.password)
                case .newPassword:
                    // Registration path — offer iOS's strong-password suggestion.
                    SecureField("", text: $text)
                        .textContentType(.newPassword)
                case .plain:
                    TextField("", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.hlHeadline)
            .foregroundStyle(HLText.primary)
            .padding(HLSpace.md)
            .background(HLColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
    }
}
