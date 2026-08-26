import Foundation
#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

/// Koordiniert die HealthKit-Background-Sync-Pipeline:
/// 1. Registriert den `BGProcessingTask`-Handler beim Boot (idempotent).
/// 2. Aktiviert (nach erteilter HK-Berechtigung) `HKObserverQuery` + `enableBackgroundDelivery`.
/// 3. Wenn der Handler ausgelöst wird, re-scheduled er sich zuerst (Apple-Pattern:
///    nach jedem Run wieder einreihen) und betritt dann **genau einen** benannten
///    Pass.
///
/// **Phase 07 / Plan 07-09 — ein Trigger, ein Pass.** Der Coordinator besitzt
/// vier der sechsundzwanzig inventarisierten Trigger (`processing`,
/// `appRefresh`, `manual` und — über den Silent-Push-Handler — `silentPush`).
/// Bis Wave 4 rief jeder Wake der Reihe nach vier Hooks auf (Writer-Sweep,
/// Workout-Pass, Aggregat-Anchor-Sweep, ECG) und der erste davon startete
/// bereits den orchestrierten Pass, der drei davon ohnehin enthielt — jeder
/// Doppellauf idempotent, aber real: doppelte HealthKit-Reads, doppelte POSTs,
/// doppelt verbrauchtes Background-Budget. Jetzt benennt jeder Wake seinen
/// `HealthSyncTrigger`, reicht sein eigenes Expiration-Fenster hinein und
/// bekommt die `HealthSyncCapability`-Liste zurück, die der Pass beantwortet
/// hat. Die *nicht*-HealthKit-Hooks (Cache-Sweep, Medikamenten-Reconcile,
/// Live-Activity, Mood-Reminder) bleiben unverändert — sie gehören nicht zum
/// Sync-Pass.
///
/// Der `BGProcessingTask` ist *garantierter Sync* — `HKObserverQuery` allein reicht nicht,
/// weil das System es ablehnen kann, die App für manche Frequenzen aufzuwecken (z. B. wenn
/// der User Low-Power-Mode aktiv hat). Siehe PROJECT_GUIDE.md HealthKit-Specifics.
///
/// Sendable-Note: `BGTaskScheduler.register`'s `launchHandler` ist *nicht* `@Sendable` und
/// läuft auf einer System-Queue. Wir bridgen über eine `@Sendable`-Shim und einen
/// `Task` in den Service-Actor.
public final class BackgroundSyncCoordinator: @unchecked Sendable {
    /// Identifier muss in `project.yml` → `BGTaskSchedulerPermittedIdentifiers` registriert sein.
    public static let bgTaskIdentifier = "dev.healthlog.app.healthkit-sync"

    /// **#66 P0.1 (Baustein 1)** — Identifier des leichten `BGAppRefreshTask`.
    /// Muss ebenfalls in `project.yml` → `BGTaskSchedulerPermittedIdentifiers`
    /// stehen. Das System gewährt AppRefresh-Wakes deutlich häufiger (mehrmals
    /// täglich) als den schweren `BGProcessingTask`; dieser Task fährt nur den
    /// leichten Pull (Spezi-Collection-Trigger + Outbox-Drain), damit die
    /// verbleibenden `start: .manual`-Typen auch ohne Foreground öfter zum
    /// Server fließen (die R3-aggressive-Kadenz-Typen heartRate / stepCount /
    /// sleepAnalysis laufen jetzt auf echter Background-Delivery und brauchen
    /// diesen Pull nicht mehr).
    public static let bgRefreshTaskIdentifier = "dev.healthlog.app.refresh"

    /// **R3 aggressive-Kadenz** — frühestmöglicher Abstand zum nächsten
    /// `BGAppRefreshTask`-Wake, in Sekunden. Verdichtet von 2 h auf ~45 min:
    /// engeres Fenster = iOS darf häufiger wecken, effektiver Sync-Takt näher an
    /// der Datenkadenz (Operator-Entscheid "besserer Empfang, Batterie
    /// zweitrangig"; mehr Wakeups = mehr Verbrauch, bewusst akzeptiert). Nur
    /// die *früheste* Zeit — das System entscheidet nach Budget/Heuristik, ob
    /// es tatsächlich weckt. Als Konstante exponiert, damit der Wert ohne
    /// laufenden `BGTaskScheduler` (Simulator/CI) pinbar ist.
    public static let bgRefreshEarliestInterval: TimeInterval = 45 * 60

    /// Strong reference. `AnyHealthKitWriter` ist nicht class-bound (kann auch ein
    /// Mock-Struct/-Class sein), daher kein `weak`. Lifecycle: der Container hält
    /// sowohl `healthKit` als auch den Coordinator — beide leben so lange wie die App.
    /// Kein Retain-Cycle, weil der Coordinator den Container nicht zurück-halten muss.
    private let healthKit: AnyHealthKitWriter?

    private let hookLock = NSLock()

