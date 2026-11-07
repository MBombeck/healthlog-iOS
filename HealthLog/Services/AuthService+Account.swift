import Foundation

// MARK: - Account deletion and the account probe

/// KONTO (1.5.0): moved out of `AuthService.swift`, which stood at the
/// `file_length` error limit, so the deletion receipt (`scheduledPurgeAt`,
/// server 1.46.0) has room. Behaviour is unchanged apart from the receipt.
public extension AuthService {
    /// GDPR-style hard-delete: ruft `DELETE /api/settings/account` mit dem vom
    /// Server geforderten Confirm-Body (`{ confirm: "DELETE_ACCOUNT" }`) auf.
    /// Bei 2xx → kompletter Keychain-Wipe (Bearer + Refresh + Expiries +
    /// UserID + DeviceID), so dass kein Token-Reststand einen Re-Login mit
    /// derselben Device-Identität beeinflusst. Wirft bei jedem Server-Fehler
    /// (4xx/5xx) und lässt die Keychain dabei unangetastet — der Aufrufer
    /// (AuthStore) kann den Fehler dann an die UI durchreichen, ohne dass
    /// der User ungewollt ausgeloggt wird.
    ///
    /// `maxRetries: 0` — Account-Deletion ist NICHT idempotent aus Server-Sicht
    /// (zweite Anfrage 401't, weil der User gerade weg ist). Wir wollen genau
    /// einen Versuch.
    ///
    /// KONTO (server 1.46.0): returns the receipt with `scheduledPurgeAt`, the
    /// day a server with a grace window erases the now locked account. The body
    /// is read raw and tolerantly (``AccountDeletionReceipt/parse(_:)``): the
    /// deletion already happened when the server answered 2xx, so neither an
    /// empty 204 nor a pre-1.46 body may turn it into an error.
    @discardableResult
    func deleteAccount() async throws -> AccountDeletionReceipt {
        struct ConfirmBody: Encodable {
            let confirm: String
        }
        // Server (`/src/app/api/settings/account/route.ts`) erwartet einen
        // Confirm-Body auch beim DELETE-Verb — der Wrapper `.delete(_:)` trägt
        // keinen Body, also bauen wir den `APIRequest` von Hand.
        let body = try JSONEncoder.hlDefault.encode(ConfirmBody(confirm: "DELETE_ACCOUNT"))
        let deleteReq = APIRequest<Data>(
            method: .delete,
            path: "/api/settings/account",
            body: body,
            maxRetries: 0
        )
        let previousUserID = keychain.getString(forKey: KeychainKey.userID)
        let (responseBody, _) = try await api.download(deleteReq)
        invalidateAndWipeDeletedAccountCredentials()
        if let cleanup = onLogoutCleanup {
            await cleanup(previousUserID)
        }
        return AccountDeletionReceipt.parse(responseBody)
    }

    /// KONTO (server 1.46.0) — the deletion grace window in days, from
    /// `GET /api/settings/privacy-summary` (`retention.accountDeletionGraceDays`,
    /// read from the same resolver the purge job uses). `nil` when the server
    /// does not say (older server, failed read): the copy then stays general.
    func accountDeletionGraceDays() async -> Int? {
        struct Summary: Decodable, Sendable {
            struct Retention: Decodable, Sendable {
                let accountDeletionGraceDays: Int?
            }

            let retention: Retention?
        }
        let req = APIRequest<Summary>(method: .get, path: "/api/settings/privacy-summary", maxRetries: 0, failFast: true)
        guard let days = try? await api.send(req).retention?.accountDeletionGraceDays, days >= 0 else { return nil }
        return days
    }

