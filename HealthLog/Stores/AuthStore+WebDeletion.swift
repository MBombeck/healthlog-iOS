import Foundation

// MARK: - Web-deletion return detection (#37/#38 Privacy H3 — audit-v0162)

public extension AuthStore {
    /// Non-secret marker for the user being routed to web account deletion.
    private static var pendingWebDeletionKey: String {
        "auth.pendingWebDeletion"
    }

    /// Owner binding prevents a later account from inheriting the prior user's
    /// unfinished deletion reconciliation.
    private static var pendingWebDeletionOwnerKey: String {
        "auth.pendingWebDeletion.owner"
    }

    /// Read on foreground by `RootView` to gate reconciliation.
    var hasPendingWebDeletion: Bool {
        defaults.bool(forKey: Self.pendingWebDeletionKey)
    }

    /// Arms the return probe before `DeleteAccountScreen` opens the web page.
    func markPendingWebDeletion() {
        defaults.set(true, forKey: Self.pendingWebDeletionKey)
        if let owner = keychain.getString(forKey: KeychainKey.userID) {
            defaults.set(owner, forKey: Self.pendingWebDeletionOwnerKey)
        } else {
            defaults.removeObject(forKey: Self.pendingWebDeletionOwnerKey)
        }
    }

    /// Clears both the trigger and its account-boundary owner.
    func clearPendingWebDeletion() {
        defaults.removeObject(forKey: Self.pendingWebDeletionKey)
        defaults.removeObject(forKey: Self.pendingWebDeletionOwnerKey)
    }

    /// Clears a stale marker only if it still belongs to the probe that is
    /// being discarded. A replacement account may have armed its own marker
    /// while the prior request was suspended; that newer marker must survive.
    private func clearPendingWebDeletion(ifOwnedBy expectedOwner: String?) {
        guard defaults.string(forKey: Self.pendingWebDeletionOwnerKey) == expectedOwner else { return }
        clearPendingWebDeletion()
    }

    /// Probes `GET /api/auth/me` on foreground after a web handoff. A gone
    /// account runs the same full local cascade as a native 2xx deletion;
    /// exists/inconclusive outcomes remain armed for a later foreground.
    func reconcilePendingWebDeletion() async {
        guard hasPendingWebDeletion else { return }
        guard await beginDeletedAccountTransition() else { return }
        defer { finishDeletedAccountTransition() }

        // A second foreground reconciliation may have queued behind the first.
        // Re-read the trigger only after this task owns the account boundary.
        guard hasPendingWebDeletion else { return }
        let pendingOwner = defaults.string(forKey: Self.pendingWebDeletionOwnerKey)
        let capturedOwner = keychain.getString(forKey: KeychainKey.userID)
        let deletedAccountOwner = pendingOwner ?? capturedOwner
        let capturedGeneration = authSessionGeneration
        if let pendingOwner, let capturedOwner, pendingOwner != capturedOwner {
            clearPendingWebDeletion(ifOwnedBy: pendingOwner)
            return
        }

        let outcome = await auth.probeAccountStatus()

        // The probe suspended outside the MainActor. Re-check both the marker
        // and the authenticated-session boundary immediately before any wipe.
        // The deletion transition suppresses this probe's generic unauthorized
        // bridge, so the captured Keychain owner must remain unchanged. A
        // token-less pre-existing session captures nil on both sides; its marker
        // still carries `deletedAccountOwner` for owner-partition cleanup.
        let currentMarkerOwner = defaults.string(forKey: Self.pendingWebDeletionOwnerKey)
        let currentOwner = keychain.getString(forKey: KeychainKey.userID)
        let sameOwnerBoundary = currentOwner == capturedOwner
        guard hasPendingWebDeletion,
              currentMarkerOwner == pendingOwner,
              authSessionGeneration == capturedGeneration,
              sameOwnerBoundary else
        {
            clearPendingWebDeletion(ifOwnedBy: pendingOwner)
            return
        }

        switch outcome {
        case .gone:
            // 06-05 (step 1) — the deletion is confirmed: stale the shared
            // authenticated-session lease before any destructive teardown so
            // no suspended producer can publish into the deleted session. The
            // local cascade below re-asserts the invalidation and drains every
            // owned task; a `.exists`/`.inconclusive` probe never reaches this
            // branch and leaves the live lease untouched.
            invalidateAuthenticatedSession()
            // Reuse the native deletion's complete synchronous account-boundary
            // wipe, including device identity, every AI consent/decline record,
            // and all BYO credentials. Phase + marker move before the first
            // cleanup await. Authentication admission remains serialized until
            // the owner-anchor and app-local cascades have both quiesced.
            await auth.invalidateAndWipeDeletedAccountCredentials()
            clearPendingWebDeletion(ifOwnedBy: pendingOwner)
            await runDeletedAccountOwnerCleanup(previousOwner: deletedAccountOwner)
            await localCleanupHook?()
            completeDeletedAccountBoundary()
            HLLog.auth.warning("Web-deletion return detected — account gone; local PHI wiped.")
        case .exists, .inconclusive:
            break
        }
    }
}
