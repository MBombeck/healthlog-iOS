import Foundation
import Observation

/// Single read-only **capability surface** that views and stores consult instead
/// of hard-reading `AuthStore.phase` and `Reachability` scattered across the
/// codebase.
///
/// It models whether the HealthLog
/// backend is *reachable and usable* by folding two signals into one observable:
///
/// 1. **Auth** — derived from ``AuthStore/Phase``. The install loses the
///    backend the instant the session is invalidated (401-cascade →
///    `.unauthenticated`).
/// 2. **Reachability** — the cheap interface signal from ``Reachability``. An
///    authenticated user behind a dead network can still *use* cached data, so
///    reachability gates ``isReachable`` only.
///
/// `@MainActor @Observable` — read on the main actor by SwiftUI views. The
/// online flag is fed from the actor-isolated ``Reachability`` stream via
/// ``start(reachability:)`` (a `@MainActor`-hopping consumer task), so there is
/// no shared mutable state crossing actor boundaries — the only writer of
/// ``isOnline`` is the `@MainActor` consumer loop.
@MainActor
@Observable
public final class BackendAvailability {
    private weak var authStore: AuthStore?

    /// Interface-level connectivity, fed from ``Reachability/isOnlineStream``.
    /// Defaults `true` so the app never *starts* in a "looks offline" state
    /// before the first path update lands (matching `ReachabilityBanner`).
    public private(set) var isOnline: Bool = true

    /// **Ist überhaupt eine Serveradresse hinterlegt?**
    ///
    /// Beobachtbare Spiegelung von ``AppEnvironment/isServerConfigured``. Die
    /// zwei Signale oben beantworten „darf/kann diese Installation mit einem
    /// Server reden"; dieses hier beantwortet die Frage davor: *kennt sie
    /// überhaupt eine Adresse*. Ohne sie wirft jeder Request
    /// ``HLError/serverNotConfigured``, bevor ein Transport anläuft — kein
    /// Netzwerkfehler, sondern ein Einrichtungszustand, den die Oberfläche
    /// als solchen behandeln muss (statt ein Anmeldeformular anzubieten, von
    /// dem sie weiß, dass es scheitern wird).
    ///
    /// Wird beim Aufbau des Containers gesetzt und von
    /// ``AppContainer/reloadEnvironment()`` nachgezogen — den beiden einzigen
    /// Stellen, an denen sich die aufgelöste Adresse ändern kann.
    public private(set) var hasServerAddress: Bool

    private var streamTask: Task<Void, Never>?

    public init(authStore: AuthStore?, hasServerAddress: Bool = true) {
        self.authStore = authStore
        self.hasServerAddress = hasServerAddress
    }

    /// Composition-Root-Setter für ``hasServerAddress``. Idempotent.
    public func setHasServerAddress(_ configured: Bool) {
        hasServerAddress = configured
    }

    /// Wire the reachability stream. Called by the composition root after the
    /// `Reachability` actor exists. Idempotent — a second call cancels the
    /// prior consumer first so we never fan out duplicate loops.
    public func start(reachability: some ReachabilityProviding) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await online in await reachability.isOnlineStream {
                guard let self else { return }
                if Task.isCancelled { return }
                isOnline = online
            }
        }
    }

    // MARK: - Derived state

    /// True iff the install currently holds a usable session. An install whose
    /// token was invalidated (401-cascade → `.unauthenticated`) reports
    /// `false` — the server exists, we just can't talk to it until re-auth.
    public var isAuthenticated: Bool {
        switch authStore?.phase {
        case .authenticated, .authenticating: true
        case .unauthenticated, .unknown, nil: false
        }
    }

    /// True iff the backend is authenticated **and** the interface is
    /// up — i.e. a fresh request would plausibly reach the server right now.
    /// Use this to decide whether to *fire* a server call.
    public var isReachable: Bool {
        isAuthenticated && isOnline
    }
}