    /// **Phase 07 / plan 07-09 — the coordinator's one HealthKit route.**
    ///
    /// This replaces four separate hooks (the daily-statistics anchor sweep, the
    /// ECG sweep, the Spezi collection trigger, and the direct workout pass),
    /// each of which the wake bodies called in sequence *in addition to* the
    /// orchestrated pass those calls also ended up starting. The coordinator now
    /// names one `HealthSyncTrigger` per wake and receives back the
    /// `HealthSyncCapability` list that pass answered for — so a wake reports
    /// what it reached instead of asserting that it ran.
    ///
    /// The second argument is the wake's own window: the BGTask expiration flag
    /// rides into the pass, which stops admitting capabilities once iOS is about
    /// to terminate the grant and names the remainder `expired`.
    ///
    /// `nil` = not wired (tests, non-iOS build, pre-attach) — a wake is then a
    /// best-effort no-op for HealthKit, exactly as an unwired hook always was.
    private nonisolated(unsafe) var onHealthSyncPass: (
        @Sendable (HealthSyncTrigger, @escaping @Sendable () -> Bool) async -> [HealthSyncCapability]
    )?

    /// **v0.12 W8-4 — Cache-Sweep-Hook.** Wird am Ende jedes BGTask-Wakeups
    /// best-effort aufgerufen, damit die SWR- + HK-Daily-Stats-SQLite-Caches
    /// nicht monoton wachsen (`sweepOlderThan` war definiert + getestet, aber
    /// nie verdrahtet). Closure-Indirection statt direkter Cache-Dependency,
    /// weil der Coordinator die Cache-Schicht nicht kennen muss — `AppContainer`
    /// verdrahtet `SWRCoordinator.sweepOlderThan` + die
    /// `HealthKitStatisticsSyncCoordinator`-Passthrough hier hinein. `nil` =
    /// nicht verdrahtet (Tests, Non-iOS-Build, Pre-Attach). Sweep-Fehler
    /// blocken den BGTask nicht (das Loeschen alter Cache-Rows ist
    /// best-effort, kein Daten-kritischer Pfad).
    private nonisolated(unsafe) var onCacheSweep: (@Sendable () async -> Void)?

    /// **b181 W-B181 (DOUBLE-DOSE SAFETY) — Med-Reconcile-Hook.** Wird am Anfang
    /// jedes BGTask-Wakeups best-effort aufgerufen, damit eine im WEB / auf
    /// einem zweiten Geraet genommene Dosis auch ohne Foreground in den Store
    /// faellt und ueber `onIntakesDidChange` die Live Activity beendet + die
    /// Med-Widget-Timelines neu laedt. Ohne diesen Hook synchronisierte der
    /// Sperrbildschirm/das Widget erst beim naechsten App-Foreground — der
    /// Doppeleinnahme-Pfad. Closure-Indirection statt direkter Store-Dependency,
    /// weil der Coordinator die Store-Schicht nicht kennen muss; `AppContainer`
    /// verdrahtet `medicationsStore.load(force:)` hinein. `nil` = nicht
    /// verdrahtet (Tests, Non-iOS-Build, Pre-Attach). Best-effort: ein
    /// Reconcile-Fehler blockt den BGTask-Erfolg nicht.
    private nonisolated(unsafe) var onMedicationReconcile: (@Sendable () async -> Void)?

    /// **v0.15.5 AUD-1 F4 — Mood-Reminder-Re-Arm-Hook.** Wird am Ende jedes
    /// BGTask-Wakeups best-effort aufgerufen, damit der lokale Abend-Mood-
    /// Reminder (`mood-reminder-local`, ein nicht-wiederholender
    /// `UNCalendarNotificationTrigger`) auch ohne App-Foreground neu armiert
    /// wird. Ohne diesen Hook re-armte der Reminder nur auf `scenePhase .active`
    /// — wer die App nicht oeffnet, bekam ihn genau einmal und danach nie wieder
    /// (analog zum One-Shot-Med-Cadence-Bug). Closure-Indirection statt direkter
    /// Store-Dependency: `AppContainer` verdrahtet den Mood-Store + die
    /// Settings-Toggle + den `NotificationService` hinein. `nil` = nicht
    /// verdrahtet (Tests, Non-iOS-Build, Pre-Attach). Best-effort: ein
    /// Re-Arm-Fehler blockt den BGTask-Erfolg nicht.
    private nonisolated(unsafe) var onMoodReconcile: (@Sendable () async -> Void)?

    /// **v0.16.1 W-LA-BG (LIVE-ACTIVITY BACKGROUND START) — LA-Reconcile-Hook.**
    /// Wird am Ende jedes BGTask-Wakeups best-effort + **inline awaited**
    /// aufgerufen, NACHDEM `onMedicationReconcile` den Store frisch geladen hat,
    /// damit eine Dosis, die *waehrend* der Hintergrund-Phase faellig wurde,
    /// ihre Medication Live Activity STARTET — nicht nur die lokale
    /// Notification. Der bestehende `onIntakesDidChange`-Pfad startet die LA nur
    /// indirekt ueber einen fire-and-forget `Task`, der nach `setTaskCompleted`
    /// abgeschnitten werden kann; ausserdem feuert er nur bei *Daten*-Aenderung,
    /// nicht wenn allein das Verstreichen der Zeit eine Dosis faellig macht.
    /// Dieser Hook awaitet die ActivityKit-`request`-Mutation inline, bevor der
    /// BGTask `setTaskCompleted` ruft, sodass der Start im gewaehrten
    /// Background-Runtime-Fenster abgeschlossen wird. Closure-Indirection statt
    /// direkter Controller-Dependency: `AppContainer` verdrahtet den
    /// `MedicationLiveActivityController` + den Store + die Delivery-Prefs
    /// hinein. `nil` = nicht verdrahtet (Tests, Non-ActivityKit-Build,
    /// Pre-Attach). Best-effort: ein Reconcile-Fehler blockt den BGTask nicht.
    private nonisolated(unsafe) var onLiveActivityReconcile: (@Sendable () async -> Void)?

