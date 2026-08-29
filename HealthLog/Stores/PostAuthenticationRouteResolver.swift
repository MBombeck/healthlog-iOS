import Foundation

/// **Phase 08 Wave 0 — the vocabulary a post-authentication route is decided
/// in. Contract only: nothing here resolves, routes, or mutates.**
///
/// Today the app has no post-authentication route at all. Every successful
/// sign-in — password, passkey, OIDC, web handoff — lands on
/// `AuthStore.Phase.authenticating(user)`, and the single surface that reacts
/// to that phase (`OnboardingFlow.handlePhase`) moves the flow to
/// `.healthKit` unconditionally. The server-owned completion flag that
/// `OnboardingTourStore` reconciles on the same tick is read by nothing: a
/// user who finished setup on another device, or on this device before a
/// reinstall, walks the optional permission, AI, anamnesis and baseline steps
/// again.
///
/// The three routes below are the whole decision space, and the third one is
/// the point of the exercise. A completion lookup that did not resolve is not
/// a completion lookup that answered "no"; collapsing the two is how a
/// transient network blip becomes a replayed setup wizard. The same shape
/// already exists twice in this codebase for exactly that reason —
/// `DisclaimerAckStore.shouldGate(hasLoaded:isAcknowledged:)` and
/// `MfaEnrollmentGateStore.shouldGate(hasLoaded:isRequired:)` both refuse to
/// act on an unresolved read.
public enum PostAuthenticationRoute: String, Sendable, Hashable, CaseIterable {
    /// Setup is behind the user: hand straight to the authenticated shell.
    case authenticatedShell
    /// Setup is genuinely outstanding, or a genuinely required datum is
    /// missing. Optional steps the user already declined do not qualify.
    case setup
    /// The completion lookup did not resolve and no account-safe local
    /// evidence stands in for it. Ask again; never replay setup on a guess.
    case retryCompletionLookup
}

/// **Phase 16 Plan 01 — what this DEVICE can say about its own local setup.**
///
/// Kept separate from ``PostAuthenticationRoute`` because it answers a
/// different question about a different resource. The route above is decided
/// from account-owned facts (the server's completion flag, a same-account
/// cache); HealthKit authorization and notification permission are owned by the
/// handset, survive no reinstall, and travel to no second device. Collapsing
/// the two is K10: the operator's fresh install was handed to the shell on the
/// strength of a flag the web onboarding had set, and the dashboard then told
/// him Apple Health was not connected — a step the app has, and never showed.
///
/// `unknown` exists for the same reason ``PostAuthenticationRoute/retryCompletionLookup``
/// does: a signal that did not resolve is not a `no`. It is deliberately the
/// *conservative* answer here rather than the cautious one, because the two
/// point opposite ways — inventing setup work for a returning user on an
/// unreadable signal is the 08-08 defect running backwards.
public enum DeviceLocalSetupState: String, Sendable, Hashable, CaseIterable {
    /// This device has been through the local setup for this account.
    case complete
    /// This device has not. A fresh install, a reinstall, a second handset.
    case outstanding
    /// Nothing composed can say. Never treated as `outstanding`.
    case unknown
}

/// **Phase 16 Plan 01 — how much of setup an authenticated user still owes.**
///
/// The 08-08 skip was right for the steps it was built for and wrong for the
/// two it also swallowed. This is the distinction it lacked: the account-level
/// tail (AI source, anamnesis, baseline profile) belongs to the account and is
/// correctly skipped for a user who finished it anywhere; the device-local head
/// (HealthKit, notifications) belongs to the handset and cannot be finished
/// anywhere else.
public enum PostAuthenticationSetupScope: String, Sendable, Hashable, CaseIterable {
    /// Nothing outstanding — hand over to the shell.
    case none
    /// The device-local head only. The account-level tail stays skipped.
    case deviceLocalOnly
    /// Everything: this account never finished setup at all.
    case full
}

