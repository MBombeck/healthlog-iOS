import Foundation

// Phase 24 / plan 24-01 — when the repair runs, and how often.
//
// `AuthService.recoverUserIDFromProfile()` knows HOW to recover an identity.
// This decides WHETHER to, and it is deliberately the narrowest possible
// trigger: a token is present, and the slot holds a value that trims to empty.
// That is the poisoned state and nothing else.

extension AuthStore {
    /// The user id `bootstrap()` should publish, healing a blanked slot first.
    ///
    /// Three cases, and only the middle one costs anything:
    ///
    /// 1. **No value at all** → `nil`, and the shipped bootstrap semantics are
    ///    untouched. A missing slot is not the poisoned state: the poisoning
    ///    writes `""` (a successful Keychain upsert), never nothing. Treating
    ///    absence as a recovery trigger would change how a token-without-id
    ///    install resolves, which is a different question this plan does not
    ///    reopen.
    /// 2. **Blank or whitespace** → the poisoned state. One recovery attempt,
    ///    at most once per launch.
    /// 3. **A usable id** → returned verbatim, with no network call. A healthy
    ///    installation pays nothing for this repair, which is what keeps it
    ///    from becoming a cold-launch tax on users who were never affected.
    ///
    /// **It cannot loop.** The latch is set BEFORE the await, so a second
    /// `bootstrap()` in the same process never re-attempts, whatever the first
    /// attempt returned. A failed recovery is retried on the NEXT launch — the
    /// natural retry cadence for a once-per-launch repair, and the only one
    /// that cannot spin.
    ///
    /// **It cannot wedge.** On failure the stored value is returned unchanged,
    /// so the phase that follows is byte-for-byte the phase this build would
    /// have published without the repair.
    func resolveBootstrapUserID() async -> String? {
        guard let stored = keychain.getString(forKey: KeychainKey.userID) else { return nil }
        if stored.trimmedNonEmptyHint != nil { return stored }
        guard !didAttemptUserIDRecovery else { return stored }
        didAttemptUserIDRecovery = true
        guard let recovered = await auth.recoverUserIDFromProfile() else { return stored }
        return recovered
    }
}