    /// Best-effort but fail-closed local Keychain teardown after the server has
    /// irreversibly accepted account deletion. Every targeted key is attempted
    /// even if one removal fails. If any targeted delete fails, a service-wide
    /// wipe is the recovery path: retaining a bearer, consent grant, or provider
    /// secret is worse than making the user re-enter the non-secret server URL.
    ///
    /// This helper deliberately does not throw. Once the server returned 2xx,
    /// `AuthStore` must still run the app-level cache/outbox cleanup and move to
    /// `.unauthenticated`; reporting a retry would be false because the account
    /// no longer exists.
    /// Shared synchronous account-boundary wipe used after both the native
    /// delete endpoint and a confirmed web/MFA deletion. Keeping the primitive
    /// synchronous lets `AuthStore` revalidate the probed session and perform
    /// the destructive keychain step without an actor hop that could admit a
    /// replacement account in between.
    internal nonisolated static func wipeDeletedAccountKeychain(using keychain: KeychainStoring) {
        // Normal path: enumerate the account-bound keys explicitly so the
        // configured server URL survives and onboarding can return to the same
        // host. `removeAll()` is reserved for a targeted-removal failure.
        var keys = [
            KeychainKey.authToken,
            KeychainKey.refreshToken,
            KeychainKey.refreshTokenExpiresAt,
            KeychainKey.accessTokenExpiresAt,
            KeychainKey.userID,
            KeychainKey.userDisplayName,
            KeychainKey.deviceID,
            AIConsentStore.serverManagedScope,
            AIConsentStore.serverManagedDeclinedKey
        ]
        // Device-ID rotieren: ein neuer Login danach soll als "neues Gerät"
        // beim Server gelten, sonst könnte der Server-Side-Cleanup auf
        // alte Device-Rows referenzieren (auch wenn Cascade-Delete sie schon
        // abräumt — saubere Trennung zwischen den beiden Sessions).
        // v0.12 W1 (security finding W1-1, Apple 5.1.2(i)) — mirror the
        // AI-consent grant wipe here so the account-deletion direct keychain
        // teardown is self-sufficient even if the `performFullLocalLogout`
        // cascade is ever decoupled from this path. The per-provider
        // `ai-consent.<provider>` grant + the paired `ai-consent-declined.
        // <provider>` marker are the informed-consent record gating
        // off-device LLM transmission; they must not survive the account
        // they were granted under (shared-device inheritance leak).
        // Idempotent — over-removing absent keys is a no-op.
        for provider in AIProvider.allCases where provider != .unconfigured {
            keys.append(AIConsentStore.keyPrefix + provider.rawValue)
            keys.append(AIConsentStore.declinedKeyPrefix + provider.rawValue)
        }
        // v0.13 — mirror the BYO-key consent-grant wipe (`byo-consent.<provider>`)
        // so account deletion is self-sufficient. The client-side BYO path
        // transmits health data off-device, so its consent record must not
        // survive the deleted account.
        keys.append(KeychainKey.lastSessionUserID) // Build 273 (A2) — goes with the outbox
        for provider in BYOProviderID.allCases {
            keys.append(AIConsentStore.byoKeyPrefix + provider.rawValue)
            keys.append(BYOKeyStore.keyPrefix + provider.rawValue)
            keys.append(BYOKeyStore.modelPrefix + provider.rawValue)
            keys.append(BYOKeyStore.baseURLPrefix + provider.rawValue)
        }
        // v0.13 W2 — and wipe the BYO API **key bytes** themselves
        // (`byo.llm.key.<provider>` + model/baseURL overrides) so the secret
        // never survives the deleted account.
        var targetedRemovalFailed = false
        for key in keys {
            do {
                try keychain.remove(forKey: key)
            } catch {
                targetedRemovalFailed = true
            }
        }

        guard targetedRemovalFailed else { return }
        HLLog.security.error(
            "Account-deletion targeted Keychain wipe failed; attempting service-wide fail-closed wipe."
        )
        do {
            try keychain.removeAll()
        } catch {
            HLLog.security.error(
                "Account-deletion service-wide Keychain wipe failed; local credentials may remain on device: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }

    /// #37/#38 Privacy H3 (audit-v0162) — the tri-state outcome of probing
    /// whether the currently-persisted session's account still exists on the
    /// server. Used after an MFA-enrolled user was routed to *web* account
    /// deletion (the native Bearer session cannot satisfy the cookie-only fresh-
    /// MFA step-up): once the deletion completes on the web, the local device
    /// still holds full PHI until an incidental call happens to 401. The probe
    /// makes that detection deterministic on the next foreground.
    enum AccountProbeOutcome: Sendable, Equatable {
        /// `GET /api/auth/me` answered 2xx — the account is still live (the user
        /// has not completed the web deletion, or cancelled). Do NOT wipe.
        case exists
        /// The account is gone: a 401/404 (or a locally-absent token) — the
        /// server no longer recognises this session. Run the full local wipe.
        case gone
        /// Network/offline/5xx — cannot tell. Leave the pending flag armed and
        /// re-probe on the next foreground.
        case inconclusive
    }

    /// #37/#38 Privacy H3 (audit-v0162) — probe `GET /api/auth/me` to decide
    /// whether the account behind the persisted token still exists.
    ///
    /// Routed through the fail-fast auth session (`failFast: true`,
    /// `maxRetries: 0`) so a no-connectivity probe returns `.inconclusive`
    /// immediately instead of parking on the patient outbox timeout. A 401/404 —
    /// or a session that self-heals via the refresh→logout bridge and ends up
    /// token-less — resolves to `.gone`; a merely-expired access token that the
    /// refresh path renews resolves to `.exists` (no false positive). Any other
    /// failure is `.inconclusive`.
    func probeAccountStatus() async -> AccountProbeOutcome {
        // No local token to authenticate with ⇒ the session is already gone
        // (e.g. an incidental 401 already fired the token-expiry bridge). Treat
        // as gone so the caller still runs the full account-deletion wipe.
        guard isAuthenticated else { return .gone }
        let req = APIRequest<EmptyPayload>(
            method: .get,
            path: "/api/auth/me",
            maxRetries: 0,
            failFast: true
        )
        do {
            try await api.sendVoid(req)
            return .exists
        } catch let error as HLError {
            switch error {
            case let .server(status, _, _) where status == 401 || status == 404:
                return .gone
            case .unauthorized:
                return .gone
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }
}
