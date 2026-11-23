import Foundation

/// The single pull seam for HealthKit collection.
///
/// Every trigger (cold activation, after sign-in, the foreground revalidate,
/// "Jetzt syncen", the silent push, the two background tasks and every
/// observer signal) enters here, names its own `HealthSyncTrigger`, and runs
/// one bounded, account-scoped pass through ``AppOwnedHealthCollection``.
/// SpeziHealthKit no longer collects anything: no `CollectSamples` is
/// registered, the module stays only for authorization and its UI surfaces.
/// The name is historical.
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

        /// The `BGAppRefreshTask` wake, which is not
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
        /// Made `HealthSyncTrigger` the thing every call site
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

    /// The single pull seam: one ``AppOwnedHealthCollection`` pass under the
    /// budget this trigger names.
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
}
