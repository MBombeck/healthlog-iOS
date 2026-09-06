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
/// 4. **#5 — Gnadenfenster nach einer Rotation.** Single-Flight fängt nur die
///    401s, die *gleichzeitig* da sind. An der 24-h-Grenze kommt aber ein
///    Nachzügler, der noch mit dem alten Access-Token unterwegs war, erst nach
///    der Rotation an: kein in-flight Task mehr, also rotierte er ein ZWEITES
///    Mal (B → C) und revokte damit das Token, mit dem die eben reparierten
///    Requests gerade unterwegs waren — der tägliche Zwangs-Logout. Innerhalb
///    von ``graceWindow`` Sekunden nach einer erfolgreichen Rotation bekommt
///    ein solcher Nachzügler deshalb ``RefreshOutcome/refreshed``, ohne dass
///    ein zweiter Refresh läuft.
public actor RefreshCoordinator {
    private let refresh: @Sendable () async -> RefreshOutcome
    private let graceWindow: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: Task<RefreshOutcome, Never>?
    private var lastRefreshedAt: Date?

    /// #5 — `graceWindow`/`now` sind Parameter geworden, damit das Fenster
    /// (siehe Punkt 4 oben) an einer injizierten Uhr *geprüft* statt in einem
    /// Test verschlafen wird. Die Defaults sind die Produktionswerte; das
    /// Composition-Root ruft weiterhin nur `RefreshCoordinator(auth:)`.
    public init(
        auth: AuthService,
        graceWindow: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(refresh: { await auth.refresh() }, graceWindow: graceWindow, now: now)
    }

    /// #5 — Test-Naht: derselbe Koordinator über einer Closure statt über dem
    /// echten ``AuthService``, damit `RefreshCoordinatorGraceTests` zählen
    /// kann, wie oft tatsächlich rotiert wurde.
    init(
        refresh: @escaping @Sendable () async -> RefreshOutcome,
        graceWindow: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.refresh = refresh
        self.graceWindow = graceWindow
        self.now = now
    }

    /// Idempotent: parallele Aufrufe sehen denselben in-flight Task. Liefert
    /// das dreiwertige ``RefreshOutcome`` (refreshed / authFailure / transient).
    ///
    /// #5 — Nachlaufende Anrufer innerhalb von ``graceWindow`` Sekunden nach
    /// einer erfolgreichen Rotation bekommen ``RefreshOutcome/refreshed`` ohne
    /// eigene Rotation: der Schlüsselbund hält bereits eine frische Session,
    /// und ein zweiter Umlauf würde genau die Tokens revoken, die die eben
    /// reparierten Requests benutzen. Ein *fehlgeschlagener* Refresh öffnet
    /// kein Fenster — dann gibt es nichts Frisches zu erben.
    public func attemptRefresh() async -> RefreshOutcome {
        if let inFlight {
            return await inFlight.value
        }
        if let lastRefreshedAt, now().timeIntervalSince(lastRefreshedAt) < graceWindow {
            // #5 — a straggler arriving right after a rotation must not rotate again.
            return .refreshed
        }
        let task = Task<RefreshOutcome, Never> { [refresh] in
            await refresh()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if result == .refreshed {
            lastRefreshedAt = now()
        }
        return result
    }
}
