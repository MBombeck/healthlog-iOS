import Foundation

/// Which sample types wake the app in the background.
///
/// `AppOwnedHealthCollectionCoordinator.observedTypeIdentifiers` arms an
/// `HKObserverQuery` with `enableBackgroundDelivery(.immediate)` for exactly
/// the types this policy marks; every other type is pull-only and syncs on the
/// next foreground, processing or app-refresh pass (the battery posture).
///
/// - Vital signs: low volume, time-sensitive.
/// - Aggressive cadence: heart rate, steps and sleep, by operator decision
///   (reception over battery).
/// - Sparse readings: a smart scale's weight and body fat.
/// - Low urgency: cumulative and slowly changing types, never woken for.
///
/// Keyed on raw identifier strings so it stays HealthKit-import-free and the
/// tests can assert it without a store.
public enum HealthKitBackgroundDeliveryPolicy {
    /// Vital-sign identifiers that warrant immediate background delivery.
    /// A new reading from any of these should wake the app and sync promptly.
    ///
    /// `heartRate` is not in this set (it is not clinically a vital sign); it
    /// joins the background set through ``aggressiveCadenceIdentifiers``,
    /// because the operator chose reception over battery even though a Watch
    /// worn 24/7 streams HR continuously. `restingHeartRate`, SpO₂
    /// (`OxygenSaturation`), blood pressure, body temperature and glucose are
    /// here: time-sensitive and low-volume.
    public static let vitalSignIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        // RMSSD (iOS 27) is delivered like SDNN. It only arms where
        // the registry holds it, i.e. where the system resolves the type.
        "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierBodyTemperature",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKQuantityTypeIdentifierBloodPressureDiastolic",
        "HKQuantityTypeIdentifierBloodGlucose"
    ]

    /// **R3 aggressive-cadence promotion (operator decision — reception over
    /// battery).** High-value but higher-volume / batch-natured types the
    /// operator wants on *real* HealthKit background delivery — the same
    /// mechanic as the vital-sign collectors: `start: .automatic` +
    /// `continueInBackground: true`, i.e. an armed `HKObserverQuery` that wakes
    /// the app at `.immediate` cadence rather than waiting for the next
    /// foreground / `BGProcessingTask` sweep.
    ///
    /// - `heartRate` — its v0.14 demotion is deliberately *lifted* here. The
    ///   operator accepts the extra Watch-HR wakeups in exchange for HR that
    ///   syncs promptly instead of only on the sweep.
    /// - `stepCount`, `sleepAnalysis` — promoted from the low-urgency sweep so
    ///   step and sleep data land server-side without waiting for a foreground
    ///   session or a background-task wake.
    ///
    /// **Battery posture (honest).** Every identifier here arms an
    /// `.immediate` background observer, so the app wakes more often and burns
    /// more energy than under the v0.14 posture — most notably `heartRate`,
    /// which a 24/7 Watch streams continuously. This is a *conscious* operator
    /// trade-off (R3: "besserer Empfang, Batterie zweitrangig"), not an
    /// oversight. Reverting is a one-line move back into
    /// ``lowUrgencyIdentifiers`` + restoring `start: .manual` at the call site.
    public static let aggressiveCadenceIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierStepCount",
        "HKCategoryTypeIdentifierSleepAnalysis"
    ]

    /// Sparse readings a person takes on purpose: a smart scale's weight and
    /// body fat. A handful a day at most, so waking for each costs little, and
    /// without a wake a morning weigh-in waited until the app was opened.
    public static let sparseReadingIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage"
    ]

    /// Cumulative / low-urgency identifiers that should NOT wake the app in
    /// the background. They sync on the next foreground / `BGProcessingTask`
    /// sweep. Includes the remaining cumulative types plus VO₂, audio
    /// exposure, and time-in-daylight.
    ///
    /// `heartRate`, `stepCount`, and `sleepAnalysis` were moved OUT of
    /// this set into ``aggressiveCadenceIdentifiers`` — see there for the
    /// operator rationale + battery trade-off.
    public static let lowUrgencyIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierVO2Max",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure",
        "HKQuantityTypeIdentifierTimeInDaylight"
    ]

    /// The full automatic/background set: genuine vital-signs UNION the R3
    /// aggressive-cadence promotions. Membership here means both levers are on
    /// — `start: .automatic` **and** `continueInBackground: true` — which in
    /// this codebase are always flipped together (an armed background observer
    /// implies an automatically-started query). ``continuesInBackground(for:)``
    /// and ``startsAutomatically(for:)`` are both keyed on this set so the two
    /// levers can never drift apart.
    public static let automaticBackgroundIdentifiers: Set<String> =
        vitalSignIdentifiers.union(aggressiveCadenceIdentifiers).union(sparseReadingIdentifiers)

    /// `true` when the collector for `identifier` should set
    /// `continueInBackground: true` — the vital-signs plus the R3
    /// aggressive-cadence promotions (``automaticBackgroundIdentifiers``).
    /// Cumulative / low-urgency types and the server-deferred set return
    /// `false`.
    ///
    /// The deferred types (see ``HealthKitServerSupportConfig``) are gated out
    /// of the configuration entirely while the server can't persist them; if
    /// any is ever re-enabled it joins the low-urgency group (`false`) —
    /// respiratory rate is a vital but stays throttled until the server lands
    /// it, matching the rest of the deferred set.
    public static func continuesInBackground(for identifier: String) -> Bool {
        automaticBackgroundIdentifiers.contains(identifier)
    }

    /// `true` when the collector for `identifier` should use `start:
    /// .automatic` (arm its continuous observer at `configure()` time) rather
    /// than `start: .manual` (pull only when ``SpeziCollectionTrigger`` fires).
    /// Identical membership to ``continuesInBackground(for:)`` — the two levers
    /// are flipped together — but exposed as its own predicate so the delegate
    /// and the tests can assert the `.automatic` decision explicitly.
    public static func startsAutomatically(for identifier: String) -> Bool {
        automaticBackgroundIdentifiers.contains(identifier)
    }
}
