import Foundation

/// Single-flight Refresh-Token Koordinator. Rolle:
///
/// 1. APIClient ruft `attemptRefresh()` bei jedem 401 auf — wir rufen
///    `AuthService.refresh()` und geben das ``RefreshOutcome`` zurück. Bei
///    ``RefreshOutcome/refreshed`` wiederholt APIClient den Original-Request
///    einmal (siehe `17-error-handling.md §9` Algorithmus).
/// 2. Parallele 401-Antworten warten alle auf den **selben** in-flight
///    Refresh-Task — sonst würde der zweite Caller den jetzt-rotierten
///    Refresh-Token erneut benutzen, was server-seitig
///    `Refresh token reuse detected` triggert + alle Tokens des Users
///    revokt (`05-auth-flows.md §3.1`). Das Single-Flight ist die erste
///    Schutzschicht gegen den 401-Refresh-Storm.
/// 3. Bei ``RefreshOutcome/authFailure`` bleibt das Auth-Wipe + Logout dem
///    Aufrufer überlassen (APIClient ruft dann `onUnauthorized`); bei
///    ``RefreshOutcome/transient`` darf der Aufrufer **nicht** ausloggen —
///    die Session überlebt (die zweite Schutzschicht: kein Spurious-Logout
///    durch transiente Refresh-Fehler).
public actor RefreshCoordinator {
    private let auth: AuthService
    private var inFlight: Task<RefreshOutcome, Never>?

    public init(auth: AuthService) {
        self.auth = auth
    }

    /// Idempotent: parallele Aufrufe sehen denselben in-flight Task. Liefert
    /// das dreiwertige ``RefreshOutcome`` (refreshed / authFailure / transient).
    public func attemptRefresh() async -> RefreshOutcome {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task<RefreshOutcome, Never> { [auth] in
            await auth.refresh()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}
