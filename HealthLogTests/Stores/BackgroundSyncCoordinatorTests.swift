// Diese Suite testet App-Target-Symbole (`AppContainer`, `BackgroundSyncCoordinator`),
// die in der SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// Mock-Writer für Wiring-Tests. Kein echtes HealthKit involviert — wir wollen nur
    /// asserten, dass das Aufruf-Path durchlaeuft (`activate -> writer.activate`).
    final class MockHealthKitWriter: AnyHealthKitWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var _activateCallCount = 0
        private var _syncPassCallCount = 0
        private var _writeCallCount = 0
        private var shouldThrow: Bool
        /// CYC-3 — the no-prompt biological-sex signal this mock returns, so a
        /// composition test can prove `AppContainer` actually wires the gate's
        /// `biologicalSexProvider` through to `healthKit.cycleBiologicalSex()`
        /// (the provider was dead — defaulted to `.unknown` — before the wiring).
        private let _cycleBiologicalSex: CycleGateResolver.BiologicalSexSignal

        init(
            shouldThrow: Bool = false,
            cycleBiologicalSex: CycleGateResolver.BiologicalSexSignal = .unknown
        ) {
            self.shouldThrow = shouldThrow
            _cycleBiologicalSex = cycleBiologicalSex
        }

        func cycleBiologicalSex() async -> CycleGateResolver.BiologicalSexSignal {
            _cycleBiologicalSex
        }

        var activateCallCount: Int {
            lock.withLock { _activateCallCount }
        }

        var syncPassCallCount: Int {
            lock.withLock { _syncPassCallCount }
        }

        var writeCallCount: Int {
            lock.withLock { _writeCallCount }
        }

        /// `HealthLog.Measurement` (Domain-Type) explizit qualifizieren — sonst kollidiert
        /// der Param-Type mit `Foundation.Measurement<UnitType>` an genau dieser Signatur.
        func write(_: HealthLog.Measurement) async throws {
            lock.withLock { _writeCallCount += 1 }
        }

        /// W-HKBACKFILL — records every batch handed to the server-origin mirror
        /// (latest-page + historical backfill) so the backfill suite can pin the
        /// run-once gate, source policy, and what reaches the mirror.
        private var _mirrorCallCount = 0
        private var _mirroredMeasurements: [HealthLog.Measurement] = []

        var mirrorCallCount: Int {
            lock.withLock { _mirrorCallCount }
        }

        var mirroredMeasurements: [HealthLog.Measurement] {
            lock.withLock { _mirroredMeasurements }
        }

        func mirrorServerMeasurements(_ measurements: [HealthLog.Measurement]) async {
            lock.withLock {
                _mirrorCallCount += 1
                _mirroredMeasurements.append(contentsOf: measurements)
            }
        }

        func writeMood(_: MoodEntry) async throws {
            // S4 / QA6 #2: HKStateOfMind mirror. Mock no-op.
        }

        func deleteMood(id _: String) async throws {
            // v0.10.0 W10 M1 — HKStateOfMind mirror delete. Mock no-op.
        }

        func requestMoodAuthorization() async throws {
            // v0.10.0 W-Mood-B — State-of-Mind opt-in auth. Mock no-op.
        }

        func startMoodImport(repo _: MoodRepository, userID _: String?) async {
            // v0.10.0 W-Mood-B — State-of-Mind import. Mock no-op.
        }

        func stopMoodImport() async {
            // v0.10.0 W-Mood-B — State-of-Mind import. Mock no-op.
        }

        func resetMoodImport() async {
            // v0.10.0 W10 M2 — State-of-Mind import anchor reset. Mock no-op.
        }

        /// v0.14.8 W3 (AUDIT-SECURITY-B175 H-1) — recorded so the logout-
        /// completeness suite can pin that `performFullLocalLogout` resets the
        /// cycle import observer + per-user anchors on every path.
        var resetCycleImportCallCount: Int {
            lock.withLock { _resetCycleImportCallCount }
        }

        private var _resetCycleImportCallCount = 0

        func resetCycleImportObserver() async {
            lock.withLock { _resetCycleImportCallCount += 1 }
        }

        func activateBackgroundDeliveries() async throws {
            lock.withLock { _activateCallCount += 1 }
            if shouldThrow {
                throw HLError.unknown("mock")
            }
        }

        func runBackgroundSyncPass() async {
            lock.withLock { _syncPassCallCount += 1 }
        }

        func attachUploader(_: MeasurementBatchUploader) async {
            // Test-Doppel — Composition-Root sollte den Hook aufrufen, der echte
            // Uploader wird im Mock nicht verdrahtet.
        }

        func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {
            // Test-Doppel.
        }

        func setInitialBackfillCutoff(_ cutoff: Date?) async {
            lock.withLock { _initialBackfillCutoff = cutoff }
        }

        func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {
            // Test-Doppel — Composition-Root wires the live reader;
            // wiring-tests don't exercise the per-sample gate.
        }

        var initialBackfillCutoff: Date? {
            lock.withLock { _initialBackfillCutoff }
        }

        private var _initialBackfillCutoff: Date?
    }

    /// Minimaler Passkey-Stub für Tests, weil `StubPasskeyService` aus dem App-Target
    /// nur für Non-iOS-Plattformen kompiliert wird.
    final class TestPasskeyService: PasskeyServiceProtocol, @unchecked Sendable {
        @MainActor func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("test stub")
        }

        @MainActor func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("test stub")
        }
    }

    @Suite("BackgroundSyncCoordinator wiring")
    struct BackgroundSyncCoordinatorTests {
        @Test("activateHealthKitBackgroundDeliveries delegiert an den Writer")
        func activateDelegates() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)

            await coordinator.activateHealthKitBackgroundDeliveries()

            #expect(writer.activateCallCount == 1)
        }

        @Test("activate schluckt Writer-Errors (BG-Sync darf Onboarding nicht abbrechen)")
        func activateSwallowsErrors() async {
            let writer = MockHealthKitWriter(shouldThrow: true)
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)

            // Darf nicht throwen — Onboarding-Flow hängt sonst.
            await coordinator.activateHealthKitBackgroundDeliveries()

            #expect(writer.activateCallCount == 1)
        }

        @Test("Coordinator ohne HealthKit-Writer ist no-op (nicht-iOS-Build / Tests)")
        func noWriterIsNoOp() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            // Darf nicht crashen.
            await coordinator.activateHealthKitBackgroundDeliveries()
        }

        @Test("BG-Task-Identifier bleibt im Sync mit project.yml")
        func identifierMatchesPlist() {
            // Die Konstante wird in project.yml's BGTaskSchedulerPermittedIdentifiers
            // referenziert — Drift würde HK-BG-Sync silently brechen, daher hard-coded check.
            #expect(BackgroundSyncCoordinator.bgTaskIdentifier == "dev.healthlog.app.healthkit-sync")
        }

        /// **Restated by plan 07-09 — the Connect-Spinner regression, closed
        /// structurally.**
        ///
        /// Before v0.14.1 the anchor-sweep hook was awaited here, so the connect
        /// path (onboarding + the Settings toggle) hung on a multi-thousand-row
        /// all-time backfill. v0.14.1 made the hook detached. This plan removed
        /// the reason for the hook altogether: `activateHealthKitBackgroundDeliveries`
        /// arms HealthKit delivery and re-submits the two BGTask requests, and
        /// starts no pass at all — the caller (`RootView` → `coldActivation`,
        /// `HKReadinessStore`/`HealthKitPermissionStep` → `postAuthentication`)
        /// names its own trigger. The spinner cannot hang on a backfill this path
        /// no longer starts.
        @Test("activate arms delivery and starts no pass (Connect-Spinner-Bugfix v0.14.1)")
        func activateStartsNoPass() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)

            let routeEntered = AsyncFlag()
            coordinator.attachHealthSyncRoute { _, _ in
                routeEntered.set()
                return []
            }

            let start = ContinuousClock.now
            await coordinator.activateHealthKitBackgroundDeliveries()
            let elapsed = ContinuousClock.now - start

            // Authorization-Delegation ist synchron erledigt …
            #expect(writer.activateCallCount == 1)
            // … der Aufruf kommt prompt zurueck …
            #expect(elapsed < .seconds(5))
            // … und er hat keinen Pass gestartet. Das ist die staerkere Form des
            // v0.14.1-Fixes: nicht "der Sweep blockt nicht mehr", sondern "dieser
            // Pfad faengt keinen an".
            #expect(!routeEntered.value)
        }

        @Test("runMedicationReconcile ruft den attached Hook + meldet true (b182 #22 Silent-Push-Pfad)")
        func runMedicationReconcileInvokesHook() async {
            // Der Silent-Push-Handler (NotificationService) ruft diesen Pfad bei
            // eventType MEDICATION_INTAKE_SYNC — er muss den b181-Med-Reconcile-Hook
            // tatsaechlich ausfuehren, damit eine remote genommene Dosis sofort
            // reconcilet (Live Activity beenden + Widgets reloaden).
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let hookRan = AsyncFlag()
            coordinator.attachMedicationReconcileHook {
                hookRan.set()
            }

            let didRun = await coordinator.runMedicationReconcile()

            #expect(didRun)
            await hookRan.wait()
        }

        @Test("runMedicationReconcile ohne Hook ist no-op (meldet false)")
        func runMedicationReconcileNoHookIsNoOp() async {
            // Vor der Hook-Verdrahtung (oder auf nicht-iOS-Builds) darf der
            // Silent-Push-Pfad nicht crashen — er meldet schlicht false.
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)

            let didRun = await coordinator.runMedicationReconcile()

            #expect(!didRun)
        }

        // MARK: - AUD-1 F4/F8 — BGProcessingTask re-arms med + mood reminders

        @Test("AUD-1 F8: runBGSync drives the medication-reconcile hook (med-reminder re-arm)")
        func bgSyncDrivesMedicationReconcileHook() async {
            // The guaranteed-sync BGProcessingTask must re-run the medication
            // reconcile so the local SpeziScheduler med-reminder queue gets
            // topped up even when Background App Refresh never grants the app
            // runtime. This pins that the reconcile hook fires from the BG pass
            // (not just from the on-demand silent-push `runMedicationReconcile`).
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let medReconcileRan = AsyncFlag()
            coordinator.attachMedicationReconcileHook {
                medReconcileRan.set()
            }

            await coordinator.runBGSync(on: spy)

            // The BG pass completed normally AND the med reconcile ran inline
            // before completion.
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            await medReconcileRan.wait()
        }

        @Test("AUD-1 F4: runBGSync drives the mood-reconcile hook (mood-reminder re-arm)")
        func bgSyncDrivesMoodReconcileHook() async {
            // The local evening mood reminder is a non-repeating trigger that
            // previously re-armed only on app foreground. The guaranteed-sync
            // BGProcessingTask must now also re-arm it, so a user who never
            // opens the app still gets the daily nudge. This pins that the
            // mood-reconcile hook fires from the BG pass.
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let moodReconcileRan = AsyncFlag()
            coordinator.attachMoodReconcileHook {
                moodReconcileRan.set()
            }

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            await moodReconcileRan.wait()
        }

        @Test("W-LA-BG: runBGSync drives the Live-Activity reconcile hook AFTER the med reconcile")
        func bgSyncDrivesLiveActivityReconcileHook() async {
            // v0.16.1 W-LA-BG — a dose that becomes due while the app is
            // backgrounded must have its medication Live Activity STARTED from
            // the guaranteed-sync BGProcessingTask, not only the local
            // notification. This pins that (1) the LA-reconcile hook fires from
            // the BG pass and (2) it runs AFTER the med-reconcile hook (which
            // force-loads the store with the current intakes), so the LA
            // reconcile sees fresh data.
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let order = ReconcileOrderRecorder()
            coordinator.attachMedicationReconcileHook {
                await order.record("med")
            }
            coordinator.attachLiveActivityReconcileHook {
                await order.record("liveActivity")
            }

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            let recorded = await order.events
            #expect(recorded == ["med", "liveActivity"])
        }

        @Test("W-LA-BG: Live-Activity reconcile hook is best-effort — a missing hook does not fail the BGTask")
        func bgSyncWithoutLiveActivityHookStillCompletes() async {
            // No LA hook attached (pre-wiring / non-ActivityKit) must not crash
            // and must still complete the BGTask normally.
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("AUD-1 F4: mood-reconcile hook is best-effort — a missing hook does not fail the BGTask")
        func bgSyncWithoutMoodHookStillCompletes() async {
            // No mood hook attached (pre-wiring / non-iOS) must not crash and
            // must still complete the BGTask normally.
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        // MARK: - Reliability M1 (audit-v0162) — BGTask drains the outbox

        /// **Restated by plan 07-09 — same contract, reached through the one
        /// route.** The guaranteed-sync BGProcessingTask must still drain the
        /// encrypted Outbox so an offline-logged user write replays on a BG wake
        /// instead of waiting for the next app foreground (audit RELIABILITY M1).
        /// It is now the pass's last planned capability rather than a separate
        /// hook call the pass duplicated, and `runOutboxDrain()` — the probe-gated
        /// hook this test attaches — is exactly what that capability invokes.
        @Test("M1: a BG wake's pass drains the outbox (queued user write replays on BG wake)")
        func bgSyncDrivesOutboxDrainHook() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let drainRan = AsyncFlag()
            coordinator.attachOutboxDrainHook {
                drainRan.set()
            }
            // The production route: `AppContainer.runHealthSyncPass` → the
            // orchestrator, whose `outboxDrain` adapter calls back into
            // `runOutboxDrain()`.
            coordinator.attachHealthSyncRoute { trigger, _ in
                #expect(trigger == .processing)
                let didDrain = await coordinator.runOutboxDrain()
                return didDrain ? [.outboxDrain] : []
            }

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            await drainRan.wait()
        }

        @Test("M1: outbox-drain hook is best-effort — a missing hook does not fail the BGTask")
        func bgSyncWithoutOutboxDrainHookStillCompletes() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("M1: the wired drain is probe-gated — replays only when confirmedReachable()")
        @MainActor
        func outboxDrainHookGatedOnReachability() async {
            // Reachable → the drain (outbox replay) fires.
            let reachableDrainRan = AsyncFlag()
            let reachableHook = AppContainer.makeReachabilityGatedOutboxDrain(
                confirmReachable: { true },
                drain: { reachableDrainRan.set() }
            )
            await reachableHook()
            await reachableDrainRan.wait()

            // Unreachable (captive portal / degraded server) → the drain is a
            // no-op, so a queued write never burns a replay attempt against an
            // unreachable host.
            let unreachableDrainCount = DrainCounter()
            let unreachableHook = AppContainer.makeReachabilityGatedOutboxDrain(
                confirmReachable: { false },
                drain: { await unreachableDrainCount.bump() }
            )
            await unreachableHook()
            #expect(await unreachableDrainCount.value == 0)
        }

        // MARK: - W-HK-RELIABILITY H-3 — BGTask completion exactly-once + expiration

        /// **Restated by plan 07-09.** It used to assert that the wake called the
        /// writer's shimmed sweep once *and* the workout hook once — two of the
        /// four sequential calls the wake made. It now asserts the thing that
        /// replaced them: the wake enters exactly one pass, names `.processing`,
        /// and reports the capabilities that pass answered for.
        @Test("normal path: runBGSync completes the task exactly once with success + enters one pass")
        func bgSyncNormalPathCompletesOnce() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let triggers = TriggerRouteRecorder()

            coordinator.attachHealthSyncRoute { trigger, _ in
                await triggers.record(trigger)
                return [.speziSampleCollection, .workoutImport, .outboxDrain]
            }

            await coordinator.runBGSync(on: spy)

            #expect(await triggers.values == [.processing], "one wake, one named pass")
            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            // An expiration handler must always be installed.
            #expect(spy.expirationHandlerInstalled)
        }

        @Test("no writer: runBGSync still completes the task exactly once (success=false)")
        func bgSyncNoWriterCompletesOnce() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
        }

        @Test("expiration handler completes the task (success=false) and the normal path does NOT double-complete")
        func bgSyncExpirationCompletesExactlyOnce() async {
            // The writer blocks inside the sync pass; meanwhile we fire the
            // installed expiration handler. The expiration path must complete
            // the task exactly once, and the eventual normal-path completion
            // must be a no-op (exactly-once guarantee).
            //
            // Plan 07-09: the pass blocks in the route rather than in the
            // writer's shimmed sweep, because the wake no longer calls that
            // sweep. The predicate the route receives is the same
            // `BGTask.expirationHandler` flag the handler sets.
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let spy = BGTaskCompletionSpy()
            let passStarted = AsyncFlag()
            let release = AsyncFlag()
            let sawExpiry = AsyncBox()
            coordinator.attachHealthSyncRoute { _, isExpired in
                passStarted.set()
                await release.wait()
                sawExpiry.set(isExpired())
                return []
            }

            let run = Task { await coordinator.runBGSync(on: spy) }

            // Wait until the expiration handler is installed + the pass has
            // started blocking, then simulate iOS expiry.
            await passStarted.wait()
            spy.fireExpiration()
            // Release the blocked pass so runBGSync can reach its normal-path
            // completion (which must be guarded out).
            release.set()
            await run.value

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
            // The pass was told, rather than merely cancelled: that is what lets
            // it name the capabilities it did not admit `expired`.
            #expect(sawExpiry.value == true)
        }

        @Test("OneShotCompletion delivers setTaskCompleted exactly once across racing callers")
        func oneShotCompletionIsExactlyOnce() {
            let guardObj = OneShotCompletion()
            let spy = BGTaskCompletionSpy()

            guardObj.complete(task: spy, success: true)
            guardObj.complete(task: spy, success: false)
            guardObj.complete(task: spy, success: true)

            #expect(spy.completionCount == 1)
            // First caller wins.
            #expect(spy.lastSuccess == true)
        }

        // MARK: - #66 P0.1 (Baustein 1) — BGAppRefreshTask + on-demand outbox drain

        @Test("#66: the refresh-task identifier stays in sync with project.yml")
        func refreshIdentifierMatchesPlist() {
            // Drift here would silently break the new light HK wake channel (the
            // identifier must appear in BGTaskSchedulerPermittedIdentifiers).
            #expect(BackgroundSyncCoordinator.bgRefreshTaskIdentifier == "dev.healthlog.app.refresh")
        }

        @Test("R3: BGAppRefresh earliest-begin interval is compressed to ~45 min")
        func refreshEarliestIntervalIsAggressiveCadence() {
            // R3 aggressive-cadence: densified from 2 h → 45 min so iOS may wake
            // the app for the light HK pull more often (operator: reception over
            // battery). This is the earliest-begin lower bound, not a guarantee;
            // the reschedule pattern (re-submit after every run) is unchanged.
            #expect(BackgroundSyncCoordinator.bgRefreshEarliestInterval == 45 * 60)
        }

        @Test("#66: registerBGTaskHandler is idempotent — a double call does not crash (per-identifier guard)")
        func registerBGTaskHandlerIsIdempotent() {
            // Registers both the processing + refresh identifiers under the
            // process-wide per-identifier guard. A raw double
            // `BGTaskScheduler.register` throws NSInternalInconsistencyException;
            // the guard must turn the second call into a no-op. Reaching the
            // assertion without a crash IS the test.
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            coordinator.registerBGTaskHandler()
            coordinator.registerBGTaskHandler()
            #expect(BackgroundSyncCoordinator.bgRefreshTaskIdentifier == "dev.healthlog.app.refresh")
        }

        /// **Restated by plan 07-09.** The AppRefresh wake used to make three
        /// calls in order — arm the collectors, run the workout pass, drain the
        /// outbox — the last two of which the pass the first one started already
        /// contained. It now enters one `.appRefresh` pass, and it must still not
        /// be the heavy `.processing` one.
        @Test("#66: runBGRefresh enters exactly one .appRefresh pass and completes exactly once")
        func bgRefreshEntersOneAppRefreshPass() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let triggers = TriggerRouteRecorder()
            coordinator.attachHealthSyncRoute { trigger, _ in
                await triggers.record(trigger)
                return [.speziSampleCollection, .workoutImport, .outboxDrain]
            }

            await coordinator.runBGRefresh(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
            #expect(spy.expirationHandlerInstalled)
            #expect(writer.syncPassCallCount == 0, "the light wake never runs the heavy shim")
            #expect(await triggers.values == [.appRefresh])
        }

        /// **Restated by plan 07-09.** The downstream this pins is no longer a
        /// second HealthKit hook (there is none) but the reconcile chain that
        /// runs after the pass: an expired wake must not start it.
        @Test("Pass expiration completes once and prevents downstream reconciliation")
        func passExpirationStopsHeavyPass() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let spy = BGTaskCompletionSpy()
            let passStarted = AsyncFlag()
            let releasePass = AsyncFlag()
            let downstreamRan = AsyncFlag()
            coordinator.attachHealthSyncRoute { trigger, _ in
                #expect(trigger == .processing)
                passStarted.set()
                await releasePass.wait()
                return []
            }
            coordinator.attachMedicationReconcileHook {
                downstreamRan.set()
            }

            let run = Task { await coordinator.runBGSync(on: spy) }
            await passStarted.wait()
            spy.fireExpiration()
            releasePass.set()
            await run.value

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
            #expect(!downstreamRan.value)
        }

        @Test("#66: runBGRefresh with no hooks still completes the task exactly once (best-effort)")
        func bgRefreshNoHooksStillCompletes() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let spy = BGTaskCompletionSpy()

            await coordinator.runBGRefresh(on: spy)

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == true)
        }

        @Test("#66: runBGRefresh expiration completes exactly once and the normal path does NOT double-complete")
        func bgRefreshExpirationExactlyOnce() async {
            // Block inside the pass, fire iOS expiry, then release. The
            // expiration path completes exactly once (success=false) and the
            // eventual normal-path completion is guarded out — same
            // exactly-once contract as runBGSync.
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let spy = BGTaskCompletionSpy()
            let hookStarted = AsyncFlag()
            let release = AsyncFlag()
            coordinator.attachHealthSyncRoute { _, _ in
                hookStarted.set()
                await release.wait()
                return []
            }

            let run = Task { await coordinator.runBGRefresh(on: spy) }
            await hookStarted.wait()
            spy.fireExpiration()
            release.set()
            await run.value

            #expect(spy.completionCount == 1)
            #expect(spy.lastSuccess == false)
        }

        @Test("#66: runOutboxDrain runs the attached hook + reports true (silent-push channel)")
        func runOutboxDrainInvokesHook() async {
            // The silent-push handler calls this on-demand path so a server wake
            // drains an offline-logged user write without waiting for a BGTask.
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let hookRan = AsyncFlag()
            coordinator.attachOutboxDrainHook { hookRan.set() }

            let didRun = await coordinator.runOutboxDrain()

            #expect(didRun)
            await hookRan.wait()
        }

        @Test("#66: runOutboxDrain without a hook is a no-op (reports false)")
        func runOutboxDrainNoHookIsNoOp() async {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let didRun = await coordinator.runOutboxDrain()
            #expect(!didRun)
        }
    }

    /// Spy `BGTaskCompleting` — records completion calls + lets the test fire the
    /// installed expiration handler. No real `BGTask` involved (system-vended).
    final class BGTaskCompletionSpy: BGTaskCompleting, @unchecked Sendable {
        private let lock = NSLock()
        private var _completionCount = 0
        private var _lastSuccess: Bool?
        private var _expirationHandler: (@Sendable () -> Void)?

        var completionCount: Int {
            lock.withLock { _completionCount }
        }

        var lastSuccess: Bool? {
            lock.withLock { _lastSuccess }
        }

        var expirationHandlerInstalled: Bool {
            lock.withLock { _expirationHandler != nil }
        }

        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { _expirationHandler = handler }
        }

        func setTaskCompleted(success: Bool) {
            lock.withLock {
                _completionCount += 1
                _lastSuccess = success
            }
        }

        /// Simulate iOS firing the BGTask expiration handler.
        func fireExpiration() {
            let handler: (@Sendable () -> Void)? = lock.withLock { _expirationHandler }
            handler?()
        }
    }

    /// Writer whose `runBackgroundSyncPass` blocks until released, so the
    /// expiration race can be driven deterministically.
    final class BlockingHealthKitWriter: AnyHealthKitWriter, @unchecked Sendable {
        let passStarted = AsyncFlag()
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func release() {
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            for continuation in toResume {
                continuation.resume()
            }
        }

        func runBackgroundSyncPass() async {
            passStarted.set()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let already: Bool = lock.withLock {
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if already { continuation.resume() }
            }
        }

        func write(_: HealthLog.Measurement) async throws {}
        func mirrorServerMeasurements(_: [HealthLog.Measurement]) async {}
        func writeMood(_: MoodEntry) async throws {}
        func deleteMood(id _: String) async throws {}
        func requestMoodAuthorization() async throws {}
        func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
        func stopMoodImport() async {}
        func resetMoodImport() async {}
        func activateBackgroundDeliveries() async throws {}
        func attachUploader(_: MeasurementBatchUploader) async {}
        func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
        func setInitialBackfillCutoff(_: Date?) async {}
        func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
    }

    /// Minimaler async-Latch fuer den Detach-Test: erlaubt einem detached Task zu
    /// signalisieren, dass er gestartet ist, und dem Test darauf zu warten — ohne
    /// `Task.sleep`-Polling. `@unchecked Sendable` + NSLock, weil der Setter aus dem
    /// detached Task und der Waiter aus dem Test-Task kommen.
    final class AsyncFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func set() {
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                guard !isSet else { return [] }
                isSet = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            for continuation in toResume {
                continuation.resume()
            }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadySet: Bool = lock.withLock {
                    if isSet { return true }
                    waiters.append(continuation)
                    return false
                }
                if alreadySet {
                    continuation.resume()
                }
            }
        }

        var value: Bool {
            lock.withLock { isSet }
        }
    }

    /// Records the order in which the BGTask hooks fire, so a test can pin that
    /// the Live-Activity reconcile runs AFTER the med reconcile (which loads the
    /// store's fresh intakes). An `actor` gives data-race-free ordering across
    /// the two `@Sendable` hook closures.
    actor ReconcileOrderRecorder {
        private(set) var events: [String] = []
        func record(_ label: String) {
            events.append(label)
        }
    }

    actor WorkoutModeRecorder {
        private(set) var values: [WorkoutSyncPassMode] = []
        func record(_ mode: WorkoutSyncPassMode) {
            values.append(mode)
        }
    }

    /// Plan 07-09 — a one-shot lock-guarded box, so an assertion made inside a
    /// `@Sendable` route closure can be read back on the test task.
    final class AsyncBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?

        func set(_ newValue: Bool) {
            lock.withLock { stored = newValue }
        }

        var value: Bool? {
            lock.withLock { stored }
        }
    }

    /// Plan 07-09 — records the `HealthSyncTrigger` each wake names, so
    /// "exactly once, under one name" is an assertion rather than a claim.
    actor TriggerRouteRecorder {
        private(set) var values: [HealthSyncTrigger] = []
        func record(_ trigger: HealthSyncTrigger) {
            values.append(trigger)
        }
    }

    /// Reliability M1 — data-race-free drain counter for the probe-gated
    /// outbox-drain test (the drain closure is `@Sendable`).
    actor DrainCounter {
        private(set) var value = 0
        func bump() {
            value += 1
        }
    }

    @MainActor
    @Suite("AppContainer.activateHealthKitBackground")
    struct AppContainerHKBackgroundTests {
        @Test("activateHealthKitBackground triggert den Writer")
        func appContainerActivates() async {
            let writer = MockHealthKitWriter()
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: writer
            )

            await container.activateHealthKitBackground(for: .coldActivation)

            #expect(writer.activateCallCount == 1)
        }
    }

#endif // !SWIFT_PACKAGE
