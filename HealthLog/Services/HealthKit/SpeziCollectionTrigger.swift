import Foundation

/// **W-B182 (Apple-Health-Sync bulletproof) — the active pull lever for the
/// SpeziHealthKit low-urgency collectors.**
///
/// ## Why this exists
///
/// The app moved fully onto the SpeziHealthKit `CollectSamples` observer path
/// (W-A5). To preserve the W2 battery posture, every type except the
/// automatic/background set (vital signs + the R3 aggressive-cadence
/// promotions `heartRate` / `stepCount` / `sleepAnalysis`) runs with
/// `continueInBackground: false` — i.e. it arms **no** background
/// `HKObserverQuery`. Before W-B182 those types were collected by a single
/// foreground `start: .automatic` continuous query that armed once at
/// `configure()` time and was never re-triggered: the `BGProcessingTask` wake,
/// the foreground revalidate, and the manual "Jetzt syncen" button were all
/// no-ops for them (`runOneShotAnchorSweep()` was an empty shim). Result: mass
/// / body-fat / VO₂ / audio / gait / respiratory / BMI synced only
/// opportunistically and "went quiet" = the operator's "synchronisiert nicht
/// konstant" complaint.
///
/// ## The fix
///
/// Those collectors are now declared `start: .manual` (see
/// `HealthLogSpeziDelegate.configuration`). A manual collector does nothing
/// until ``SpeziHealthKit/HealthKit/triggerDataSourceCollection()`` is called;
/// the first call arms its anchored continuous query (which then re-fires for
/// new samples for the rest of the process lifetime), and every later call is a
/// cheap no-op for already-armed collectors. This type is the single seam that
/// performs that trigger from all three points:
///
/// 1. the `BGProcessingTask` wake (`HealthKitService.runOneShotAnchorSweep`),
/// 2. the foreground `.active` revalidate (`RootView`),
/// 3. the manual "Jetzt syncen" path (`HKReadinessStore.triggerManualSync`).
///
/// On a cold launch the manual collectors re-arm from their persisted
/// SpeziLocalStorage anchor on the first trigger and immediately deliver
/// everything since the anchor, so each launch + first foreground catches up.
///
/// The automatic/background collectors (vital signs + the R3 aggressive-cadence
/// `heartRate` / `stepCount` / `sleepAnalysis`) stay `start: .automatic` +
/// background, so this trigger neither re-enables `.immediate` background
/// delivery for the bulk of the type set (battery posture preserved for the
/// low-urgency set) nor needs to touch them — they self-arm at `configure()`.
///
/// Records the trigger heartbeat in ``HKSyncDiagnostics`` so the diagnostics
/// surface can distinguish "armed, nothing new" (healthy) from "never armed".
enum SpeziCollectionTrigger {
    /// Origin of a trigger, for diagnostics + logging.
    enum Source: String {
        case background
        case foreground
        case manual
        /// **#66 P0.1 (Baustein 2)** — a silent-push wake (the third HK wake
        /// channel). **CU-21:** the provenance no longer stops at the
        /// diagnostics heartbeat — the push handler opens a `.push`
        /// ``SyncTriggerContext`` window around this trigger, so every batch
        /// POST it causes carries `syncTrigger: "push"` on the wire.
        case push

        /// **Phase 07 / plan 07-07** — the `BGAppRefreshTask` wake, which is not
        /// the `BGProcessingTask` wake.
        ///
        /// Both used to arrive here as `.background`, so the ~30-second
        /// AppRefresh grant resolved to the Processing budget: eight pages per
        /// type and a permitted first history walk. That is the opposite of what
        /// `HealthSyncBudget.required(for: .appRefresh)` states, and a history
        /// walk started in a wake that is about to be terminated is the shape
        /// Waves 1-3 spent three plans making safe. The AppRefresh hook now says
        /// which wake it is.
        case appRefresh

        /// The Phase-07 trigger this source starts work for.
        ///
        /// Named rather than inferred: the budget the app-owned collector applies
        /// (pages per type, and whether a first history walk is allowed at all) is
        /// resolved from this value, so the wake that caused the pass has to be
        /// carried into it rather than guessed.
        var healthSyncTrigger: HealthSyncTrigger {
            switch self {
            case .background: .processing
            case .appRefresh: .appRefresh
            case .foreground: .foreground
            case .manual: .manual
            case .push: .silentPush
            }
        }

