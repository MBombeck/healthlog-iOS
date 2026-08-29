import CryptoKit
import Foundation
import Observation

/// Server-owned onboarding-tour / setup-completion state (#32, server v1.18.6).
///
/// **What moved to the server.** Whether the user has finished onboarding was
/// previously inferred locally (Keychain token + `SyncModeStore` flag). That
/// flag is per-install: it does not survive a reinstall and does not sync across
/// devices, so a returning user could be dropped back into the setup wizard on a
/// fresh device even though they had already completed it elsewhere. This store
/// reconciles the local signal against the server-owned setup state off
/// `GET /api/auth/me`, and stamps the server on finish
/// (`POST /api/onboarding/tour`). Progress now survives reinstall, syncs
/// across devices, and is shared with the web.
///
/// **25-03 (GH #1) — what "completed" is derived from.** The tour marker
/// alone answered wrongly for accounts set up in the web UI (the web setup
/// wizard writes `onboardingCompletedAt`, not the tour marker), so the
/// classification now derives completion from what exists on the account —
/// see ``classifySetupCompletion(_:)``.
///
/// **Phase 08 Wave 1 — what changed, and why.** Two properties collapsed three
/// different worlds into one. `refresh()` answered a network failure with the
/// cached value and left `hasLoaded == false`, which is also the state before
/// any lookup starts and the state while one is in flight: a failed lookup was
/// therefore not merely mishandled, it was **unobservable**. And the cache was a
/// single install-wide `Bool` under one key, so an account that signed in after
/// an interrupted sign-out inherited its predecessor's completion.
///
/// Both are now structural:
///
/// - ``resolution`` is the four-state answer (`completed`, `incomplete`,
///   `endpointAbsent`, `unavailable`) and `nil` until a lookup settles. It is
///   the Wave-0 vocabulary, so the routing rules live in one pure place
///   (``PostAuthenticationRouteResolver``) rather than in each consumer.
/// - The cache is keyed per owner, and ``evidence`` says *whose* the local value
///   is. Only same-account evidence may stand in for a missing answer.
///
/// **The legacy slot.** Installs upgrading over this build still carry a value
/// under the unscoped key, and its owner cannot be established after the fact.
/// It is accepted, never adopted into an account's scope, and admissible only
/// under `endpointAbsent` — a state in which the request *succeeded* against
/// this session and the deployment simply has no such field, so the local mirror
/// is the only evidence there will ever be. Under `unavailable` nothing was
/// verified at all and it counts for nothing. The first owner-scoped write
/// retires it.
@MainActor
@Observable
public final class OnboardingTourStore {
    /// Canonical UserDefaults key for the local completion cache — now the
    /// *prefix* of the per-owner keys and, on its own, the legacy unscoped slot.
    /// Public so the Mocks layer / logout-wipe suite can seed + assert it.
    public nonisolated static let cacheKey = "hl.onboarding.tourCompleted"

    public typealias Owner = PostAuthenticationRouteInput.Owner
    public typealias ServerCompletion = PostAuthenticationRouteInput.ServerCompletion
    public typealias CachedCompletion = PostAuthenticationRouteInput.CachedCompletion

    /// `true` only with positive, account-safe evidence that setup is behind
    /// this user. Never a guess: it is derived from ``resolution`` and
    /// ``evidence`` through the one pure resolver, so it cannot disagree with
    /// the route the flow takes.
    public private(set) var isCompleted = false

    /// What the last settled lookup said. `nil` means no lookup has settled —
    /// none started, or one is still in flight. **`unavailable` is a settled
    /// state**: the question was asked and did not resolve, which is a different
    /// thing from not having asked.
    public private(set) var resolution: ServerCompletion?

    /// The local evidence that was admissible at the last settle, and whose it
    /// is. `absent` until then.
    public private(set) var evidence: CachedCompletion = .absent

    /// Whether the completion lookup has settled at all. Consumers that need the
    /// *answer* read ``resolution``; this only says the question is no longer
    /// open.
    public var hasLoaded: Bool {
        resolution != nil
    }

    /// The owner the current state belongs to. A result computed for a
    /// superseded owner is neither published nor returned — the store answers
    /// only for whoever is signed in now.
    private var activeOwner: Owner?

    private let repo: OnboardingTourRepository
    private let defaults: UserDefaults

    public init(repo: OnboardingTourRepository, defaults: UserDefaults = .standard) {
        self.repo = repo
        self.defaults = defaults
    }

