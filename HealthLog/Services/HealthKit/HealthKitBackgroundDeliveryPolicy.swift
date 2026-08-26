import Foundation

/// Per-type background-delivery policy for the SpeziHealthKit collectors
/// (`HealthLogSpeziDelegate.configuration`).
///
/// **Why this exists (W2 energy fix).** SpeziHealthKit's `CollectSamples`
/// exposes only a `continueInBackground: Bool` — there is **no per-type
/// frequency parameter**. Internally it always arms background delivery with
/// `enableBackgroundDelivery(for:frequency: .immediate)`. The pre-Spezi
/// pipeline used `HKObserverQuery.enableBackgroundDelivery(...,
/// frequency: .hourly)` for cumulative / low-urgency types; that throttle was
/// lost in the Spezi migration, so every one of the ~27 collectors registered
/// `continueInBackground: true` and could wake the app at `.immediate` cadence
/// — including slowly-changing types that have nothing useful to upload
/// between foreground sessions.
///
/// Since the only lever Spezi gives us is the boolean, the classification is:
/// - **Vital-signs** → `continueInBackground: true`. Low-latency delivery is
///   the point (a new resting-HR / SpO₂ / blood-pressure / glucose reading
///   should sync promptly). `.immediate` is the right behavior for them.
/// - **R3 aggressive-cadence promotions** (``aggressiveCadenceIdentifiers``) →
///   `continueInBackground: true`. `heartRate`, `stepCount`, and
///   `sleepAnalysis` were lifted onto real background delivery by an explicit
///   operator decision (reception over battery). `heartRate` in particular had
///   been demoted in v0.14; that demotion is deliberately reversed here.
/// - **Cumulative + low-urgency** → `continueInBackground: false`. No
///   background observer is armed; the type syncs on the next foreground
///   sweep or the `BGProcessingTask` wake. This is the practical equivalent
///   of the old `.hourly` intent: no high-frequency wakeups for data that
///   changes slowly or arrives in batches (energy, mass, audio exposure, …).
///
/// **Battery posture.** The R3 promotions add background wakeups (heaviest:
/// 24/7 Watch heart-rate) and therefore cost more energy than the prior
/// posture. That is a conscious operator trade-off ("besserer Empfang,
/// Batterie zweitrangig"), documented at ``aggressiveCadenceIdentifiers``.
///
/// The classification is keyed on raw HK identifier strings so it stays
/// HealthKit-import-free and the W2 tests can assert it without a HealthKit
/// store. The delegate calls ``continuesInBackground(for:)`` to drive each
/// `CollectSamples`, keeping the policy a single auditable source of truth
/// rather than a per-call boolean literal.
public enum HealthKitBackgroundDeliveryPolicy {
    /// Vital-sign identifiers that warrant immediate background delivery.
    /// A new reading from any of these should wake the app and sync promptly.
    ///
    /// **v0.14 energy decision (audit #1) — SUPERSEDED for `heartRate` by the
    /// R3 aggressive-cadence operator decision (see
    /// ``aggressiveCadenceIdentifiers``).** In v0.14 `heartRate` was demoted out
    /// of the background set: a Watch worn 24/7 streams HR continuously, so
    /// `.immediate` HR delivery was the single biggest background wake / battery
    /// source. That demotion is now *lifted* — the operator explicitly chose
    /// reception over battery (R3). `heartRate` no longer lives here in the
    /// literal "vital sign" set (it isn't clinically a vital sign), but joins
    /// the automatic/background set via ``aggressiveCadenceIdentifiers`` so the
    /// `.immediate` HR wake path is back on. `restingHeartRate`, SpO₂
    /// (`OxygenSaturation`), blood pressure, and body temperature, and glucose
    /// were never demoted and stay here — genuinely time-sensitive, low-volume.
    public static let vitalSignIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
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

    /// Cumulative / low-urgency identifiers that should NOT wake the app in
    /// the background. They sync on the next foreground / `BGProcessingTask`
    /// sweep. Includes the remaining cumulative types plus mass, body-fat,
    /// VO₂, audio exposure, and time-in-daylight.
    ///
    /// **R3:** `heartRate`, `stepCount`, and `sleepAnalysis` were moved OUT of
    /// this set into ``aggressiveCadenceIdentifiers`` — see there for the
    /// operator rationale + battery trade-off.
    public static let lowUrgencyIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage",
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
        vitalSignIdentifiers.union(aggressiveCadenceIdentifiers)

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