        /// The diagnostics word for a trigger, when this vocabulary has one.
        ///
        /// **Plan 07-09** made `HealthSyncTrigger` the thing every call site
        /// names, so this enum stopped being an input and became what it always
        /// was underneath: the diagnostics heartbeat's word. Cold activation,
        /// post-authentication, observer and teardown have no member here and
        /// record their own trigger name instead of borrowing a wrong one.
        init?(healthSyncTrigger trigger: HealthSyncTrigger) {
            switch trigger {
            case .processing: self = .background
            case .appRefresh: self = .appRefresh
            case .foreground: self = .foreground
            case .manual: self = .manual
            case .silentPush: self = .push
            case .coldActivation, .postAuthentication, .observer, .accountTeardown: return nil
            }
        }
    }

    /// The single pull seam.
    ///
    /// **Phase 07 Wave 2.** This used to mean one thing — arm SpeziHealthKit's
    /// `start: .manual` collectors — and now means two. The Spezi trigger is kept
    /// because the module is still registered and still owns authorization, and
    /// removing the call would change more than this plan claims to. The work that
    /// actually collects server-bound samples is the second call:
    /// ``AppOwnedHealthCollection``, which runs one bounded, account-scoped pass
    /// under the budget this source names.
    ///
    /// Routing through here is deliberate. **Plan 07-09** made it exclusive: cold
    /// activation, post-authentication, the foreground revalidate, the manual
    /// "Jetzt syncen", the silent push, the BGAppRefresh wake, the BGProcessing
    /// wake and every observer signal now enter here and nowhere else, each
    /// naming its own `HealthSyncTrigger`. What used to happen *in addition* —
    /// the direct daily-stats/HR/nutrient/ECG/medication/workout fan-outs at
    /// those call sites — is gone, so a foreground tick is one pass rather than
    /// one pass plus a second, idempotent-but-real, set of uploads.
    ///
    /// - Parameters:
    ///   - observedSource: for `.observer` passes, the one source that signalled.
    ///     An observer pass resolves to exactly that capability; it is never a
    ///     fan-out.
    ///   - isExpired: the wake's own window. A background grant passes its
    ///     `BGTask.expirationHandler` flag so the pass stops admitting
    ///     capabilities and names the remainder `expired`.
    /// - Returns: the capabilities the pass named, so a caller can report what a
    ///   wake actually reached.
    @MainActor
    @discardableResult
    static func run(
        _ trigger: HealthSyncTrigger,
        observedSource: HealthSyncSource? = nil,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> [HealthSyncCapability] {
        let word = Source(healthSyncTrigger: trigger)?.rawValue ?? trigger.rawValue
        HKSyncDiagnostics.shared.recordCollectionTrigger(source: word)
        #if canImport(Spezi) && canImport(SpeziHealthKit)
            let answered = await AppOwnedHealthCollection.run(
                trigger,
                observedSource: observedSource,
                isExpired: isExpired
            )
            // `word` and the capability count are fixed enum case names and a
            // cardinality — operator-grade, no PII. `.public` is correct here.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.debug(
                "collection trigger fired (\(word, privacy: .public)) — \(answered.count, privacy: .public) capabilities"
            )
            return answered
        #else
            return []
        #endif
    }

    /// Re-arms SpeziHealthKit's `start: .manual` collectors from their persisted
    /// anchors.
    ///
    /// This is the historical W-B182 job of `HealthKitService.runOneShotAnchorSweep`
    /// and it stayed there: the Spezi module is still registered, still owns
    /// authorization, and a manual collector that is never triggered pulls
    /// nothing. **Plan 07-09** separated it from the pass — arming a module and
    /// running a capability plan are two things, and conflating them is how a
    /// trigger ended up starting a pass from inside another pass.
    @MainActor
    static func armManualCollectors() async {
        #if canImport(Spezi) && canImport(SpeziHealthKit)
            guard let healthKit = ResolvedModule.healthKit else {
                HLLog.healthKit.info("Spezi HealthKit module unavailable — collector arming skipped")
                return
            }
            await healthKit.waitForConfigurationDone()
            await healthKit.triggerDataSourceCollection()
        #endif
    }
}

#if canImport(Spezi) && canImport(SpeziHealthKit)
    @_spi(APISupport) import Spezi
    import SpeziHealthKit

    /// Tiny resolver wrapper so the `@MainActor` Spezi lookup stays in one
    /// place (mirrors `AppContainer.attachSpeziStandardUploader`'s
    /// `SpeziAppDelegate.spezi` → `module(_:)` pattern).
    private enum ResolvedModule {
        @MainActor
        static var healthKit: HealthKit? {
            guard let spezi = SpeziAppDelegate.spezi else { return nil }
            return spezi.module(HealthKit.self)
        }
    }
#endif