    /// **Reliability M1 (audit-v0162) — Outbox-Drain-Hook.** Wird am Ende jedes
    /// BGTask-Wakeups best-effort aufgerufen, damit ein offline geloggter
    /// *User*-Write (Messung / Mood / Medikamenten-Einnahme) auch ohne
    /// App-Foreground repliziert wird. Ohne diesen Hook lief der Outbox-Replay
    /// NUR auf einer Online-Interface-Flanke (solange der Prozess lebt), auf
    /// App-Foreground oder beim Auth-Bootstrap — ein passiver Widget-/Watch-Nutzer
    /// konnte seine Writes tagelang haengen lassen. Der verdrahtete Hook ist
    /// probe-gated (`confirmedReachable()`), sodass ein Captive-Portal-/Degraded-
    /// Server-Wakeup ein No-op ist; hier lediglich expiration-guarded wie die
    /// anderen Hooks aufgerufen. Der verschluesselte Store + der Cipher-Key sind
    /// im BGTask-Fenster per Design lesbar (`completeUntilFirstUserAuthentication`,
    /// ADR-012). Closure-Indirection statt direkter Replay-Dependency; `nil` =
    /// nicht verdrahtet (Tests, Non-iOS-Build, Pre-Attach). Best-effort: ein
    /// Drain-Fehler blockt den BGTask-Erfolg nicht.
    private nonisolated(unsafe) var onOutboxDrain: (@Sendable () async -> Void)?

    /// Direct workout importer hook. `.processing` is reserved for the longer
    /// BGProcessing grant; AppRefresh and silent push request
    /// `.incrementalOnly`, whose writer-side anchor gate prevents a first-run
    /// history walk in their short budget.
    ///
    /// **Phase 07 / plan 07-09** kept this hook and stopped calling it from the
    /// wake bodies. It is wired with the authenticated user resolution and the
    /// post-ingest revalidation that `AppContainer.wireWorkoutBackgroundSync`
    /// owns, so it — not a second, thinner call — is what the orchestrator's
    /// `workoutImport` capability runs. One owner, reached through one pass.
    private nonisolated(unsafe) var onWorkoutSync: (@Sendable (WorkoutSyncPassMode) async -> Bool)?

    /// Process-weit eindeutiger State, weil `BGTaskScheduler.register` mit demselben
    /// Identifier zweimal aufzurufen NSInternalInconsistencyException wirft (kein
    /// Swift-Throw — harter Crash). Das passiert in Tests, wenn der Test-Host die App
    /// schon einmal hochgefahren hat und ein Test danach einen weiteren Container baut.
    /// Der NSLock-geschützte statische Bool ist die einzige zuverlässige Lösung.
    /// `nonisolated(unsafe)` ist hier korrekt: der Zugriff läuft IMMER unter
    /// `registrationLock`, das ist der Concurrency-Beweis.
    private static let registrationLock = NSLock()
    private nonisolated(unsafe) static var registeredIdentifiers: Set<String> = []

    public init(healthKit: AnyHealthKitWriter?) {
        self.healthKit = healthKit
    }

    /// Attaches the one HealthKit route (plan 07-09). `AppContainer` wires
    /// `runHealthSyncPass(_:isExpired:)` in, which resolves the trigger's plan,
    /// budget and account admission once and answers with named capabilities.
    func attachHealthSyncRoute(
        _ hook: @escaping @Sendable (
            HealthSyncTrigger,
            @escaping @Sendable () -> Bool
        ) async -> [HealthSyncCapability]
    ) {
        hookLock.withLock { onHealthSyncPass = hook }
    }

    private func currentHealthSyncRoute() -> (
        @Sendable (HealthSyncTrigger, @escaping @Sendable () -> Bool) async -> [HealthSyncCapability]
    )? {
        hookLock.withLock { onHealthSyncPass }
    }