/// The immutable input a post-authentication route is resolved from.
///
/// **Account safety is carried in the value, not assumed by the caller.** The
/// owner is the Phase-06 authenticated-owner/generation pair
/// (``AuthenticatedSessionLease``), and cached evidence is only ever offered
/// as ``CachedCompletion/sameAccount(completed:)`` when it provably belongs to
/// that owner. Nothing here may be keyed by email, by a bearer token, or by a
/// single global bool: the completion cache in `OnboardingTourStore` is one
/// unscoped `Bool` under `hl.onboarding.tourCompleted` today, which is
/// precisely why account B can inherit account A's answer whenever the logout
/// hook did not run.
///
/// Wave 1 owns the resolution. This type deliberately exposes no `resolve`,
/// touches no store, and reads no `UserDefaults`.
public struct PostAuthenticationRouteInput: Sendable, Hashable {
    /// How the session was obtained. Present so the contract can state that it
    /// does **not** matter: all four methods produce the same decision, and a
    /// method-specific exception is a defect, not a feature.
    public enum Method: String, Sendable, Hashable, CaseIterable {
        case password
        case passkey
        case oidc
        case webHandoff
    }

    /// What the server said about setup completion on this authentication tick.
    ///
    /// 25-03 (GH #1) — "what the server said" is derived from the whole `/me`
    /// row by ``OnboardingTourStore/classifySetupCompletion(_:)``: the tour
    /// marker is a fast path, and the account's own evidence (the web
    /// wizard's completion record, profile substance) completes too. The
    /// derivation changes which answer arrives here; it changes nothing about
    /// what each answer means to the route.
    public enum ServerCompletion: String, Sendable, Hashable, CaseIterable {
        /// The server answered, and setup is complete — by marker or by what
        /// actually exists on the account.
        case completed
        /// The server answered, and setup is not complete: the marker is
        /// present and `false`, and the row shows no account evidence either.
        case incomplete
        /// The server answered, but this deployment does not carry the field
        /// (pre-v1.18.6). Not an error, and not an answer either.
        case endpointAbsent
        /// The lookup did not resolve — offline, timeout, transport failure.
        case unavailable
    }

    /// Local evidence, and whose it is. `otherAccount` exists so the unsafe
    /// case has a name rather than being silently absent.
    public enum CachedCompletion: Sendable, Hashable {
        case absent
        case sameAccount(completed: Bool)
        case otherAccount(completed: Bool)
    }

    /// The authenticated owner this decision belongs to, mirroring the
    /// Phase-06 lease so a stale decision cannot be applied to a later session.
    public struct Owner: Sendable, Hashable {
        public let id: String
        public let generation: UInt64

        public init(id: String, generation: UInt64) {
            self.id = id
            self.generation = generation
        }
    }

    public let owner: Owner
    public let method: Method
    public let server: ServerCompletion
    public let cache: CachedCompletion
    /// A datum the app genuinely cannot run without is absent. This is the
    /// only reason a completed user may be sent back into setup.
    public let missingRequiredDatum: Bool
    /// The user declined an optional permission. Never a reason to treat setup
    /// as incomplete — declining is a completed decision, not a missing one.
    public let optionalPermissionDenied: Bool

    public init(
        owner: Owner,
        method: Method,
        server: ServerCompletion,
        cache: CachedCompletion,
        missingRequiredDatum: Bool = false,
        optionalPermissionDenied: Bool = false
    ) {
        self.owner = owner
        self.method = method
        self.server = server
        self.cache = cache
        self.missingRequiredDatum = missingRequiredDatum
        self.optionalPermissionDenied = optionalPermissionDenied
    }
}

