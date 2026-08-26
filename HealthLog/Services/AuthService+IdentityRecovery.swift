import Foundation

// Phase 24 / plan 24-01 — the repair half.
//
// The guard in `persist` stops NEW poisonings. It repairs nobody who already
// has the empty string in their Keychain, and that set is not hypothetical: it
// is every installation that has run b266, b267 or b268 for more than a day,
// because the access token lives 24 h and the first refresh after login wrote
// `""` into `KeychainKey.userID`.
//
// Those installations cannot recover on their own, and the reason is a
// deadlock rather than an oversight: the one read that knows the real user id
// is the profile load, and the profile load is itself fenced by the Phase-06
// authenticated-session lease — which needs the user id. The value required to
// lift the fence sits behind the fence. Without this file, a guarded build
// leaves every affected device showing the same permanent skeleton it shows
// today, forever, and the only exit remains a manual logout and login.
//
// The Bearer is still valid, so exactly one unfenced read closes it.

extension AuthService {
    /// One `GET /api/auth/me` to recover the real user id, persisted into the
    /// slot a pre-24-01 refresh blanked. Returns the recovered id, or `nil` if
    /// the identity could not be established right now.
    ///
    /// **Bounded, so it cannot wedge a launch.** `failFast: true` +
    /// `maxRetries: 0` is the same fail-fast auth session `probeAccountStatus`
    /// uses: an offline cold launch fails immediately instead of parking on the
    /// patient outbox session's 60 s resource timeout. Every failure — offline,
    /// 5xx, a decode that yields no id, a Keychain write that throws — resolves
    /// to `nil`, and the caller then behaves exactly as the shipped bootstrap
    /// behaved before this existed. Nothing here can turn a bad network into a
    /// stuck app.
    ///
    /// **It does not decide when to run.** Whether a recovery is warranted, and
    /// how often it may be attempted, is launch-lifecycle policy and belongs to
    /// `AuthStore` — see `AuthStore.resolveBootstrapUserID()`, which latches it
    /// to at most one attempt per launch.
    ///
    /// A 401 here is handled by the ordinary recovery bridge: the request is
    /// retried once behind a refresh, and a genuinely dead session tears down
    /// through `onUnauthorized` as it always has. That is the correct outcome —
    /// an account whose token no longer authenticates has no identity to
    /// recover.
    func recoverUserIDFromProfile() async -> String? {
        guard isAuthenticated else { return nil }
        let request = APIRequest<User>(
            method: .get,
            path: "/api/auth/me",
            maxRetries: 0,
            failFast: true
        )
        guard let user = try? await api.send(request),
              let recovered = user.id.trimmedNonEmptyHint else
        {
            HLLog.auth.notice("Identity recovery unavailable; the blanked user id stays blank until the next launch.")
            return nil
        }
        do {
            // A single-slot write, so it is atomic on its own terms and needs
            // none of `persist`'s snapshot/rollback machinery — and it must not
            // go through `persist`, which would rewrite token slots this call
            // knows nothing about.
            try keychain.setString(recovered, forKey: KeychainKey.userID)
        } catch {
            HLLog.auth.warning("Identity recovery could not persist the recovered user id.")
            return nil
        }
        HLLog.auth.notice("Recovered a blanked Keychain user id from the profile route.")
        return recovered
    }
}