    /// Enters the one orchestrated pass for `trigger`, once.
    ///
    /// Returns the capabilities the pass named. An empty answer means either no
    /// route is wired or the caller was already cancelled — both are honest
    /// "this wake reached nothing", never a silent success.
    @discardableResult
    func runHealthSyncPass(
        _ trigger: HealthSyncTrigger,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> [HealthSyncCapability] {
        guard !Task.isCancelled, !isExpired(), let route = currentHealthSyncRoute() else { return [] }
        return await route(trigger, isExpired)
    }

    /// **v0.12 W8-4** — Setzt den Cache-Sweep-Hook nachtraeglich. `AppContainer`
    /// ruft diesen, sobald `SWRCoordinator` + ggf.
    /// `HealthKitStatisticsSyncCoordinator` verfuegbar sind.
    public func attachCacheSweepHook(_ hook: @escaping @Sendable () async -> Void) {
        hookLock.withLock { onCacheSweep = hook }
    }

    private func currentCacheSweepHook() -> (@Sendable () async -> Void)? {
        hookLock.withLock { onCacheSweep }
    }

    /// **b181 W-B181** — Setzt den Med-Reconcile-Hook nachtraeglich.
    /// `AppContainer` ruft diesen, sobald `MedicationsStore` verfuegbar ist.
    public func attachMedicationReconcileHook(_ hook: @escaping @Sendable () async -> Void) {
        hookLock.withLock { onMedicationReconcile = hook }
    }

    private func currentMedicationReconcileHook() -> (@Sendable () async -> Void)? {
        hookLock.withLock { onMedicationReconcile }
    }

    /// **v0.15.5 AUD-1 F4** — Setzt den Mood-Reminder-Re-Arm-Hook nachtraeglich.
    /// `AppContainer` ruft diesen, sobald `MoodStore` + `SettingsStore` +
    /// `NotificationService` verfuegbar sind.
    public func attachMoodReconcileHook(_ hook: @escaping @Sendable () async -> Void) {
        hookLock.withLock { onMoodReconcile = hook }
    }

    private func currentMoodReconcileHook() -> (@Sendable () async -> Void)? {
        hookLock.withLock { onMoodReconcile }
    }

    /// **v0.16.1 W-LA-BG** — Setzt den Live-Activity-Reconcile-Hook
    /// nachtraeglich. `AppContainer` ruft diesen, sobald der
    /// `MedicationLiveActivityController` + `MedicationsStore` verfuegbar sind.
    public func attachLiveActivityReconcileHook(_ hook: @escaping @Sendable () async -> Void) {
        hookLock.withLock { onLiveActivityReconcile = hook }
    }

    private func currentLiveActivityReconcileHook() -> (@Sendable () async -> Void)? {
        hookLock.withLock { onLiveActivityReconcile }
    }

    /// **Reliability M1 (audit-v0162)** — Setzt den Outbox-Drain-Hook
    /// nachtraeglich. `AppContainer` verdrahtet den probe-gated
    /// `OutboxReplayService.runOnce()`-Pfad hinein (siehe
    /// `AppContainer+OutboxBGDrain`).
    public func attachOutboxDrainHook(_ hook: @escaping @Sendable () async -> Void) {
        hookLock.withLock { onOutboxDrain = hook }
    }

    private func currentOutboxDrainHook() -> (@Sendable () async -> Void)? {
        hookLock.withLock { onOutboxDrain }
    }

    public func attachWorkoutSyncHook(
        _ hook: @escaping @Sendable (WorkoutSyncPassMode) async -> Bool
    ) {
        hookLock.withLock { onWorkoutSync = hook }
    }

    private func currentWorkoutSyncHook() -> (@Sendable (WorkoutSyncPassMode) async -> Bool)? {
        hookLock.withLock { onWorkoutSync }
    }

    /// Runs the direct workout path on demand (silent push and focused tests).
    /// Returns whether authenticated, budget-eligible work actually ran.
    @discardableResult
    public func runWorkoutSync(
        mode: WorkoutSyncPassMode,
        source: WorkoutSyncSource = .manual
    ) async -> Bool {
        guard !Task.isCancelled, let sync = currentWorkoutSyncHook() else { return false }
        let didRun = await WorkoutSyncDiagnosticContext.$source.withValue(source) {
            await sync(mode)
        }
        guard !Task.isCancelled else { return false }
        return didRun
    }

    /// The manual "Jetzt syncen" pass.
    ///
    /// **Plan 07-09** replaced its three-call fan-out (workout → aggregates →
    /// ECG) with the one `.manual` pass, whose plan is every capability rather
    /// than the three someone remembered. That is the whole point of the phase:
    /// "sync everything" used to be whatever the call site listed.
    public func runManualHealthSyncPass() async {
        await SyncTriggerContext.shared.withTrigger(.foreground) {
            _ = await runHealthSyncPass(HealthSyncTrigger.manual)
        }
    }

    /// **b182 W-B182 (#22)** — Runs the attached med-reconcile hook on demand.
    /// Used by the silent-push handler so a server intake push reconciles the
    /// store (→ Live Activity end + widget reload) without waiting for the next
    /// foreground or BGTask wake. No-op when no hook is attached yet.
    /// Returns `true` when a reconcile actually ran.
    @discardableResult
    public func runMedicationReconcile() async -> Bool {
        guard let reconcile = currentMedicationReconcileHook() else { return false }
        await reconcile()
        return true
    }

    /// **#66 P0.1 (Baustein 3)** — Runs the attached outbox-drain hook on demand.
    /// Used by the silent-push handler so a server wake drains an offline-logged
    /// user write immediately (probe-gated inside the wired hook), without waiting
    /// for the next foreground / BGProcessing / BGAppRefresh wake. No-op when no
    /// hook is attached yet. Returns `true` when a drain actually ran.
    @discardableResult
    public func runOutboxDrain() async -> Bool {
        guard let drain = currentOutboxDrainHook() else { return false }
        await drain()
        return true
    }

    /// Registriert den BGTask-Handler. Muss VOR dem ersten `submit(_:)` und idealerweise
    /// VOR `applicationDidFinishLaunching` returnt aufgerufen werden — wir machen es im
    /// `AppContainer.init`, der seinerseits aus `HealthLogApp.init` getrieben wird.
    public func registerBGTaskHandler() {
        #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
            // Der schwere garantierte-Sync `BGProcessingTask` …
            registerHandler(identifier: Self.bgTaskIdentifier) { [weak self] task in
                // BGTask ist nicht Sendable in Swift 6 — wir packen es in einen
                // `@unchecked Sendable`-Shim, damit es in den Task hineinwandern darf.
                // Der System-Handler ruft uns nur einmal pro Submission, kein Aliasing.
                let envelope = BGTaskEnvelope(task: task)
                Task.detached { [weak self] in
                    await self?.handleBGTask(envelope: envelope)
                }
            }
            // … und der leichte, häufiger gewährte `BGAppRefreshTask` (#66 P0.1).
            registerHandler(identifier: Self.bgRefreshTaskIdentifier) { [weak self] task in
                let envelope = BGTaskEnvelope(task: task)
                Task.detached { [weak self] in
                    await self?.handleBGRefresh(envelope: envelope)
                }
            }
        #endif
    }

    #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
        /// Registriert *einen* Task-Handler unter dem Doppel-Register-Guard.
        /// Der prozessweite `registeredIdentifiers`-Set trägt den State **pro
        /// Identifier** — ein zweiter Register-Versuch desselben Identifiers
        /// (z. B. wenn der Test-Host schon einen Container gebaut hat) würde sonst
        /// eine `NSInternalInconsistencyException` (harter Crash) auslösen. Beide
        /// Tasks (`bgTaskIdentifier`, `bgRefreshTaskIdentifier`) laufen durch
        /// denselben Guard, jeder mit eigenem State-Eintrag.
        private func registerHandler(
            identifier: String,
            launchHandler: @escaping @Sendable (BGTask) -> Void
        ) {
            Self.registrationLock.lock()
            let alreadyRegistered = Self.registeredIdentifiers.contains(identifier)
            if !alreadyRegistered {
                Self.registeredIdentifiers.insert(identifier)
            }
            Self.registrationLock.unlock()
            guard !alreadyRegistered else {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug(
                    "BGTaskScheduler-Handler \(identifier, privacy: .public) bereits in diesem Prozess registriert — skip."
                )
                return
            }

            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil, // System-Queue
                launchHandler: launchHandler
            )
            if registered {
                // Static BGTask identifier constants — operator-grade, no PII.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.info("BGTaskScheduler-Handler registriert: \(identifier, privacy: .public)")
            } else {
                HLLog.healthKit
                    .error(
                        "BGTaskScheduler.register lehnte \(identifier, privacy: .public) ab — Identifier in project.yml gesetzt?"
                    )
            }
        }
    #endif

