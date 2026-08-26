import Foundation

/// AppContainer HealthKit lifecycle hooks (background activation, daily-stats
/// foreground refresh, environment reload, backfill-window persistence).
/// Extracted from `AppContainer.swift` (file_length discipline — pure move,
/// no behaviour change).
@MainActor
public extension AppContainer {
    /// Factory — constructs the HK-batch uploader + BG-sync coordinator VERBATIM
    /// from the prior inline `init` block. The uploader gets its sliding-window
    /// throttle (60/min server cap); the coordinator's `BGTaskScheduler.register`
    /// runs synchronously here because it MUST complete inside
    /// `applicationDidFinishLaunchingWithOptions` (Apple requirement) — and
    /// `AppContainer.init` runs synchronously in the `HealthLogApp.init` path, so
    /// this factory is on that same tick. The HKService uploader / deletion-
    /// reconciler attach is detached (the actor hop needs an async context).
    static func makeHealthKitInfra(
        apiClient: APIClient,
        healthKit: AnyHealthKitWriter?,
        measurementsRepo: MeasurementsRepository,
        keychain: KeychainStoring
    ) -> (uploader: MeasurementBatchUploader, backgroundSync: BackgroundSyncCoordinator) {
        // HK-Batch-Uploader inkl. Sliding-Window-Throttle (60/min Server-Cap).
        let uploader = MeasurementBatchUploader(
            api: apiClient,
            throttle: BatchSyncThrottle(),
            authenticationSnapshot: {
                MeasurementUploadAuthenticationSnapshot(
                    ownerUserID: keychain.getString(forKey: KeychainKey.userID),
                    bearerToken: keychain.getString(forKey: KeychainKey.authToken)
                )
            }
        )
        // HKService bekommt seinen Uploader nach Construction injiziert — siehe
        // Doc-Comment in `HealthKitService.uploader`. Detached, weil der Hop über
        // den Actor in einem async-Context laufen muss; AppContainer.init ist sync.
        if let healthKit {
            Task.detached { [measurementsRepo] in
                await healthKit.attachUploader(uploader)
                await healthKit.attachDeletionReconciler(measurementsRepo)
            }
        }
        // BG-Sync-Coordinator + Handler sofort registrieren — `BGTaskScheduler.register`
        // muss VOR `applicationDidFinishLaunching` returnt aufgerufen werden, sonst
        // weckt das System uns nicht mehr auf.
        let bgSync = BackgroundSyncCoordinator(healthKit: healthKit)
        bgSync.registerBGTaskHandler()
        return (uploader, bgSync)
    }

    /// Aktiviert HK-Background-Deliveries + BG-Sync-Schedule und fährt danach
    /// **einen** benannten Pass. Idempotent. Darf nur NACH erfolgreichem
    /// `requestAuthorization` aufgerufen werden — sonst lehnt HealthKit ab.
    /// Aufrufer:
    /// - Onboarding `HealthKitPermissionStep` direkt nach gewährter Zustimmung
    ///   (`postAuthentication`).
    /// - `RootView` beim Foreground-Bootstrap für User, die schon onboarded sind
    ///   (`coldActivation`).
    ///
    /// **Phase 07 / plan 07-09 — der Trigger kommt vom Aufrufer.** Vorher fuhr
    /// `activateHealthKitBackgroundDeliveries` selbst einen `.foreground`-Pass
    /// plus einen detached Aggregat-Sweep: ein Pass unter falschem Namen und ein
    /// zweites Fan-out daneben. Beide Aufrufer sind etwas anderes als ein
    /// Foreground-Tick, und beide sagen es jetzt.
    ///
    /// Der Pass läuft **detached best-effort**: die Verbindungsfläche (Onboarding
    /// + Settings) darf nicht auf einem All-Time-Backfill hängen — das ist die
    /// v0.14.1-Regel, die der frühere detached Sweep trug. Der garantierte
    /// BGProcessing-Wake ist der Recovery-Pfad, falls iOS diesen Task suspendiert.
    ///
    /// Internal rather than `public`: `HealthSyncTrigger` is module-internal, and
    /// naming the trigger is the whole point of the parameter.
    internal func activateHealthKitBackground(for trigger: HealthSyncTrigger) async {
        await backgroundSync.activateHealthKitBackgroundDeliveries()
        Task.detached(priority: .utility) { [weak self] in
            await self?.runHealthSyncPass(trigger)
        }
    }

