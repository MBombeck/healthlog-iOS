import Foundation

// MARK: - Core infrastructure phase

extension AppContainer {
    /// Bundle of the foundational infrastructure the composition-root builds
    /// FIRST: the pinned `APIClient`, the SwiftData-backed `OutboxQueue`,
    /// `Reachability`, the SWR coordinator + invalidator, and the auth /
    /// refresh seam. Every later repo / store depends on these, so they are
    /// constructed up front and threaded down.
    ///
    /// The `public let` handles stay on `AppContainer` itself (this just feeds
    /// them) so the ~50 external call-sites + the logout reach are byte-for-byte
    /// unchanged — the same lift `RepositoriesBundle` / `ServerStatsRepos` do.
    struct CoreInfraBundle {
        let api: APIClient
        let outbox: OutboxQueue
        let reachability: Reachability
        let swr: SWRCoordinator
        let cacheInvalidator: CacheInvalidator
        let auth: AuthService
        let refreshCoordinator: RefreshCoordinator
        /// audit-v0162 H1 (Opt 3) — shared degraded-server signal, fed by the
        /// same `/api/health` probe that gates reachability; read by the outbox
        /// replay path to avoid burning a PHI write's retry budget on a server
        /// outage.
        let serverHealth: ServerHealthSignal
        /// The owner-bound sign-out wipes of stores built after this phase.
        let ownerPartitionCleanup: OwnerPartitionCleanup
    }