    /// Aktiviert HK-Background-Deliveries. Darf erst NACH erteilter HK-Berechtigung
    /// aufgerufen werden (sonst HKErrorNotAuthorized). Idempotent: HK selbst dedupliziert
    /// `enableBackgroundDelivery`-Aufrufe pro Type.
    /// Arms HealthKit background delivery and re-submits both BGTask requests.
    ///
    /// **Plan 07-09 took the pass out of here.** It used to fire a `.foreground`
    /// collection trigger and a detached anchor sweep, which meant the two call
    /// sites that reach it — `RootView`'s cold-launch re-activation and the
    /// post-authorization paths in `HKReadinessStore` and
    /// `HealthKitPermissionStep` — could not name the trigger they actually are.
    /// Both are now `coldActivation` and `postAuthentication` respectively, named
    /// by the caller and run as one pass; this method does the two things its
    /// name says and nothing else. The connect spinner still cannot hang on a
    /// backfill, for the stronger reason that this path no longer starts one.
    public func activateHealthKitBackgroundDeliveries() async {
        _ = await reactivateDeliveryAndSchedule()
    }

    public func reactivateHealthKitBackgroundDeliveries() async {
        _ = await reactivateDeliveryAndSchedule()
    }

    @discardableResult
    private func reactivateDeliveryAndSchedule() async -> Bool {
        guard let hk = healthKit else { return false }
        do {
            try await hk.activateBackgroundDeliveries()
            HLLog.healthKit.info("HK-Background-Deliveries aktiviert.")
        } catch {
            HLLog.healthKit.error(
                "HK-Background-Delivery-Aktivierung fehlgeschlagen: \(error.localizedDescription, privacy: .private)"
            )
        }
        scheduleNextBGSync()
        scheduleNextBGRefresh()
        return true
    }

    /// Reserviert das nächste BGProcessing-Task-Slot beim System.
    /// Apple-Pattern: nach jedem `setTaskCompleted` neu submitten — sonst gibt's nur
    /// EINEN Wakeup nach App-Install.
    public func scheduleNextBGSync() {
        #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
            let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
            // HK-Sync braucht weder Power noch Network *zwingend* — die HK-DB lebt lokal,
            // Server-Upload wäre "nice", aber wir wollen lieber einen Sync-Pass ohne Netz
            // als gar keinen. Outbox hält den Upload eh fest.
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = false
            // Mindestens 15 min Abstand zum nächsten Run — verhindert, dass das System
            // uns sofort wieder aufweckt und einen Energie-Strafrechnung schickt.
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

            do {
                try BGTaskScheduler.shared.submit(request)
                // Static BGTask identifier constant — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug("BGProcessingTask eingereiht: \(Self.bgTaskIdentifier, privacy: .public)")
            } catch BGTaskScheduler.Error.notPermitted {
                HLLog.healthKit.error("BGTaskScheduler.notPermitted — Entitlement / project.yml prüfen.")
            } catch BGTaskScheduler.Error.tooManyPendingTaskRequests {
                // Kein Drama — das System hat schon einen Pending Request für uns,
                // der reicht völlig.
                HLLog.healthKit.debug("BGTaskScheduler: bereits ein Request pending — kein Re-Submit.")
            } catch BGTaskScheduler.Error.unavailable {
                HLLog.healthKit.warning("BGTaskScheduler nicht verfügbar (Simulator? Background-App-Refresh aus?).")
            } catch {
                HLLog.healthKit.error("BGTaskScheduler.submit failure: \(error.localizedDescription, privacy: .private)")
            }
        #endif
    }

