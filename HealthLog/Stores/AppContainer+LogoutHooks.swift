import Foundation

// MARK: - Logout / unauthorized hook wiring

extension AppContainer {
    /// Typed session-boundary surface consumed by Plan 06-05 when it becomes
    /// the sole owner of terminal teardown ordering. Creating the hooks here
    /// does not activate or invalidate a session and therefore preserves all
    /// current runtime paths.
    var authenticatedSessionBoundaryHooks: AuthenticatedSessionBoundaryHooks {
        let registry = authenticatedSessionRegistry
        return AuthenticatedSessionBoundaryHooks(
            invalidate: {
                registry.invalidate()
            },
            // 06-05 — quiescence is real now: awaits every registered
            // owned-task cancel-and-drain seam of the composition.
            awaitQuiescence: { [weak self] in
                await self?.drainAuthenticatedSessionWork()
            },
            activate: { ownerID in
                registry.activate(ownerID: ownerID)
            }
        )
    }

    /// Wires sharing recovery plus the four sign-out seams onto the already-built `authStore` +
    /// `unauthorizedRef`: the 401→`handleUnauthorized` bridge, the
    /// account-deletion cleanup hook, the user-initiated post-logout hook, and
    /// the adopt-on-pair upload hook. All four route through the shared
    /// `performFullLocalLogout(reason:)` cascade so every logout path wipes the
    /// SAME surface.
    ///
    /// An instance method (not a static factory) because three of the four
    /// hooks weakly capture `self` to reach the cascade — `init` calls this at
    /// the end, after every stored property is assigned, so the `self`-capture
    /// is fully valid. Body moved VERBATIM from the prior inline `init` block.
    func wireLogoutHooks(apiClient: APIClient) {
        // Sharing grant/session recovery is deliberately narrower than logout:
        // keep credentials, auth phase, local preferences, and the owner-bound
        // outbox, but empty every store/cache that can have painted through an
        // X-HealthLog-Account selector. Install cleanup first so the API handler
        // can never publish the reconciled actor over stale selected-record data.
        authStore.sharingScopeCleanupHook = { [weak self] in
            await self?.performSharingScopeCleanup()
        }
        let sharingStore = authStore
        apiClient.setSharingRecoveryHandler { [weak sharingStore] event in
            await sharingStore?.handleSharingRecovery(event)
        }

        // 401 → AuthStore.handleUnauthorized() bridge.
        //
        // v0.7.0 W-LOGOUT (NEW-H-1): the cascade body now lives in
        // `AppContainer.performFullLocalLogout(reason: .tokenExpired)` so
        // all four logout paths (user-tap / 401 / account-delete / switch-
        // server) wipe the SAME surface. The bridge only retains the
        // `AuthStore.handleUnauthorized()` call because it has to transition
        // the auth phase + wipe the auth-bundle keychain entries, which
        // live in HealthLogCore and don't have AppContainer visibility.
        let storeForBridge = authStore
        unauthorizedRef.set { [weak self, weak storeForBridge] in
            // 06-05 — eligibility probe FIRST, without publishing anything.
            // Only an active session (`.authenticated` / `.authenticating`)
            // with no deletion reconciliation owning the account boundary is
            // torn down. A web-deletion reconciliation's stronger
            // `.accountDeleted` cascade owns cleanup; starting `.tokenExpired`
            // here would expose the login UI and let a replacement session
            // race the still-running deletion wipe. Deliberately NO account-
            // boundary acquisition here: the bridge can fire re-entrantly
            // from network calls made WHILE `login()`/`logout()` hold the
            // boundary, and queueing would deadlock the very call that
            // surfaced the 401.
            guard await storeForBridge?.shouldBeginUnauthorizedTeardown() ?? false else { return }
            // Shared cascade FIRST (invalidate lease → cancel/drain owned
            // tasks → reason-specific clears). Captures `self` weakly — if the
            // container is torn down between the 401 and the cleanup hop, the
            // wipe simply no-ops.
            await self?.performFullLocalLogout(reason: .tokenExpired)
            // Phase + atomic auth-bundle keychain wipe + AWAITED HK-anchor
            // cleanup, then the terminal publication — deliberately LAST, so
            // no login surface exists (and no replacement admission can
            // begin) until every cleanup stage above has completed. This
            // stays outside `performFullLocalLogout` because phase
            // transitions are AuthStore's concern.
            let shouldRunGenericCleanup = await storeForBridge?.handleUnauthorized() ?? true
            guard shouldRunGenericCleanup else { return }
        }

        // Account-Deletion-Cleanup-Hook: wird vom `AuthStore.deleteAccount`
        // NACH dem erfolgreichen Server-DELETE + Keychain-Wipe aufgerufen,
        // aber VOR dem Phase-Wechsel auf `.unauthenticated`.
        //
        // v0.7.0 W-LOGOUT (NEW-H-1): consolidated to
        // `performFullLocalLogout(reason: .accountDeleted)`. The helper
        // adds the outbox + GLP-1 wipe (the only delete-specific extras)
        // on top of the shared cleanup. Pre-v0.7.0 this hook was missing
        // the on-device AI caches, avatar PNG cache, HK diagnostics
        // counters, and the server-stats repo invalidation that the
        // switch-server path already had.
        authStore.localCleanupHook = { [weak self] in
            await self?.performFullLocalLogout(reason: .accountDeleted)
        }

        // v0.7.0 W-LOGOUT (NEW-H-1): user-initiated sign-out also routes
        // through the shared cascade. Pre-v0.7.0 this path only ran the
        // `AuthService.onLogoutCleanup` HK-anchor wipe — the on-device AI
        // caches, avatar PNG, Coach SwiftData transcript, and outbox
        // cipher key all survived a user-tap logout.
        authStore.onPostLogoutHook = { [weak self] in
            await self?.performFullLocalLogout(reason: .userInitiated)
        }
        // v0.11 W4 — adopt-on-pair upload (wiring in `AppContainer+AdoptUpload`).
        authStore.adoptUploadHook = Self.makeAdoptUploadHook(
            api: apiClient,
            localRepo: localRepo,
            medicationsStore: medicationsStore
        )
    }

    /// Clears only data surfaces admitted by APIClient's selected-record route
    /// policy. Session credentials, sync mode, device preferences, integrations,
    /// HealthKit cursors, local repositories, and outbox rows remain untouched.
    private func performSharingScopeCleanup() async {
        await swr.invalidateAll()
        await serverStatsRepos.invalidateAll()

        let selectedRecordStores: [any LogoutClearable] = [
            dashboardStore,
            measurementsStore,
            medicationsStore,
            deliveryPreferencesStore,
            moodStore,
            moodTagCatalogStore,
            moodTagManagementStore,
            cycleStore,
            insightsStore,
            dailyBriefingStore,
            healthScoreStore,
            chartsStore,
            trendsOverlayStore,
            doctorReportStore,
            localDoctorReportStore,
            labsStore,
            customMetricsStore,
            illnessStore,
            documentsStore,
            allergiesStore,
            familyHistoryStore,
            mentalHealthStore
        ]
        for store in selectedRecordStores {
            store.clearOnLogout()
        }
        serverStatsStores.clearOnLogout()
        OnDeviceBriefingCache.shared.clearOnLogout()
        TrendObservationCache.shared.clearOnLogout()
    }
}
