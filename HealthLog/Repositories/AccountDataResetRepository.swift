import Foundation

/// `DELETE /api/settings/data` request body. The server compares `confirm`
/// against the literal ASCII string `"DELETE"` and answers 422 for anything else
/// (`src/app/api/settings/data/route.ts` — `if (confirm !== "DELETE")`).
///
/// **The wire value is NOT the localized type-confirm phrase.** The iOS UI asks
/// the user to type the localized word (`LÖSCHEN` in German), matching the
/// `DeleteAccountScreen` idiom; that localized string is a *UI gate only* and is
/// never sent. Conflating the two would make the German build unable to reset
/// data at all, which is exactly the class of bug this comment exists to
/// prevent.
public struct AccountDataResetBody: Encodable, Sendable, Equatable {
    public let confirm: String

    /// The one value the server accepts. Deliberately a constant rather than a
    /// caller-supplied string.
    public static let serverConfirmToken = "DELETE"

    public init(confirm: String = AccountDataResetBody.serverConfirmToken) {
        self.confirm = confirm
    }
}

/// Wraps `DELETE /api/settings/data` — "wipe my health data but keep my login"
/// (parity item 2.5, web ref `advanced-section.tsx:277-325`).
///
/// Distinct from account deletion: the user row, credentials, passkeys and
/// sessions survive; measurements, medications, intake events, mood entries and
/// API tokens are dropped. Before this existed, iOS offered only the all-or-
/// nothing account delete.
///
/// **Step-up caveat.** The route is wrapped in `requireFreshMfaIfEnrolled`, the
/// same gate as account deletion. Fresh-MFA step-up is cookie-only by
/// construction, so an MFA-enrolled account cannot satisfy it over a native
/// Bearer session and the server answers `401 auth.stepup.required`. The screen
/// handles that by routing to the web surface, exactly as `DeleteAccountScreen`
/// does — which is why `/api/settings/data` had to be added to
/// `APIClient.preserves401Body`, or the typed error code would have been
/// swallowed by the 401 refresh-and-logout cascade before the UI could read it.
public actor AccountDataResetRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Deletes all user-owned health data, keeping the account.
    ///
    /// Uses the bodied-DELETE factory (the server reads `confirm` from the
    /// request body, not a query parameter). No outbox `Kind` is wired and no
    /// retry is desirable: this is a destructive, non-idempotent-feeling action
    /// the user must consciously re-trigger if it fails.
    public func resetAllData() async throws {
        let req: APIRequest<EmptyPayload> = try .delete(
            "/api/settings/data",
            body: AccountDataResetBody()
        )
        try await api.sendVoid(req)
    }
}