    /// **#66 P0.1 (Baustein 1)** — Reiht den nächsten `BGAppRefreshTask` ein.
    /// Wie beim Processing-Task gilt Apple-Pattern: nach jedem Lauf neu
    /// submitten, sonst gibt's nur EINEN Wake nach Install. `earliestBeginDate`
    /// ~45 min (R3 aggressive-Kadenz — verdichtet von 2 h). Das ist nur die
    /// *frühestmögliche* Wake-Zeit, keine Garantie: das System entscheidet nach
    /// seinem Budget/Heuristik, wann (und ob) es tatsächlich weckt. Ein engeres
    /// Fenster signalisiert iOS Bereitschaft für häufigere Refreshes und bringt
    /// den effektiven Sync-Takt näher an die Datenkadenz — Operator-Entscheid
    /// "besserer Empfang, Batterie zweitrangig". Kosten: mehr Wakeups = mehr
    /// Verbrauch, bewusst akzeptiert. Reschedule-Logik unverändert (nach jedem
    /// Lauf neu submitten). Ein `BGAppRefreshTaskRequest` trägt (anders als
    /// `BGProcessingTaskRequest`) keine Power-/Network-Flags — das System
    /// entscheidet allein.
    public func scheduleNextBGRefresh() {
        #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
            let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshTaskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: Self.bgRefreshEarliestInterval)