    /// Foreground-Refresh fuer den HK-STATS-Pfad. Lightweight gegenueber
    /// `activateHealthKitBackground()` — laeuft nur den Daily-Stats-Sync,
    /// nicht die volle BG-Delivery-Reaktivierung (kein
    /// `enableBackgroundDelivery`, kein `scheduleNextBGSync`). Idempotent:
    /// `HKStatisticsCollectionQuery` ist billig (system-cached Aggregate)
    /// und der Server idempotiert per `externalId="stats:<id>:<YYYY-MM-DD>"`
    /// (POST → `duplicate`-no-op wenn der Wert unveraendert ist).
    ///
    /// Behebt operator-reported Regression (v0.6.1.21): nach einem Walk
    /// zeigt das Schritte-Tile nur die Schritte vom letzten BGTask-Wakeup
    /// (typischerweise Stunden alt), nicht den aktuellen Tagestotal. Der
    /// einzige Pfad der heute auf dem Server landet ist
    /// `triggerDailyStatsSync` — und der lief vorher nur einmal pro
    /// App-Lifecycle (`didActivateHKBackground`-Guard in RootView) plus
    /// den 15-min-gedrosselten BGTask. Mit diesem Hook auf jedem
    /// `scenePhase == .active` sieht die Tile den frischen Tagestotal.
    ///
    /// **lookbackDays: 1** — Default reicht fuer "heute" (HK-Statistics-
    /// Anchor wird vom Coordinator auf User-TZ-Tagesanfang gerundet, der
    /// 1-Tag-Lookback deckt also den ganzen heutigen Tag ab). Der grosse
    /// Backfill von 7 Tagen passiert weiterhin nur beim BG-Activate +
    /// BGTask, damit ein Foreground-Wechsel nicht jeden Type-Sync 7x
    /// triggert.
    /// - Parameter force: when `true`, bypasses the foreground self-throttle
    ///   (W8-A1). Pull-to-refresh passes `true`; the two scenePhase observers
    ///   pass `false` (default) so a foreground bounce runs the sync at most
    ///   once per `dailyStatsForegroundThrottle`, even though both observers
    ///   may call this on the same `.active` transition.
    /// **Phase 07 / plan 07-09 — this is the `foreground` route, and it is one
    /// pass.**
    ///
    /// It used to be a hand-written fan-out: daily statistics, HR buckets,
    /// nutrients, ECG and the Apple-medication mirror, each called directly, on
    /// the same tick that `SpeziCollectionTrigger.trigger(source: .foreground)`
    /// already ran a complete orchestrated pass containing all five. Every
    /// duplicated call was idempotent and every one was still a second HealthKit
    /// read and a second POST. The list is also what made "sync everything" a
    /// different set per call site — this method never reached Mood, cycle, heart
    /// events, workouts or the outbox, and nobody could see that from here.
    ///
    /// What stays is the one thing the pass does not do: the live HK-direct read
    /// that feeds the Schritte tile's today number. That is a local UI read, not
    /// a sync capability, and it has no server leg at all.
    func refreshHealthKitDailyStatsForToday(force: Bool = false) async {
        // W8-A1 — coalesce the double foreground fan-out. A non-forced call
        // inside the throttle window is suppressed; a forced run (pull-to-
        // refresh) always runs and re-arms the window.
        guard dailyStatsForegroundThrottle.shouldRun(force: force) else { return }
        // v0.6.2.x bug-c10-ios-direct — the HK-direct read is what actually feeds
        // the tile's today number; it runs concurrently with the pass, which
        // feeds the server rows every other consumer (insights, trends) reads.
        async let liveRefresh: Void = liveHealthKitTodayStore.refresh()
        async let pass: [HealthSyncCapability] = runHealthSyncPass(.foreground)
        _ = await (liveRefresh, pass)
    }

    /// Re-reads the current server URL from Keychain + bundle defaults and
    /// propagates the new `AppEnvironment` to the APIClient. Idempotent —
    /// repeated calls with the same Keychain value are a no-op.
    ///
    /// **Called by onboarding's `ServerURLStep`** after the user confirms a
    /// custom server URL; subsequent login + auth requests then target the
    /// new host. The `URLSession` itself is not rebuilt — its config carries
    /// only User-Agent + Client-Type headers, which don't change with the URL.
    ///
    /// Note: this swap is safe pre-login only. For paired sessions the auth
    /// token + Cert-Pin SPKI hashes are bundle-pinned to the original host;
    /// flipping mid-session would invalidate both. Onboarding writes the URL
    /// before any 401 fires, so v0.4.1 stays inside the safe window.
    func reloadEnvironment() async {
        let resolved = AppEnvironment.resolve(keychain: keychain)
        environment = resolved
        // R1 — die beobachtbare Adressfrage mitziehen. Erst dadurch schließt
        // sich das Adress-Gate in `RootView`, sobald der Nutzer seine Adresse
        // eingetragen hat, und öffnet es sich wieder, wenn sie fehlt.
        backendAvailability.setHasServerAddress(resolved.isServerConfigured)
        // audit-v0162 M-7 — the cached "server materialises dose slots" verdict
        // describes the PREVIOUS host and says nothing about this one. Drop it
        // so the next `/api/version` probe re-decides; until that answers, the
        // gate falls back to its unknown-state default (no synthesis).
        medicationSlotGate.forget()
        // APIClient is an actor; cross-actor hop required.
        if let apiClient = api as? APIClient {
            await apiClient.setEnvironment(resolved)
        }
    }

    /// Setzt das Initial-Backfill-Window fuer den ersten HK-Sync. Persistiert die
    /// Wahl in UserDefaults (per-User partitioniert) und propagiert die computed
    /// cutoff-Date an den HealthKitService — der nutzt sie als Predicate-Start im
    /// ersten AnchoredObjectQuery (sobald ein Anchor steht, wird die Predicate
    /// von HK ohnehin ignoriert).
    ///
    /// Aufruf-Ort: Onboarding `HealthKitPermissionStep`, BEVOR `requestAuthorization`
    /// auf den ersten ObserverQuery-Wakeup folgt.
    func setHealthKitBackfillWindow(_ window: HealthKitBackfillWindow) async {
        HealthKitBackfillWindowStore.persist(window, keychain: keychain)
        let cutoff = window.lowerBound()
        await healthKit?.setInitialBackfillCutoff(cutoff)
    }

    /// Re-Hydriert die Window-Wahl aus UserDefaults nach App-Start. Wird vom
    /// RootView beim Foreground-Bootstrap aufgerufen, damit ein bereits
    /// onboarded User mit dem damals gewaehlten Window weiter syncht.
    func restoreHealthKitBackfillWindow() async {
        guard let window = HealthKitBackfillWindowStore.load(keychain: keychain) else {
            // Pre-Onboarding oder Pre-A1H — kein Cutoff. HK macht Default
            // (alles seit `.distantPast`), aber das passiert nur wenn auch
            // kein Anchor existiert. Bestehende User mit Anchors sind eh nicht
            // betroffen.
            return
        }
        await healthKit?.setInitialBackfillCutoff(window.lowerBound())
    }
}