    /// Reconcile against the server (`GET /api/auth/me`) for `owner`.
    ///
    /// Server-authoritative: a present flag overwrites this owner's cache in
    /// both directions. An absent field or an unresolved lookup writes nothing
    /// and, crucially, **answers nothing** — the outcome is recorded on
    /// ``resolution`` and the caller decides with the resolver.
    ///
    /// Passing no owner is the un-attributed path: legitimate before an identity
    /// exists, and it is exactly the path that may not spend a cached `true`.
    public func refresh(owner: Owner? = nil) async {
        activeOwner = owner
        let answer = await resolveCompletion()
        // The lookup suspended. If the account changed underneath it, this
        // answer belongs to nobody here: publish nothing, and return nothing
        // either — a superseded result leaks just as far through a return value
        // as through a published property.
        guard owner == activeOwner else { return }
        settle(answer, owner: owner)
    }

    /// Stamp the onboarding setup wizard as finished — called from the
    /// `OnboardingFlow` terminal handoff (server / demo / standalone).
    /// Optimistic: flips the flag + this owner's cache immediately so routing is
    /// correct even if the server write is deferred, then best-effort posts
    /// `completed:true` (`POST /api/onboarding/tour`). A failed POST leaves the
    /// cache set; a later `refresh()` reconciles. No-op when already completed,
    /// so a re-mount race can't double-post.
    ///
    /// `outcome` defaults to `.completed` (the user walked the wizard to the end).
    public func markCompleted(owner: Owner? = nil, outcome: TourUpdateBody.Outcome = .completed) async {
        guard !isCompleted else { return }
        activeOwner = owner
        settle(.completed, owner: owner)
        do {
            let response = try await repo.markCompleted(outcome: outcome)
            guard owner == activeOwner else { return }
            settle(response.onboardingTourCompleted ? .completed : .incomplete, owner: owner)
        } catch {
            // Endpoint absent / offline: this owner's cache is the durable
            // signal for this install; the next reachable `markCompleted` /
            // `refresh` reconciles to the server. Fail-soft — log the error
            // shape only (type, no payload) so a persistent failure is
            // diagnosable. (audit-v0162 L-E1)
            HLLog.ui.debug(
                "Onboarding tour completion deferred: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    /// Logout wipe — resets to the un-resolved baseline and clears **every**
    /// cached completion on this install, not just the current owner's, so the
    /// next user reconciles their OWN server flag and no residue survives a
    /// sign-out. Key-agnostic by prefix: a scope this build never wrote is still
    /// swept.
    public func clearOnLogout() {
        isCompleted = false
        resolution = nil
        evidence = .absent
        activeOwner = nil
        for key in completionKeys() {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Settling

    /// The repository read, classified into the four-state Wave-1 vocabulary
    /// instead of collapsed into a `Bool` plus a `catch`.
    ///
    /// A caller holding `Bool?` and a `catch` has to invent a policy for both
    /// non-answers at the call site, and the policy every such caller reached
    /// for was `false`. Naming the four states makes that mistake
    /// unrepresentable rather than merely discouraged, and the routing rules
    /// then live in exactly one pure place.
    ///
    /// The error is not rethrown and nothing is logged: `unavailable` is a
    /// published, testable state, which is a strictly better record of the
    /// failure than the line in a log the previous `catch` did not even write.
    private func resolveCompletion() async -> ServerCompletion {
        do {
            return try await Self.classifySetupCompletion(repo.fetchSetupState())
        } catch {
            return .unavailable
        }
    }

    /// **25-03 (GH #1) — completeness derived from what exists on the
    /// account, with the marker as a fast path and never the sole source.**
    ///
    /// The tour marker is stamped by this app's wizard and by the web's
    /// coachmark tour — but not by the web *setup wizard*, so a profile
    /// created in the web UI carried a `false` marker over a fully-set-up
    /// account, and rule 1 of the resolver ("a server answer wins outright")
    /// then correctly routed that wrong answer into the full flow. The
    /// public reply on issue #1 promised the check would be derived from
    /// what actually exists on the account; this is that derivation, and it
    /// rides the same `/me` response the lookup always fetched — no second
    /// request, no second failure mode.
    ///
    /// Three rules, in order:
    ///
    /// 1. **A true marker completes.** Unchanged fast path.
    /// 2. **Account evidence completes.** The web wizard's own completion
    ///    record (`onboardingCompletedAt`) or profile substance the setup
    ///    flow would otherwise ask for again. Evidence only ever *widens*
    ///    toward `completed`: it cannot demote a marker-true account and it
    ///    cannot turn a non-answer into an answer — a thrown lookup never
    ///    reaches this function.
    /// 3. **`incomplete` requires the row to say so and show nothing.** The
    ///    request succeeded, the marker field is present and `false`, and no
    ///    evidence stands against it — the one state that is genuinely a new
    ///    account. A row with no marker field and no evidence stays
    ///    `endpointAbsent` (pre-v1.18.6), where the same-account cache keeps
    ///    its established standing.
    nonisolated static func classifySetupCompletion(_ row: AuthMeOnboarding) -> ServerCompletion {
        if row.onboardingTourCompleted == true { return .completed }
        if row.hasSetupCompletionRecord || row.hasProfileSubstance { return .completed }
        if row.onboardingTourCompleted == false { return .incomplete }
        return .endpointAbsent
    }

    /// Record one settled answer: persist what the server said, re-read the
    /// local evidence, and let the one pure resolver decide what that means.
    /// `isCompleted` is therefore a *consequence* of the route rather than a
    /// second, hand-maintained opinion about it.
    private func settle(_ answer: ServerCompletion, owner: Owner?) {
        switch answer {
        case .completed: persist(true, owner: owner)
        case .incomplete: persist(false, owner: owner)
        case .endpointAbsent, .unavailable: break
        }
        resolution = answer
        evidence = Self.admissibleEvidence(cachedEvidence(for: owner), under: answer)
        isCompleted = PostAuthenticationRouteResolver.resolve(
            server: answer,
            cache: evidence
        ) == .authenticatedShell
    }

    // MARK: - The cache, and whose it is

    /// Local evidence before admissibility is decided.
    private enum LocalEvidence {
        case none
        /// Stored under this owner's scope.
        case owned(Bool)
        /// Stored under some other owner's scope — never evidence about this one.
        case foreign(Bool)
        /// The pre-Wave-1 install-wide slot. Its owner cannot be established.
        case unattributed(Bool)
    }

    private func cachedEvidence(for owner: Owner?) -> LocalEvidence {
        if let owner, let mine = storedFlag(Self.cacheKey(for: owner)) { return .owned(mine) }
        if let theirs = foreignFlag(excluding: owner) { return .foreign(theirs) }
        if let legacy = storedFlag(Self.cacheKey) { return .unattributed(legacy) }
        return .none
    }

    /// The one rule that decides whether an un-attributed legacy value counts:
    /// **only when the current session was verified on this tick.** Under
    /// `endpointAbsent` the request succeeded and the deployment simply carries
    /// no field, so the install-wide mirror is the only evidence that will ever
    /// exist for it. Under `unavailable` nothing was verified — not the session,
    /// not the account — so a bare `true` from an unknown owner is a guess, and
    /// the retry route exists precisely so it does not have to be made.
    private static func admissibleEvidence(
        _ evidence: LocalEvidence,
        under answer: ServerCompletion
    ) -> CachedCompletion {
        switch evidence {
        case .none: .absent
        case let .owned(completed): .sameAccount(completed: completed)
        case let .foreign(completed): .otherAccount(completed: completed)
        case let .unattributed(completed):
            answer == .endpointAbsent ? .sameAccount(completed: completed) : .absent
        }
    }

    /// Writes the answer into `owner`'s own scope, and retires the legacy
    /// install-wide slot the first time an attributed value exists. The legacy
    /// value is never *copied* into a scope: adopting it would launder an
    /// unknown owner's answer into an attributed one, which is the whole defect.
    private func persist(_ completed: Bool, owner: Owner?) {
        defaults.set(completed, forKey: Self.cacheKey(for: owner))
        guard owner != nil else { return }
        defaults.removeObject(forKey: Self.cacheKey)
    }

    private func storedFlag(_ key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    private func foreignFlag(excluding owner: Owner?) -> Bool? {
        let mine = owner.map { Self.cacheKey(for: $0) }
        for key in completionKeys().sorted() where key != Self.cacheKey && key != mine {
            if let flag = storedFlag(key) { return flag }
        }
        return nil
    }

    private func completionKeys() -> [String] {
        let scoped = Self.cacheKey + "."
        return defaults.dictionaryRepresentation().keys.filter {
            $0 == Self.cacheKey || $0.hasPrefix(scoped)
        }
    }

    /// The cache key for one owner. Scoped by a digest of the owner id, not by
    /// the id itself: a routing bool does not justify writing an account
    /// identifier into `UserDefaults` in the clear, and the digest is every bit
    /// as good at telling two accounts apart. The **generation** is deliberately
    /// not part of the key — it fences an in-flight decision against a session
    /// change, while the cache has to survive across sign-ins of the same user.
    nonisolated static func cacheKey(for owner: Owner?) -> String {
        guard let owner else { return cacheKey }
        let digest = SHA256.hash(data: Data(owner.id.utf8))
        let scope = digest.map { String(format: "%02x", $0) }.joined()
        return cacheKey + "." + String(scope.prefix(16))
    }

    #if DEBUG
        /// Test-only seam — set the completion state without a round-trip so the
        /// logout-wipe suite can prove `clearOnLogout` purges it.
        func seedForTesting(isCompleted: Bool, hasLoaded: Bool) {
            self.isCompleted = isCompleted
            resolution = hasLoaded ? (isCompleted ? .completed : .incomplete) : nil
            evidence = isCompleted ? .sameAccount(completed: true) : .absent
        }
    #endif
}