            do {
                try BGTaskScheduler.shared.submit(request)
                // Static BGTask identifier constant — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug("BGAppRefreshTask eingereiht: \(Self.bgRefreshTaskIdentifier, privacy: .public)")
            } catch BGTaskScheduler.Error.notPermitted {
                HLLog.healthKit.error("BGAppRefresh notPermitted — `fetch`-Background-Mode / project.yml prüfen.")
            } catch BGTaskScheduler.Error.tooManyPendingTaskRequests {
                HLLog.healthKit.debug("BGAppRefresh: bereits ein Request pending — kein Re-Submit.")
            } catch BGTaskScheduler.Error.unavailable {
                HLLog.healthKit.warning("BGAppRefresh nicht verfügbar (Simulator? Background-App-Refresh aus?).")
            } catch {
                HLLog.healthKit.error("BGAppRefresh submit failure: \(error.localizedDescription, privacy: .private)")
            }
        #endif
    }

    // MARK: - BGTask Handler

    #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
        private func handleBGTask(envelope: BGTaskEnvelope) async {
            await runBGSync(on: BGTaskCompletionBox(task: envelope.task))
        }

        private func handleBGRefresh(envelope: BGTaskEnvelope) async {
            await runBGRefresh(on: BGTaskCompletionBox(task: envelope.task))
        }
    #endif

    /// Hop to the `@MainActor` diagnostics singleton to record a background-wake
    /// heartbeat (#66 P0.1 Baustein 4). Best-effort — a diagnostics write never
    /// affects the BGTask completion contract.
    private func recordWake(_ kind: HKSyncDiagnostics.WakeKind) async {
        await MainActor.run {
            HKSyncDiagnostics.shared.recordWake(kind)
        }
    }

    /// **W-HK-RELIABILITY H-3 — exactly-once completion + expiration-safe + reschedule.**
    ///
    /// Testable core of the BGTask handler, abstracted over ``BGTaskCompleting``
    /// so a unit test can drive it without a real `BGTask` (which the test host
    /// cannot construct). Guarantees:
    ///
    /// 1. **Reschedule first** — the next BGTask is submitted before any work
    ///    runs, so a crash mid-sweep does not kill the recurrence (WWDC19).
    /// 2. **Expiration handler** — on iOS-driven expiration it cancels the
    ///    in-flight work `Task` *and* completes the BGTask (`success: false`)
    ///    immediately, so iOS always sees a completion and does not throttle us.
    /// 3. **Exactly-once `setTaskCompleted`** — a one-shot guard
    ///    (``OneShotCompletion``) makes the normal path and the expiration path
    ///    race-safe: whichever fires first wins, the other is a no-op.
    func runBGSync(on task: some BGTaskCompleting) async {
        HLLog.healthKit.info("BG HK sync ran") // DEBUG-Anker — von Anleitung gefordert.

        // #66 P0.1 (Baustein 4) — honest evidence: this BGProcessing wake
        // actually fired. Recorded before the work so the surface shows the
        // wake even if the pass later expires.
        await recordWake(.processing)

        // Reschedule BEFORE work so a crash doesn't kill the recurrence.
        scheduleNextBGSync()

        let completion = OneShotCompletion()
        let expirationFlag = ExpirationFlag()

        // The work runs in a child Task so the expiration handler can cancel it.
        let work = Task { [weak self] in
            await self?.runBGSyncPasses(expirationFlag: expirationFlag)
        }

        // Expiration: BGProcessing grants ~30s/wake. On expiry we cancel the
        // in-flight work AND complete exactly-once with success=false. Our
        // anchor persistence writes only AFTER sample processing, so an aborted
        // pass loses no data — the next wake re-reads the same window.
        task.setExpirationHandler {
            expirationFlag.set()
            work.cancel()
            HLLog.healthKit.warning("BGTask Expiration-Handler getriggert — Sweep abgebrochen.")
            completion.complete(task: task, success: false)
        }

        guard healthKit != nil else {
            completion.complete(task: task, success: false)
            return
        }

        await work.value

        // Normal path completion — exactly-once guarded against the expiration
        // handler having already fired.
        completion.complete(task: task, success: !expirationFlag.value)
    }

    /// The actual sync passes, each expiration-guarded + best-effort. Split out
    /// so the orchestration in ``runBGSync(on:)`` stays focused on the
    /// completion/expiration contract.
    ///
    /// **CU-21 (1)** — the whole pass runs inside a `.background`
    /// ``SyncTriggerContext`` window, so every batch POST it causes (per-sample
    /// sweep, daily stats, HR buckets, outbox drain) carries
    /// `syncTrigger: "background"` on the wire. That is the signal the server
    /// needs to tell "this phone delivers on its own" from "this phone delivers
    /// only while the app is open" — the verification #66 was missing.
    private func runBGSyncPasses(expirationFlag: ExpirationFlag) async {
        await SyncTriggerContext.shared.withTrigger(.background) {
            await runBGSyncPassesBody(expirationFlag: expirationFlag)
        }
    }

    private func runBGSyncPassesBody(expirationFlag: ExpirationFlag) async {
        guard healthKit != nil else { return }

        // **Plan 07-09 — one named trigger, one pass.** This used to be four
        // sequential calls (the writer's shimmed sweep, the direct workout pass,
        // the aggregate anchor-sweep hook, the ECG hook), three of which the
        // orchestrated pass the first one started *also* made. The
        // `HealthSyncCapability` list that comes back is what this wake actually
        // reached; the pass names every capability it planned, including the ones
        // it did not admit and the ones the expiring grant cut short.
        let answered = await runHealthSyncPass(
            HealthSyncTrigger.processing,
            isExpired: { expirationFlag.value }
        )
        // A count of fixed enum cases — operator-grade, no PII.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info("BG processing pass named \(answered.count, privacy: .public) capabilities")

        // V0.12 W8-4: nach dem Sync-Pass die SQLite-Caches sweepen, damit
        // sie nicht monoton wachsen (SWR 30d, HK-Daily-Stats 90d). Best-
        // effort — laeuft nur, wenn kein Expiration ansteht, und blockt den
        // BGTask-Erfolg nicht (Sweep-Fehler werden im Hook geschluckt +
        // geloggt).
        if !expirationFlag.value, !Task.isCancelled, let sweep = currentCacheSweepHook() {
            await sweep()
        }

        // b181 W-B181 (DOUBLE-DOSE SAFETY): force-revalidate the medications
        // store so a dose taken on the WEB / a second device reaches the
        // store even without a foreground, driving the `onIntakesDidChange`
        // reconcile chain (Live Activity end/refresh + med widget reload).
        // Best-effort + expiration-guarded — a reconcile failure does not
        // block the BGTask's success (the next wakeup / foreground retries).
        if !expirationFlag.value, !Task.isCancelled, let reconcile = currentMedicationReconcileHook() {
            await reconcile()
        }

        // v0.16.1 W-LA-BG (LIVE-ACTIVITY BACKGROUND START): AFTER the med
        // reconcile has force-loaded the store with the current day's intakes,
        // reconcile the medication Live Activity so a dose that became due
        // *while backgrounded* gets its Live Activity STARTED — not just the
        // local notification (which v0.15.5 already re-arms). The store's
        // `onIntakesDidChange` chain starts the LA only via a fire-and-forget
        // `Task` that `setTaskCompleted` can cut off, and only fires on a data
        // change (not when mere elapsed time makes a dose due). This hook awaits
        // the ActivityKit `request` INLINE inside the granted background-runtime
        // window. Best-effort + expiration-guarded — a failure never fails the
        // BGTask (the next wakeup / foreground retries).
        if !expirationFlag.value, !Task.isCancelled, let liveActivityReconcile = currentLiveActivityReconcileHook() {
            await liveActivityReconcile()
        }

        // v0.15.5 AUD-1 F4 (mood-reminder reliability): re-arm the local
        // evening mood reminder from the guaranteed-sync wakeup. The reminder
        // is a non-repeating `UNCalendarNotificationTrigger` whose "logged
        // today → cancel" gate makes a repeating trigger awkward, so it
        // depends on a re-arm; previously that re-arm only ran on app
        // foreground (`scenePhase .active`), so a user who didn't open the app
        // got it once and never again. This second, app-foreground-independent
        // re-arm rides the same wakeup that re-arms medications. Best-effort +
        // expiration-guarded — a re-arm failure does not block the BGTask.
        if !expirationFlag.value, !Task.isCancelled, let moodReconcile = currentMoodReconcileHook() {
            await moodReconcile()
        }

        // Reliability M1 (audit-v0162): the encrypted Outbox is drained on the
        // guaranteed-sync wakeup so a user write logged offline (measurement /
        // mood / medication intake) does not sit queued until the user next
        // foregrounds the app — for a passive widgets/watch-only user, days.
        //
        // **Plan 07-09** no longer calls the drain hook a second time here: the
        // pass above plans `outboxDrain` as its last capability, and it is the
        // same probe-gated hook (`confirmedReachable()`) reached through the
        // orchestrator. Draining it here as well would replay the same rows
        // twice in one wake.
    }

    // MARK: - BGAppRefreshTask core (#66 P0.1 — Baustein 1)

    /// **#66 P0.1 (Baustein 1) — BGAppRefreshTask handler.** Testable core over
    /// the ``BGTaskCompleting`` seam (same contract as ``runBGSync(on:)``:
    /// reschedule-first, expiration-safe, exactly-once completion), but doing
    /// only the *light* work the more frequent AppRefresh wake warrants: one
    /// `.appRefresh` pass, whose plan is the incremental capability set under the
    /// AppRefresh budget. The med-/mood-/LA-reconcile hooks stay on the
    /// `BGProcessingTask` so an AppRefresh grant (short runtime budget) is never
    /// wasted on multi-thousand-row backfills.
    func runBGRefresh(on task: some BGTaskCompleting) async {
        HLLog.healthKit.info("BG HK refresh ran") // DEBUG-Anker, analog runBGSync.

        // #66 P0.1 (Baustein 4) — honest evidence: this AppRefresh wake fired.
        await recordWake(.appRefresh)

        // Reschedule BEFORE work so a crash / early expiry doesn't kill the
        // recurrence (Apple-Pattern, mirrors runBGSync).
        scheduleNextBGRefresh()

        let completion = OneShotCompletion()
        let expirationFlag = ExpirationFlag()

        let work = Task { [weak self] in
            await self?.runBGRefreshPasses(expirationFlag: expirationFlag)
        }

        task.setExpirationHandler {
            expirationFlag.set()
            work.cancel()
            HLLog.healthKit.warning("BGAppRefresh Expiration-Handler getriggert — Refresh abgebrochen.")
            completion.complete(task: task, success: false)
        }

        await work.value

        completion.complete(task: task, success: !expirationFlag.value)
    }

    /// The light AppRefresh pass, expiration-guarded + best-effort (an unwired
    /// route is a no-op; a failure never fails the task). **CU-21 (1)** — same
    /// `.background` ``SyncTriggerContext`` window as the heavy pass, so every
    /// POST it causes still carries `syncTrigger: "background"` on the wire.
    private func runBGRefreshPasses(expirationFlag: ExpirationFlag) async {
        await SyncTriggerContext.shared.withTrigger(.background) {
            await runBGRefreshPassesBody(expirationFlag: expirationFlag)
        }
    }

    /// **Plan 07-09 — one named trigger, one pass.** The AppRefresh wake used to
    /// arm the collectors, then run the workout pass, then drain the outbox. The
    /// `.appRefresh` plan is the incremental set — sample collection, workouts,
    /// heart events, State of Mind, outbox — under the AppRefresh budget (one
    /// page per type, incremental only, no first history walk), and every
    /// capability outside that set comes back named `deferred` rather than
    /// silently missing.
    private func runBGRefreshPassesBody(expirationFlag: ExpirationFlag) async {
        let answered = await runHealthSyncPass(
            HealthSyncTrigger.appRefresh,
            isExpired: { expirationFlag.value }
        )
        // A count of fixed enum cases — operator-grade, no PII.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info("BG refresh pass named \(answered.count, privacy: .public) capabilities")
    }
}

