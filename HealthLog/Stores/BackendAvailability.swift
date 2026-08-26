import Foundation
import Observation

/// Single read-only **capability surface** that views and stores consult instead
/// of hard-reading `SyncModeStore.isStandalone` (and `AuthStore.phase`,
/// `Reachability`) scattered across the codebase.
///
/// **R4 §3.1 (offline-architecture research) — groundwork primitive.** It models
/// whether the HealthLog backend is *reachable and usable* by folding three
/// existing signals into one observable:
///
/// 1. **Mode** — derived from ``SyncModeStore``. A `.standalone` install has no
///    server by definition; a `.paired` install expects one.
/// 2. **Auth** — derived from ``AuthStore/Phase``. Even a paired install loses
///    the backend the instant the session is invalidated (401-cascade →
///    `.unauthenticated`).
/// 3. **Reachability** — the cheap interface signal from ``Reachability``. A
///    paired + authenticated user behind a dead network can still *use* cached
///    data, so reachability gates ``isReachable`` but **not** ``hasServer`` /
///    the capability flags (those describe whether the surface exists at all,
///    not whether it can refresh this instant).
///
/// **Paired-path invariant (the whole point of this groundwork):** on a normal
/// paired + authenticated install every capability flag returns `true`, exactly
/// as the scattered `!isStandalone` checks do today. Nothing user-visible
/// changes. The value of the abstraction is the *seam*: when v0.11 flips
/// standalone on, surfaces flip to their placeholder by populating capabilities
/// here, not by touching every view twice.
///
/// `@MainActor @Observable` — read on the main actor by SwiftUI views. The
/// online flag is fed from the actor-isolated ``Reachability`` stream via
/// ``start(reachability:)`` (a `@MainActor`-hopping consumer task), so there is
/// no shared mutable state crossing actor boundaries — the only writer of
/// ``isOnline`` is the `@MainActor` consumer loop.
@MainActor
@Observable
public final class BackendAvailability {
    /// Coarse runtime classification a screen can branch on.
    public enum Mode: Sendable, Equatable {
        /// The install is paired with a server (token expected). Server-derived
        /// surfaces are live (subject to ``isReachable`` for *fresh* data).
        case paired
        /// The install runs fully local — no server account, no token. Every
        /// server-derived surface renders its ``HLCloudDerivedPlaceholder``.
        case standalone
    }

    private weak var syncMode: SyncModeStore?
    private weak var authStore: AuthStore?

    /// Interface-level connectivity, fed from ``Reachability/isOnlineStream``.
    /// Defaults `true` so the app never *starts* in a "looks offline" state
    /// before the first path update lands (matching `ReachabilityBanner`).
    public private(set) var isOnline: Bool = true

    /// **R1 — ist überhaupt eine Serveradresse hinterlegt?**
    ///
    /// Beobachtbare Spiegelung von ``AppEnvironment/isServerConfigured``. Die
    /// drei Signale oben beantworten „darf/kann diese Installation mit einem
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

    public init(syncMode: SyncModeStore?, authStore: AuthStore?, hasServerAddress: Bool = true) {
        self.syncMode = syncMode
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

    /// `.standalone` iff the runtime ``SyncMode`` is standalone; `.paired`
    /// otherwise (including before onboarding resolves a mode — a fresh paired
    /// install is the default expectation).
    public var mode: Mode {
        syncMode?.isStandalone == true ? .standalone : .paired
    }

    /// True iff this install is paired with a server. The single signal that
    /// gates whether a server-derived surface *exists* (vs renders the
    /// placeholder). In paired mode this is always `true`.
    public var hasServer: Bool {
        mode == .paired
    }

    /// True iff a paired install currently holds a usable session. A paired
    /// install whose token was invalidated (401-cascade → `.unauthenticated`)
    /// reports `false` even though `hasServer` stays `true` — the server exists,
    /// we just can't talk to it until re-auth.
    public var isAuthenticated: Bool {
        switch authStore?.phase {
        case .authenticated, .authenticating: true
        case .standalone, .unauthenticated, .unknown, nil: false
        }
    }

    /// True iff the backend is paired, authenticated, **and** the interface is
    /// up — i.e. a fresh request would plausibly reach the server right now.
    /// Use this to decide whether to *fire* a server call; use ``hasServer`` to
    /// decide whether a *surface* should exist at all.
    public var isReachable: Bool {
        hasServer && isAuthenticated && isOnline
    }

    // MARK: - Capability flags (read intent, not raw mode)

    // v0.12 W7-5 — `canShowCloudBriefing` / `canShowCloudCoach` were removed:
    // they were declared on this surface but had ZERO production call sites. The
    // Daily Briefing already gates via the on-device-vs-server resolver in
    // `DailyBriefingHero+OnDevice.swift` (`hasServer = serverFallback != nil`)
    // and the Coach via its own `standalonePlaceholder` routing in
    // `AskCoachSheet+ServerFallback.swift`. Two dead flags invited a future
    // maintainer to wire a third, divergent gate — deleting them keeps the
    // capability surface honest (every flag below has a live consumer).

    /// Server-computed Health Score.
    public var canShowHealthScore: Bool {
        hasServer
    }

    /// Server-computed Insights surfaces (correlations, trends mother-page).
    public var canShowCloudInsights: Bool {
        hasServer
    }

    /// Server-rendered Personal Records.
    public var canShowPersonalRecords: Bool {
        hasServer
    }

    // SET-V2-B — `canShowDoctorReportPDF` was removed: the consolidated
    // the doctor-report path no longer gates a placeholder on it. The surface
    // always renders (prefer-server via ``isReachable``, on-device fallback in
    // standalone/offline — FW5-C pattern), so the flag lost its last consumer
    // and keeping it would invite a divergent gate (same honesty rule as the
    // W7-5 removals above).

    /// Multi-device sync (the `/api/sync/changes` consumer, v0.11).
    public var canSyncMultiDevice: Bool {
        hasServer
    }
}
