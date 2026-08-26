import Foundation

// MARK: - Local wipe after a server-side data reset (parity item 2.5)

extension AppContainer {
    /// Stores that must **survive** `wipeLocalDataAfterServerReset`.
    ///
    /// The wipe reuses the `LogoutClearable` registry so a new PHI-bearing store
    /// is covered automatically (AUD-7 H1) — but the registry was built for
    /// *logout*, where clearing session/mode/account state is exactly right.
    /// After a data reset the account is still signed in, so a handful of those
    /// stores would be actively harmful to clear. Over-clearing a data store is
    /// harmless (it re-fetches); clearing these is not:
    ///
    /// - `SyncModeStore` — holds paired-vs-standalone routing. Clearing it
    ///   strands a perfectly good install with no mode and drops the user into
    ///   the onboarding mode picker.
    /// - `DisclaimerAckStore` — clearing re-raises the blocking medical-
    ///   disclaimer gate in front of a user who already accepted it.
    /// - `FeatureFlagsStore` — module visibility; a transient empty map hides
    ///   whole surfaces until the next fetch resolves.
    /// - `MfaEnrollmentGateStore` — account security policy, untouched by a data
    ///   reset and unrelated to health data.
    /// - `SessionsStore` — the reset does not revoke sessions, so the inventory
    ///   stays valid.
    ///
    /// Kept as an explicit, reviewed list rather than an inverted allow-list:
    /// the failure mode of forgetting an entry here is a recoverable annoyance,
    /// whereas forgetting to clear a PHI store paints deleted health data.
    private func survivesDataReset(_ clearable: any LogoutClearable) -> Bool {
        clearable is SyncModeStore
            || clearable is DisclaimerAckStore
            || clearable is FeatureFlagsStore
            || clearable is MfaEnrollmentGateStore
            || clearable is SessionsStore
    }

    /// Drop every local trace of the health record after `DELETE
    /// /api/settings/data` succeeded, **without** signing the user out.
    ///
    /// This is the deliberate middle ground between "do nothing" and
    /// `performFullLocalLogout`. The account, the Keychain bundle and every
    /// credential survive — only the data the server just deleted is purged
    /// locally. Reusing the logout cascade wholesale would have signed the user
    /// out, which is precisely the outcome this feature exists to avoid.
    ///
    /// Order mirrors `performFullLocalLogout`'s reasoning:
    ///
    /// 1. **Actor-held caches first.** `SWRCoordinator` + the server-stats repos
    ///    keep their own snapshots; without dropping them the next foreground
    ///    revalidate re-paints records the server no longer has.
    /// 2. **URLCache purge.** The authenticated sessions run on
    ///    `URLSessionConfiguration.default`, whose on-disk cache can retain
    ///    cacheable GET bodies (measurements / medications / labs JSON) in
    ///    `Cache.db` — an OS-level surface the store sweep cannot reach, so a
    ///    reset without this leaves PHI on disk (Data-Privacy audit H1).
    /// 3. **Outbox clear.** Queued optimistic writes reference rows that no
    ///    longer exist. Replaying them would silently re-create a slice of the
    ///    record the user just asked to be destroyed — the most user-hostile
    ///    failure mode available here. The cipher key is deliberately NOT wiped:
    ///    rows and key move together (v0.7.1 C-1), and since the session
    ///    survives, a fresh key would only strand rows written afterwards.
    /// 4. **In-memory store sweep**, minus `survivesDataReset`.
    ///
    /// **Two server-side side effects worth knowing about (neither is handled
    /// here, both are benign):**
    ///
    /// - The route deletes every `ApiToken` row for the user — including the
    ///   access token this very request authenticated with. The **refresh**
    ///   token is untouched, so the next call 401s once and `APIClient`'s
    ///   one-shot refresh mints a replacement transparently. The user stays
    ///   signed in; there is nothing to do locally.
    /// - It also deletes `pushSubscription` / `notificationChannel` rows, so the
    ///   device stops receiving push until it re-registers. `RootView`'s
    ///   `refreshPushRegistrationIfReady()` re-registers on the next
    ///   authentication tick, so this self-heals on the following launch rather
    ///   than needing a bespoke call here.
    ///
    /// The UI legitimately paints empty afterwards — that is the truth now.
    func wipeLocalDataAfterServerReset() async {
        // 1. Actor-held caches.
        await swr.invalidateAll()
        await serverStatsRepos.invalidateAll()

        // 2. On-disk URLCache PHI residue.
        await api.purgeCachedResponses()

        // 3. Queued writes that would resurrect deleted rows.
        await outbox.clearAll()

        // 4. In-memory snapshots — registry-driven (AUD-7 H1), minus the
        // account/session/mode stores that must outlive a data reset.
        for clearable in logoutClearables where !survivesDataReset(clearable) {
            clearable.clearOnLogout()
        }
        // The async / bundled outliers the registry deliberately does not cover,
        // kept in lockstep with `performFullLocalLogout`'s explicit list.
        await measurementRemindersStore.clearOnLogout()
        serverStatsStores.clearOnLogout()
    }
}