/// **Phase 08 Wave 1 — the decision.** Pure, total, and account-safe: no store,
/// no `UserDefaults`, no clock, no network. Every cell of the Wave-0 matrix has
/// exactly one answer here, and the answers are the ones that file froze.
///
/// Three rules, in order:
///
/// 1. **A server answer wins outright.** `completed` hands over to the shell and
///    `incomplete` starts setup, whatever any cache says in either direction. A
///    cache is a mirror of a past answer; the answer itself is present.
/// 2. **Only same-account evidence may stand in for a missing answer.** Another
///    account's cached completion is not evidence about this one, and an absent
///    cache is not a `false`.
/// 3. **Ambiguity is its own route.** When the lookup did not resolve and no
///    same-account evidence exists, the answer is *unknown*, and unknown is
///    never setup: a transient blip must not replay a wizard the user finished
///    months ago, and it must not open the shell either.
///
/// `endpointAbsent` differs from `unavailable` in one place and it matters: the
/// request **succeeded**, the deployment simply carries no such field, so the
/// same-account mirror is the only evidence there will ever be and setup — not
/// retry — is the honest floor when it says nothing. Retrying a deployment that
/// will never answer is an infinite loop with a button on it.
public enum PostAuthenticationRouteResolver {
    /// The decision for a fully-formed input.
    ///
    /// `optionalPermissionDenied` is deliberately **not** forwarded: declining
    /// an optional step is a completed decision, not a missing datum, so it
    /// cannot move the route. It is carried on the input so that a caller which
    /// tracks it cannot quietly pass it where `missingRequiredDatum` belongs.
    /// `method` is not forwarded either, for the reason the contract states: all
    /// four sign-in doors open onto the same room.
    public static func resolve(_ input: PostAuthenticationRouteInput) -> PostAuthenticationRoute {
        resolve(
            server: input.server,
            cache: input.cache,
            missingRequiredDatum: input.missingRequiredDatum
        )
    }

    /// The same decision without an owner or a method, for the production caller
    /// that has neither to offer: `AuthStore` funnels every successful sign-in
    /// through one `.authenticating` transition, so there is no method to name
    /// at the point the route is chosen, and inventing one would be a lie the
    /// type system would happily accept.
    public static func resolve(
        server: PostAuthenticationRouteInput.ServerCompletion,
        cache: PostAuthenticationRouteInput.CachedCompletion,
        missingRequiredDatum: Bool = false
    ) -> PostAuthenticationRoute {
        let route = completionRoute(server: server, cache: cache)
        // The one reason a completed user may still be sent into setup. It is a
        // narrowing, never a widening: it can only turn `authenticatedShell`
        // into `setup`, and it can never turn an ambiguous answer into either.
        guard route == .authenticatedShell, missingRequiredDatum else { return route }
        return .setup
    }

    /// **Phase 16 Plan 01 (K10) — the second half of the decision.**
    ///
    /// The account-level answer alone cannot decide what a user is shown,
    /// because one of the things setup does is per device. This narrows the
    /// account's `done` by exactly one question — has *this handset* done its
    /// own half? — and narrows nothing else. It is pure, total, and takes no
    /// store: the caller reads the device signal from the store that owns it.
    ///
    /// Three rules, and the third is the one that keeps this from becoming the
    /// defect it fixes:
    ///
    /// 1. **An unfinished account owes everything.** There is no device-local
    ///    shortcut through setup a user never completed; the head is inside
    ///    the full route already.
    /// 2. **A finished account owes only what this device owes.** That is the
    ///    whole of K10: the flag is spent on the tail it was earned for, and
    ///    is not allowed to answer for a resource it never touched.
    /// 3. **Unknown is never work.** A device signal that did not resolve
    ///    hands over to the shell, exactly as today. Setup is never replayed on
    ///    a guess — the K12-verified "Verbinden" affordance on the dashboard is
    ///    still there, and a wrongly-shown wizard is worse than a banner.
    public static func setupScope(
        accountSetupComplete: Bool,
        deviceLocalSetup: DeviceLocalSetupState
    ) -> PostAuthenticationSetupScope {
        guard accountSetupComplete else { return .full }
        return deviceLocalSetup == .outstanding ? .deviceLocalOnly : .none
    }

    private static func completionRoute(
        server: PostAuthenticationRouteInput.ServerCompletion,
        cache: PostAuthenticationRouteInput.CachedCompletion
    ) -> PostAuthenticationRoute {
        switch server {
        case .completed:
            .authenticatedShell
        case .incomplete:
            .setup
        case .endpointAbsent:
            sameAccountCompletion(cache) == true ? .authenticatedShell : .setup
        case .unavailable:
            switch sameAccountCompletion(cache) {
            case true: .authenticatedShell
            case false: .setup
            case nil: .retryCompletionLookup
            }
        }
    }

    /// The cached answer, but only when it provably belongs to this account.
    /// `otherAccount` and `absent` are the same amount of evidence — none.
    private static func sameAccountCompletion(
        _ cache: PostAuthenticationRouteInput.CachedCompletion
    ) -> Bool? {
        guard case let .sameAccount(completed) = cache else { return nil }
        return completed
    }
}
