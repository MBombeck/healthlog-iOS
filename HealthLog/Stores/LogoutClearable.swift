import Foundation

/// **AUD-7 H1 — logout-clearing as a protocol obligation, not a hand-list.**
///
/// The logout PHI-clearing cascade in `AppContainer+Logout.performFullLocalLogout`
/// used to hand-list ~43 individual `store.clearOnLogout()` calls. Every new
/// PHI-bearing store had to be manually appended there or it leaked the previous
/// user's data across an account switch — a failure mode the team already shipped
/// once (the B187 About-Me PHI leak).
///
/// `LogoutClearable` converts that forgettable list into an enforced invariant:
/// a store conforms, and `AppContainer` collects every conforming stored property
/// into a typed registry (via `Mirror`) at `init`. `performFullLocalLogout`
/// iterates the registry instead of the hand-list, so a new conforming store is
/// cleared automatically. `LogoutCompletenessTests` then asserts that **every**
/// store reachable by the Mirror sweep is either in the registry (conforms) or
/// explicitly classified — a new clearable that isn't wired fails at test time.
///
/// **Scope:** this protocol covers the *synchronous, parameterless*
/// `clearOnLogout()` stores — the overwhelming majority. The handful of
/// async / lifecycle outliers (`deactivateOnLogout()` on `CycleStore` /
/// `MoodHealthSyncStore`, the `async` `MeasurementRemindersStore.clearOnLogout()`,
/// the `ServerStatsStores` bundle, the static `…wipePersisted()` /
/// `…clearAll()` wipes, the box-backed stores, and the HK importers) remain
/// explicit in `performFullLocalLogout` — they aren't a plain `clearOnLogout()`
/// and each carries its own ordering / error-handling nuance.
@MainActor
public protocol LogoutClearable: AnyObject {
    /// Reset the store's in-memory (and any owned UserDefaults-mirrored) per-user
    /// state back to its pristine empty shape. Called by the logout cascade.
    /// Must be idempotent.
    func clearOnLogout()
}

// MARK: - Conformances

//
// Each store already declares a synchronous `clearOnLogout()`; these empty
// extensions opt it into the registry. Adding a NEW store to the cascade is now
// "add `clearOnLogout()` + conform here" — and `LogoutCompletenessTests` fails
// until both are done.

extension AccountSecurityStore: LogoutClearable {} // parity 2.1 — clears the change-password outcome
extension AchievementsStore: LogoutClearable {}
extension AIProviderStore: LogoutClearable {}
extension AllergiesStore: LogoutClearable {} // v1.25 PHI — decrypted reaction/note
extension AvatarStore: LogoutClearable {}
extension ChartsStore: LogoutClearable {}
extension CoachCadenceSuggestionsStore: LogoutClearable {}
extension CoachNudgeStore: LogoutClearable {}
extension CycleStore: LogoutClearable {}
extension DailyBriefingStore: LogoutClearable {}
extension DashboardLayoutStore: LogoutClearable {}
extension DashboardStore: LogoutClearable {}
extension DeliveryPreferencesStore: LogoutClearable {}
extension DiabetesStore: LogoutClearable {}
extension DisclaimerAckStore: LogoutClearable {}
extension DocumentsStore: LogoutClearable {} // PHI — decrypted document vault snapshot
extension DoctorReportStore: LogoutClearable {}
extension FamilyHistoryStore: LogoutClearable {} // v1.25 PHI — decrypted note
extension FeatureFlagsStore: LogoutClearable {}
extension FitbitIntegrationStore: LogoutClearable {}
extension HealthScoreStore: LogoutClearable {}
extension HKReadinessStore: LogoutClearable {}
extension IllnessStore: LogoutClearable {}
extension InjectionSitePrefsStore: LogoutClearable {}
extension InsightsLayoutStore: LogoutClearable {}
extension InsightsStore: LogoutClearable {}
extension LabsStore: LogoutClearable {}
extension CustomMetricsStore: LogoutClearable {} // PHI — user-defined metrics + values
extension LiveHealthKitTodayStore: LogoutClearable {}
extension LocalDoctorReportStore: LogoutClearable {}
extension MeasurementsStore: LogoutClearable {}
extension MedicationsStore: LogoutClearable {}
extension MentalHealthStore: LogoutClearable {} // v1.25 PHI — in-flight item answers + history
// Parity 2.3 — the forced-enrolment verdict is per-account policy; a stale
// `true` would gate the next user against a requirement that is not theirs.
extension MfaEnrollmentGateStore: LogoutClearable {}
extension MoodStore: LogoutClearable {}
extension MoodTagCatalogStore: LogoutClearable {}
extension MoodTagManagementStore: LogoutClearable {}
extension NightscoutIntegrationStore: LogoutClearable {}
extension OnboardingTourStore: LogoutClearable {}
extension OuraIntegrationStore: LogoutClearable {}
extension PasskeyManagementStore: LogoutClearable {}
extension PolarIntegrationStore: LogoutClearable {}
// Parity 2.2 — the session inventory is per-user security state; leaving it
// behind would show the previous account's devices to the next sign-in.
extension SessionsStore: LogoutClearable {}
extension SettingsStore: LogoutClearable {}
extension StravaIntegrationStore: LogoutClearable {}
extension SyncModeStore: LogoutClearable {}
extension TrendsOverlayStore: LogoutClearable {}
extension WellnessCardVisibilityStore: LogoutClearable {} // local UI-pref — per-card Insights score-card hide
extension WhoopIntegrationStore: LogoutClearable {}
extension WithingsIntegrationStore: LogoutClearable {}