// MARK: - BGTask completion abstraction (W-HK-RELIABILITY H-3)

/// Minimal seam over the two `BGTask` calls the coordinator needs
/// (`setExpirationHandler` + `setTaskCompleted`). Abstracting them lets the
/// completion/expiration contract be unit-tested with a spy — the real
/// `BGTask` is system-vended and cannot be constructed in a test.
protocol BGTaskCompleting: Sendable {
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func setTaskCompleted(success: Bool)
}

/// One-shot completion guard. Ensures `setTaskCompleted` is delivered to a
/// `BGTaskCompleting` **exactly once**, no matter whether the normal path or
/// the expiration handler reaches it first (they race on separate threads).
final class OneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Completes the task exactly once. Subsequent calls are no-ops.
    func complete(task: some BGTaskCompleting, success: Bool) {
        let shouldComplete: Bool = lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
        guard shouldComplete else { return }
        task.setTaskCompleted(success: success)
    }
}

#if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
    /// Live `BGTaskCompleting` over a system `BGTask`. `@unchecked Sendable`
    /// because `BGTask` is not Sendable but the system vends it once and we
    /// consume it once (no aliasing — same contract as `BGTaskEnvelope`).
    private struct BGTaskCompletionBox: BGTaskCompleting, @unchecked Sendable {
        let task: BGTask

        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            task.expirationHandler = handler
        }

        func setTaskCompleted(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }
#endif

#if canImport(BackgroundTasks)
    /// Sendable-Shim für `BGTask` (selbst nicht Sendable). Wird genau einmal vom System
    /// übergeben und genau einmal konsumiert — kein Aliasing.
    private struct BGTaskEnvelope: @unchecked Sendable {
        let task: BGTask
    }
#endif

/// Atomisches Flag für den Expiration-Handler. NSLock-basiert weil `BGTask.expirationHandler`
/// auf einer beliebigen Thread läuft — wir wollen kein Actor-Hopping in einem Code-Pfad,
/// der vom System "harten" Cutoff hat.
private final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didExpire = false

    func set() {
        lock.withLock { didExpire = true }
    }

    var value: Bool {
        lock.withLock { didExpire }
    }
}