    /// Factory — constructs the foundational infrastructure VERBATIM from the
    /// prior inline `init` block (same args, same order, same detached wiring),
    /// so the move is behaviour-identical. `@MainActor` because the detached
    /// `Task`s it spawns mirror the ones that ran inside `init`.
    ///
    /// `unauthorizedRef` is the composition-root's stored `UnauthorizedHandlerRef`
    /// — passed in so the `APIClient.onUnauthorized` closure binds to the same
    /// instance the 401-bridge later wires (`init` sets it after the stores exist).
    @MainActor
    static func makeCoreInfra(
        environment: AppEnvironment,
        keychain: KeychainStoring,
        passkey: PasskeyServiceProtocol,
        unauthorizedRef: UnauthorizedHandlerRef,
        outboxFactory: OutboxOpenFactory = .live,
        apiSessionConfiguration injectedSessionConfiguration: URLSessionConfiguration? = nil
    ) -> CoreInfraBundle {
        let pinner = CertificatePinner(fromBundle: .main)

        // Ein Release OHNE Pinning ist seit dem Wegfall des eingebauten
        // Default-Servers der Normalfall: ein Selbst-Hoster, der keine Pins
        // hinterlegt hat, validiert per System-Trust und darf dafuer nicht
        // crashen. Kaputt ist nur ein Build, der Pinning DEKLARIERT (Hosts
        // und/oder Hashes im lokalen Overlay) und es dann nicht vollstaendig
        // mitbringt — siehe `CertificatePinner.pinConfigurationIsValid`.
        // Solche Halbheiten sehen wie Pinning aus und sind keines; Crash beim
        // Start ist dafuer deutlich sicherer als stille MITM-Akzeptanz oder
        // ein gebricktes Release nach der naechsten Cert-Rotation.
        #if !DEBUG
            precondition(
                pinner.pinConfigurationIsValid,
                """
                Release-Build mit unvollstaendiger TLS-Pin-Konfiguration gestartet \
                (\(pinner.pinnedHostSuffixes.count) Hosts, \(pinner.pinnedSPKIHashes.count) Pins, \
                well-formed: \(pinner.pinsAreWellFormed)). Wer pinnt, braucht beides: mindestens einen \
                Host in HLPinnedHosts UND mindestens \(CertificatePinner.minimumProductionPinCount) Pins \
                (Primaer + Backup) als 32-Byte-SHA-256-base64 in HLPinnedSPKIHashes — \
                siehe scripts/extract-spki.sh + Config/local.example.yml.
                """
            )
        #endif

        let ref = unauthorizedRef
        // In `-uitest-hermetic` runs, inject the
        // fixture-serving `HermeticURLProtocol` into the API session config so
        // EVERY request (incl. the pinned auth/stream sibling sessions, which
        // inherit `protocolClasses`) resolves from bundled JSON with NO network.
        // Debug-only by `#if DEBUG`; the default session config is untouched in
        // Release.
        let apiSessionConfiguration = injectedSessionConfiguration ?? URLSessionConfiguration.default
        #if DEBUG
            if HermeticUITestSupport.isActive {
                apiSessionConfiguration.protocolClasses =
                    [HermeticURLProtocol.self] + (apiSessionConfiguration.protocolClasses ?? [])
            }
        #endif
        let apiClient = APIClient(
            environment: environment,
            keychain: keychain,
            pinner: pinner,
            sessionConfiguration: apiSessionConfiguration,
            onUnauthorized: { await ref.invoke() }
        )
        // SwiftData-backed Outbox. Der G-9-Ladder versucht zuerst den
        // persistenten Store, schiebt einen korrupten beiseite (nie `rm`), und
        // fällt im Worst-Case auf einen In-Memory-Store mit Log-Warnung zurück —
        // so crash't AppContainer.init nie an einem unleserlichen Outbox-Store.
        // **Hier wird nichts mehr geöffnet.** Die
        // Konstruktion ist weiterhin synchron (`BGTaskScheduler.register` muss
        // im selben applicationDidFinishLaunching-Tick laufen), aber der
        // SQLite-Open hängt jetzt an einem Single-Flight-Handle: die erste
        // echte Operation löst ihn aus, oder der Foreground-Bootstrap nach dem
        // ersten Frame. Das `outbox.open`-Intervall bleibt genau hier, weil
        // `Repositories/` plattform-frei nach `HealthLogCore` kompiliert und
        // `HLPerfSignpost` dort bewusst nicht existiert.
        // This is the app-process outbox the HealthKit
        // observer wake writes through (`HealthSampleConsumption.persistRetry`),
        // and the store lives in the shared app-group container. Build 271 was
        // killed by RunningBoard (`0xdead10cc`) for holding that SQLite lock
        // across a suspension, so every persist here takes a UIApplication
        // background-task assertion first.
        let outbox = OutboxQueue.deferred(
            { HLPerfSignpost.measure(.outboxOpen, outboxFactory.open) },
            backgroundLease: UIKitBackgroundExecutionLease()
        )
        let reachability = Reachability()
        // SWR cache: defer the SwiftData container open to a detached
        // task so the launch tick doesn't pay for it. The Outbox open
        // stays synchronous because BGTaskScheduler.register must run
        // inside `applicationDidFinishLaunchingWithOptions` — the cache
        // has no such coupling (PA5 Bottleneck #1).
        // Savings: 60-180 ms cold, 10-30 ms warm.
        let cacheTask = SWRCache.makeWithRecoveryTask()
        let coordinator = SWRCoordinator(cacheTask: cacheTask, reachability: reachability)
        let cacheInvalidator = CacheInvalidator(coordinator: coordinator)

        // QoL-3-H-3 — gate the captive-portal probe through the same pinned
        // APIClient session. `Reachability` falls back to the raw interface
        // signal until this lands, so wiring it after the client exists (not
        // at the `Reachability()` init above) keeps launch unblocked.
        let probeClient = apiClient
        let probeReach = reachability
        // audit-v0162 H1 (Opt 3) — the reachability probe now ALSO records the
        // degraded signal (confirmed-reachable-but-unhealthy) into a shared
        // `ServerHealthSignal`, so the outbox replay path can read it without
        // issuing its own probe. `probeReachable` stays the gate; the recorded
        // outcome carries the extra `degraded` bit.
        let serverHealth = ServerHealthSignal()
        let healthSink = serverHealth
        Task.detached {
            await probeReach.setProbe {
                let outcome = await probeClient.probeHealth()
                await healthSink.record(outcome)
                return outcome.reachable
            }
        }

        let authService = AuthService(api: apiClient, keychain: keychain, passkey: passkey)
        let ownerPartitionCleanup = OwnerPartitionCleanup()
        // HK-Anchor-Wipe nach Logout, partitioniert per User-ID. Lebt hier im
        // Composition-Root, weil HealthLogCore die HK-Symbole nicht kennen darf
        // (`Services/HealthKitService.swift` ist im SPM-Build excluded).
        Task.detached { [ownerPartitionCleanup] in
            await authService.setOnLogoutCleanup { previousUserID in
                #if canImport(HealthKit)
                    HealthKitService.clearAnchors(for: previousUserID)
                #endif
                // Backfill-Window ist auch user-bound — Re-Login mit anderem
                // Account soll nicht die Wahl des vorigen Users erben.
                HealthKitBackfillWindowStore.clear(for: previousUserID)
                // Clear the per-User HR-bucket
                // cutover boundary so a re-login re-arms it fresh (and the
                // per-sample HR gate doesn't inherit the previous user's day).
                // The operator's raw/bucket schedule goes with it: it is a
                // statement about one account's server rows, not about this
                // device, so the next account starts from the shipping default.
                HRBucketCutoverStore.clear(for: previousUserID)
                HRUploadModeSchedule.clear(for: previousUserID)
                // Same for the workout-HR backfill cursor: the next
                // account walks its own history from scratch.
                WorkoutHRBackfillStore.clear(for: previousUserID)
                await ownerPartitionCleanup.run(previousUserID: previousUserID)
            }
        }
        // RefreshCoordinator + APIClient.refresh-Handler werden im Composition-Root
        // verzählt: APIClient existiert früher, der Coordinator wraps `auth`. Wir
        // setzen den Handler unten via `setRefreshHandler` auf dem APIClient.
        let refreshCoordinator = RefreshCoordinator(auth: authService)
        let refreshActor = refreshCoordinator
        Task.detached { [apiClient] in
            await apiClient.setRefreshHandler { await refreshActor.attemptRefresh() }
        }

        return CoreInfraBundle(
            api: apiClient,
            outbox: outbox,
            reachability: reachability,
            swr: coordinator,
            cacheInvalidator: cacheInvalidator,
            auth: authService,
            refreshCoordinator: refreshCoordinator,
            serverHealth: serverHealth,
            ownerPartitionCleanup: ownerPartitionCleanup
        )
    }
}

/// **The outbox-open seam.**
///
/// `BGTaskScheduler.register` stays synchronous inside
/// `applicationDidFinishLaunchingWithOptions`, and only the persistent
/// SwiftData outbox open is deferred behind a single-flight handle. "Opened
/// exactly once, and not before the first frame" is not something a test can
/// observe while the composition root calls a static factory directly, so the
/// open goes through this seam.
///
/// The seam produces the expensive part: one run of the G-9 recovery ladder.
/// One call to `open()` is one SQLite open, which is what lets a test count
/// opens. The live default is that ladder.
struct OutboxOpenFactory: Sendable {
    private let handler: @Sendable () -> OutboxQueue.StoreHandle

    init(_ handler: @escaping @Sendable () -> OutboxQueue.StoreHandle) {
        self.handler = handler
    }

    func open() -> OutboxQueue.StoreHandle {
        handler()
    }

    static let live = OutboxOpenFactory { OutboxQueue.recoverOrDegradeStore() }
}
